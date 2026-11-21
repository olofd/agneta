// A session is one task in Agneta; a turn is one prompt in it. A Turn is a promise of its result and an async iterable
// of its events, buffered from the start so iterating late misses nothing.
import type {
  ContentBlock, McpServerHttp, Meta, PermissionOption, RequestPermissionRequest, RequestPermissionResponse, SessionConfigOption,
  SessionModeState, SessionUpdate, StopReason, ToolCallContent, ToolCallLocation, ToolCallStatus, ToolKind, Usage
} from './acp.js';
import { configSetting, findConfigOption, type ConfigSetting } from './config.js';
import type { Connection, RequestOptions } from './connection.js';
import { Emitter } from './emitter.js';
import { InvalidParamsError, NoTurnRunningError, TimeoutError, TurnBusyError, type ConnectionClosedError, type DownloadProgress } from './errors.js';
import type {
  AgnetaRequests, AgnetaUsage, AppToolsLoad, EngineId, LimitHit, Policy, PromptResult, QueuedParams, RateLimitDetails, SandboxLevel,
  SessionCapabilities, SessionRequestMeta, SessionResult, SessionResultAgneta, SteerResult, StoppedBy, TaskInfo, TraceDelivery,
  TraceReadParams, TraceReadResult, TraceRecord, TraceRecordType
} from './protocol.js';

/** What a prompt or steer may be: text, one content block, or several. */
export type PromptInput = string | ContentBlock | readonly ContentBlock[];

/** A prompt's content blocks. */
export function promptBlocks(input: PromptInput): ContentBlock[] {
  if (typeof input === 'string') return [{ type: 'text', text: input }];
  return Array.isArray(input) ? [...input] : [input as ContentBlock];
}

// MARK: Permissions

/** How to answer a permission request: allow or reject (once; Agneta turns "always" into "once"), cancel, or an option. */
export type PermissionAnswer = 'allow' | 'reject' | 'cancel' | { optionId: string } | RequestPermissionResponse;

/** A permission request with the session it's for. */
export interface PermissionRequest extends RequestPermissionRequest {
  session: Session | undefined;
}

export type PermissionHandler = (request: PermissionRequest) => PermissionAnswer | Promise<PermissionAnswer>;

/** The ACP response for an answer: `allow` picks the allow option (once where there is one), `reject` the reject option. */
export function permissionResponse(answer: PermissionAnswer, options: readonly PermissionOption[]): RequestPermissionResponse {
  if (typeof answer === 'object' && 'outcome' in answer) return answer;
  if (typeof answer === 'object') return { outcome: { outcome: 'selected', optionId: answer.optionId } };
  const pick = (...kinds: PermissionOption['kind'][]) => kinds.map((kind) => options.find((option) => option.kind === kind)).find(Boolean);
  const option = answer === 'allow' ? pick('allow_once', 'allow_always') : answer === 'reject' ? pick('reject_once', 'reject_always') : undefined;
  return option ? { outcome: { outcome: 'selected', optionId: option.optionId } } : { outcome: { outcome: 'cancelled' } };
}

// MARK: Tool calls, merged

/** A tool call with every update merged in (ACP's updates are upserts by `toolCallId`). */
export interface ToolCallState {
  toolCallId: string;
  title: string;
  name?: string | null;
  kind?: ToolKind | null;
  status?: ToolCallStatus | null;
  content?: ToolCallContent[] | null;
  locations?: ToolCallLocation[] | null;
  rawInput?: unknown;
  rawOutput?: unknown;
  _meta?: Meta | null;
}

function mergeToolCall(calls: Map<string, ToolCallState>, update: SessionUpdate): void {
  if (update.sessionUpdate !== 'tool_call' && update.sessionUpdate !== 'tool_call_update') return;
  const { sessionUpdate: _, ...fields } = update;
  const known = calls.get(fields.toolCallId);
  const defined = Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined));
  calls.set(fields.toolCallId, { title: '', ...known, ...defined } as ToolCallState);
}

function chunkText(update: SessionUpdate, kind: 'agent_message_chunk' | 'agent_thought_chunk'): string {
  return update.sessionUpdate === kind && update.content.type === 'text' ? update.content.text : '';
}

// MARK: Turns

/** What a turn yields while it runs, discriminated by `type`. */
export type TurnEvent =
  | { type: 'update'; update: SessionUpdate }
  /** The provider is busy: the turn waits its place in Agneta's queue. */
  | { type: 'queued'; position: number; waitingFor?: QueuedParams['waitingFor'] }
  /** The provider's limit stopped the turn; the turn then fails with `RateLimitedError`. */
  | { type: 'rateLimited'; details: RateLimitDetails }
  /** The session was stopped while the turn ran; `detail` says why when Agneta did (`reach`: the socket or port). */
  | { type: 'stopped'; stoppedBy: StoppedBy; detail?: string };

export interface TurnResult {
  stopReason: StopReason;
  /** The agent's reply text (its `agent_message_chunk` text, joined). */
  text: string;
  /** Its reasoning text, where the engine sends it. */
  thought: string;
  /** Usage from the engine's records (`_meta["agneta/usage"]`), or null where Agneta didn't add it. */
  usage: AgnetaUsage | null;
  /** The engine's own figure for the turn (ACP's `usage`), passed through. */
  engineUsage: Usage | null;
  /** The policy limit that stopped the turn, or null. */
  limit: LimitHit | null;
  /** Ended by `session/cancel`, the user's Stop, or a time or cost limit. */
  cancelled: boolean;
  /** Set when the session was stopped while the turn ran. */
  stoppedBy: StoppedBy | null;
  /** The turn's tool calls, each with its updates merged. */
  toolCalls: ToolCallState[];
  /** The prompt's result as Agneta sent it. */
  raw: PromptResult;
}

export class Turn implements PromiseLike<TurnResult>, AsyncIterable<TurnEvent> {
  readonly session: Session;
  /** Resolves with the result, or rejects with the typed error. */
  readonly result: Promise<TurnResult>;
  #events: TurnEvent[] = [];
  #wakers = new Set<() => void>();
  #done = false;
  #error: unknown = null;
  #text = '';
  #thought = '';
  #toolCalls = new Map<string, ToolCallState>();
  #stoppedBy: StoppedBy | null = null;

  /** @internal */
  constructor(session: Session, run: () => Promise<PromptResult>) {
    this.session = session;
    this.result = run().then((raw) => this.#finish(raw), (error) => { this.#fail(error); throw error; });
    // Iterating without awaiting is fine: the error reaches the iterator, not an unhandled rejection.
    this.result.catch(() => {});
  }

  /** The reply so far. */
  get text(): string { return this.#text; }
  /** The reasoning so far, where the engine sends it. */
  get thought(): string { return this.#thought; }
  /** The tool calls so far, with their updates merged. */
  get toolCalls(): ToolCallState[] { return [...this.#toolCalls.values()]; }
  /** Every event so far. */
  get events(): readonly TurnEvent[] { return this.#events; }
  get done(): boolean { return this.#done; }

  then<A = TurnResult, B = never>(onFulfilled?: ((value: TurnResult) => A | PromiseLike<A>) | null, onRejected?: ((reason: any) => B | PromiseLike<B>) | null): Promise<A | B> {
    return this.result.then(onFulfilled, onRejected);
  }

  catch<B = never>(onRejected?: ((reason: any) => B | PromiseLike<B>) | null): Promise<TurnResult | B> {
    return this.result.catch(onRejected);
  }

  finally(onFinally?: (() => void) | null): Promise<TurnResult> {
    return this.result.finally(onFinally);
  }

  /** Ends the turn (`session/cancel`): it finishes with `cancelled`. */
  cancel(): void {
    if (!this.#done) this.session.cancel();
  }

  /** Adds input to the running turn (`agneta/steer`). */
  steer(input: PromptInput, options?: RequestOptions): Promise<SteerResult> {
    if (this.#done || this.session.turn !== this) {
      return Promise.reject(new NoTurnRunningError({ code: -32010, message: 'This turn has ended' }, 'agneta/steer'));
    }
    return this.session.steer(input, options);
  }

  /** Every event of the turn, from the first, until it ends. Throws the turn's error, if it fails, after its events. */
  async *[Symbol.asyncIterator](): AsyncIterator<TurnEvent> {
    let index = 0;
    for (;;) {
      while (index < this.#events.length) yield this.#events[index++]!;
      if (this.#done) {
        if (this.#error) throw this.#error;
        return;
      }
      await new Promise<void>((resolve) => this.#wakers.add(resolve));
    }
  }

  /** The session updates only. */
  async *updates(): AsyncGenerator<SessionUpdate> {
    for await (const event of this) if (event.type === 'update') yield event.update;
  }

  /** The reply as it streams: each `agent_message_chunk`'s text. */
  async *textStream(): AsyncGenerator<string> {
    for await (const event of this) {
      if (event.type !== 'update') continue;
      const text = chunkText(event.update, 'agent_message_chunk');
      if (text) yield text;
    }
  }

  /** @internal */
  push(event: TurnEvent): void {
    if (this.#done) return;
    if (event.type === 'update') {
      this.#text += chunkText(event.update, 'agent_message_chunk');
      this.#thought += chunkText(event.update, 'agent_thought_chunk');
      mergeToolCall(this.#toolCalls, event.update);
    }
    if (event.type === 'stopped') this.#stoppedBy = event.stoppedBy;
    this.#events.push(event);
    this.#wake();
  }

  #wake(): void {
    const wakers = [...this.#wakers];
    this.#wakers.clear();
    for (const wake of wakers) wake();
  }

  #finish(raw: PromptResult): TurnResult {
    this.#done = true;
    this.#wake();
    const meta = raw?._meta ?? {};
    const limit = meta['agneta/limit'] ?? null;
    return {
      stopReason: raw?.stopReason ?? 'end_turn',
      text: this.#text,
      thought: this.#thought,
      usage: meta['agneta/usage'] ?? null,
      engineUsage: raw?.usage ?? null,
      limit,
      cancelled: raw?.stopReason === 'cancelled',
      stoppedBy: this.#stoppedBy ?? (limit?.sessionEnded ? 'limit' : null),
      toolCalls: this.toolCalls,
      raw
    };
  }

  #fail(error: unknown): void {
    this.#done = true;
    this.#error = error;
    this.#wake();
  }
}

// MARK: Sessions

/** How a session ended. */
export type SessionEnd =
  | { reason: 'closed' }
  /**
   * Stopped in Agneta (`agneta/sessionStopped`): by the user, by the engine exiting, by a limit Agneta enforced, or
   * because a contained session's socket or port is no longer served by your app (`reach`, with why in `detail`).
   */
  | { reason: 'stopped'; stoppedBy: StoppedBy; detail?: string }
  /** The connection closed: Agneta ends a connection's sessions with it. Load the session again to go on. */
  | { reason: 'disconnected'; error: ConnectionClosedError };

export type SessionEvents = {
  /** Every `session/update`, during a turn or not. */
  update: [update: SessionUpdate];
  queued: [position: number, waitingFor?: QueuedParams['waitingFor']];
  rateLimited: [details: RateLimitDetails];
  /** Live trace records (`agneta/trace`), when the session asked for them. */
  trace: [records: TraceRecord[]];
  /** Live delivery stopped: read on from `after` with `readTrace`. */
  traceOverflow: [after: number];
  /** The engine's settings changed (a reply to `setConfigOption`, or `config_option_update`). */
  configOptions: [options: SessionConfigOption[]];
  mode: [modeId: string];
  ended: [end: SessionEnd];
};

/** What sessions need of their client. @internal */
export interface SessionHost {
  readonly connection: Connection;
  timeouts: { request: number; prompt: number; session: number };
  forget(session: Session): void;
  fork(source: Session, options: ForkOptions): Promise<Session>;
  readTrace(sessionId: string, params?: Omit<TraceReadParams, 'sessionId'>, options?: RequestOptions): Promise<TraceReadResult>;
  traceRecords(sessionId: string, params?: TraceRecordsOptions): AsyncGenerator<TraceRecord>;
}

/** What `session/new`, `session/load` and `agneta/fork` take. Everything is optional. */
export interface SessionOptionsBase {
  /** Absolute. Default: the app's own workspace (`access.workspace`). */
  cwd?: string;
  /** `_meta["agneta/policy"]`. Without one: workspace tools in `cwd`, the grant's sandbox, ask-app approval. */
  policy?: Policy;
  /** `_meta["agneta/task"]`: a title (and stop warning) for Agneta's menu. A string is the title. */
  task?: TaskInfo | string;
  /** `_meta["agneta/instructions"]`. */
  instructions?: string;
  /**
   * `_meta["agneta/appTools"]`: `'always'` puts your MCP tools (descriptions and schemas) in the model's context from the
   * first request, on every engine; Claude Code otherwise defers them behind its tool search. Load and fork keep the
   * original's unless given.
   */
  appTools?: AppToolsLoad;
  /** `_meta["agneta/trace"]`: `true` for live trace records. */
  trace?: boolean | TraceDelivery;
  /** The app's own tool servers: loopback Streamable HTTP, each with a bearer (`httpMcpServer`). */
  mcpServers?: McpServerHttp[];
  /** More `_meta` keys, merged over the ones above. */
  meta?: SessionRequestMeta;
  /** More top-level params, sent as they are. */
  params?: Record<string, unknown>;
  /** Answers this session's permission requests (else the client's handler, else they're declined). */
  permissions?: PermissionHandler;
  /**
   * Listeners attached before the session is returned, so they also get what arrived while it opened: the first live
   * trace records, say (`{ trace: (records) => … }`). Updates from then are in `history` too.
   */
  on?: { [Name in keyof SessionEvents]?: (...args: SessionEvents[Name]) => void };
  /**
   * While the engine downloads (-32015), try again until it's ready: `true` (the default, up to 10 minutes), a number
   * of milliseconds, or `false` to fail at once with `EngineDownloadingError`.
   */
  waitForDownload?: boolean | number;
  /** Download progress while waiting. */
  onDownloadProgress?: (progress: DownloadProgress) => void;
  timeout?: number;
  signal?: AbortSignal;
}

export interface NewSessionOptions extends SessionOptionsBase {
  /** The provider: one of `access.providers` ids. Default: the first. */
  account?: string;
  /** The engine: one of that provider's `engines`. Default: its `defaultEngine` (one that can provide the sandbox asked for). */
  engine?: EngineId;
}

export type LoadSessionOptions = SessionOptionsBase;
export type ForkOptions = SessionOptionsBase;

export interface TraceRecordsOptions {
  after?: number;
  types?: TraceRecordType[];
  /** Records per page (up to 5,000). */
  limit?: number;
  signal?: AbortSignal;
}

export class Session extends Emitter<SessionEvents> {
  /** Agneta's session id (never the engine's). */
  readonly id: string;
  /** The reply to `session/new`, `session/load` or `agneta/fork`, as Agneta sent it. */
  readonly raw: SessionResult;
  /** Updates that arrived while the session opened: a loaded session's whole conversation, replayed. */
  readonly history: SessionUpdate[];
  #host: SessionHost;
  #turn: Turn | null = null;
  #ended: SessionEnd | null = null;
  #configOptions: SessionConfigOption[];
  #modes: SessionModeState | null;
  #permissions: PermissionHandler | undefined;

  /** @internal */
  constructor(host: SessionHost, id: string, raw: SessionResult, history: SessionUpdate[], permissions?: PermissionHandler,
    listeners?: SessionOptionsBase['on']) {
    super();
    for (const [name, listener] of Object.entries(listeners ?? {})) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      if (listener) this.on(name as keyof SessionEvents, listener as (...args: any[]) => void);
    }
    this.#host = host;
    this.id = id;
    this.raw = raw;
    this.history = history;
    this.#configOptions = raw.configOptions ?? [];
    this.#modes = raw.modes ?? null;
    this.#permissions = permissions;
    for (const update of history) this.#track(update);
  }

  /** The account (provider) it runs on. */
  get account(): string { return this.raw._meta?.agneta?.account; }
  /** What its engine can do. Check before offering steering, forking or a cost limit. */
  get capabilities(): SessionCapabilities { return this.raw._meta?.agneta?.capabilities; }
  get engine(): EngineId { return this.capabilities?.engine; }
  /** The mode the task really got. */
  get sandbox(): SandboxLevel { return this.raw._meta?.agneta?.sandbox; }
  /** How the engine offers your MCP tools: the `load` it runs with, and whether they're in the model's first request. */
  get appTools(): SessionResultAgneta['appTools'] { return this.raw._meta?.agneta?.appTools; }
  /** The groups of the engine's own tools it has (`policy.builtins` applied); null when Agneta doesn't know. */
  get builtins(): SessionResultAgneta['builtins'] { return this.raw._meta?.agneta?.builtins; }
  /** Whether it has an engine process of its own. */
  get dedicatedEngine(): boolean { return this.raw._meta?.agneta?.dedicatedEngine === true; }
  /** Opened with `session/load`. */
  get resumed(): boolean { return this.raw._meta?.agneta?.resumed === true; }
  /** The task it was forked from, if any. */
  get forkOf(): string | undefined { return this.raw._meta?.agneta?.forkOf; }

  /** The engine's settings (model, effort, …) as they are now. */
  get configOptions(): SessionConfigOption[] { return this.#configOptions; }
  /** The engine's modes, if it has any. */
  get modes(): SessionModeState | null { return this.#modes; }
  /** The model setting, found by its category, with its choices. */
  get model(): ConfigSetting | undefined { return configSetting(findConfigOption(this.#configOptions, 'model')); }
  /** The reasoning-effort setting (`thought_level`), where the engine has one. */
  get effort(): ConfigSetting | undefined { return configSetting(findConfigOption(this.#configOptions, 'thought_level')); }

  /** The running turn, if any. */
  get turn(): Turn | null { return this.#turn; }
  /** How it ended, or null while it's open. */
  get ended(): SessionEnd | null { return this.#ended; }

  /** The raw connection, for anything the session methods don't cover. */
  get connection(): Connection { return this.#host.connection; }

  /**
   * Sends a prompt (`session/prompt`) and returns the turn: `await` it for the result, or `for await` its events.
   * One turn at a time: while one runs, this throws `TurnBusyError` (steer the running turn instead).
   * An aborted `signal` cancels the turn, which then ends as `cancelled`.
   */
  prompt(input: PromptInput, options: RequestOptions & { meta?: Meta } = {}): Turn {
    if (this.#turn && !this.#turn.done) {
      throw new TurnBusyError({ code: -32011, message: 'A turn is already running in this session; steer it or wait' }, 'session/prompt');
    }
    const { signal, meta } = options;
    const turn = new Turn(this, () => {
      const onAbort = () => this.cancel();
      signal?.addEventListener('abort', onAbort, { once: true });
      if (signal?.aborted) queueMicrotask(onAbort);
      return this.#request('session/prompt', { sessionId: this.id, prompt: promptBlocks(input), ...(meta ? { _meta: meta } : {}) },
        { timeout: options.timeout ?? this.#host.timeouts.prompt })
        // Timed out here: the turn still runs in Agneta, so it's cancelled there too (else the next prompt is busy).
        .catch((error) => { if (error instanceof TimeoutError) this.cancel(); throw error; })
        .finally(() => signal?.removeEventListener('abort', onAbort));
    });
    this.#turn = turn;
    const release = () => { if (this.#turn === turn) this.#turn = null; };
    turn.result.then(release, release);
    return turn;
  }

  /** Adds input to the running turn (`agneta/steer`). Rejects with `NoTurnRunningError` when none runs. */
  steer(input: PromptInput, options?: RequestOptions): Promise<SteerResult> {
    return this.#request('agneta/steer', { sessionId: this.id, prompt: promptBlocks(input) }, options);
  }

  /** Ends the running turn (`session/cancel`); it finishes as `cancelled`. A turn waiting in the queue is taken out. */
  cancel(): void {
    if (this.#ended) return;
    try { this.#host.connection.notify('session/cancel', { sessionId: this.id }); } catch {}
  }

  /** Ends the session (`session/close`) and, if it has one of its own, its engine. */
  async close(options?: RequestOptions): Promise<void> {
    if (this.#ended) return;
    try {
      await this.#request('session/close', { sessionId: this.id }, options);
    } catch (error) {
      // A retry can reach Agneta after it closed the session but the first acknowledgement was lost.
      if (!(error instanceof InvalidParamsError && error.message === 'Unknown session')) throw error;
    }
    this.end({ reason: 'closed' });
  }

  /** Sets one of the engine's settings, between turns. Resolves with the settings as they are now. */
  async setConfigOption(configId: string, value: string | boolean, options?: RequestOptions): Promise<SessionConfigOption[]> {
    const result = await this.#request('session/set_config_option', { sessionId: this.id, configId, value }, options);
    if (Array.isArray(result?.configOptions)) this.#setConfigOptions(result.configOptions);
    else this.#setConfigOptions(this.#configOptions.map((option) => option.id === configId ? { ...option, currentValue: value } as SessionConfigOption : option));
    return this.#configOptions;
  }

  /** Sets the model, found by its category. Throws when the engine offers no model setting. */
  setModel(value: string, options?: RequestOptions): Promise<SessionConfigOption[]> {
    return this.#setCategory('model', value, options);
  }

  /** Sets the reasoning effort (`thought_level`). Throws when the engine offers none. */
  setEffort(value: string, options?: RequestOptions): Promise<SessionConfigOption[]> {
    return this.#setCategory('thought_level', value, options);
  }

  /** Changes the engine's mode (`session/set_mode`). Agneta refuses modes that would leave what it set up. */
  async setMode(modeId: string, options?: RequestOptions): Promise<void> {
    await this.#request('session/set_mode', { sessionId: this.id, modeId }, options);
    if (this.#modes) this.#modes = { ...this.#modes, currentModeId: modeId };
    this.emit('mode', modeId);
  }

  /** Sets the instructions between turns (`agneta/instructions/set`), where `capabilities.instructionsBetweenTurns`. */
  async setInstructions(text: string, options: { mode?: 'replace' | 'append'; key?: string } & RequestOptions = {}): Promise<void> {
    const { mode, key, ...request } = options;
    await this.#request('agneta/instructions/set', { sessionId: this.id, text, ...(mode ? { mode } : {}), ...(key ? { key } : {}) }, request);
  }

  /** A new task with a copy of this one's conversation (`agneta/fork`), where `capabilities.fork`. */
  fork(options: ForkOptions = {}): Promise<Session> {
    return this.#host.fork(this, options);
  }

  /** One page of this task's trace (`agneta/trace/read`). */
  readTrace(params: Omit<TraceReadParams, 'sessionId'> = {}, options?: RequestOptions): Promise<TraceReadResult> {
    return this.#host.readTrace(this.id, params, options);
  }

  /** Every trace record after `after`, page by page, until the trace has no more for now. */
  traceRecords(options: TraceRecordsOptions = {}): AsyncGenerator<TraceRecord> {
    return this.#host.traceRecords(this.id, options);
  }

  /** Answers this session's permission requests. Returns a function that removes the handler. */
  onPermission(handler: PermissionHandler): () => void {
    this.#permissions = handler;
    return () => { if (this.#permissions === handler) this.#permissions = undefined; };
  }

  /** @internal */
  get permissionHandler(): PermissionHandler | undefined { return this.#permissions; }

  /** @internal Routes a notification for this session. */
  receive(method: string, params: any): void {
    switch (method) {
      case 'session/update': {
        const update = params?.update as SessionUpdate | undefined;
        if (!update || typeof update !== 'object') return;
        this.#track(update);
        this.#turn?.push({ type: 'update', update });
        this.emit('update', update);
        return;
      }
      case 'agneta/queued':
        this.#turn?.push({ type: 'queued', position: params.position, waitingFor: params.waitingFor });
        this.emit('queued', params.position, params.waitingFor);
        return;
      case 'agneta/rateLimited': {
        const details: RateLimitDetails = { account: params.account, message: params.message, resetsAt: params.resetsAt ?? null };
        this.#turn?.push({ type: 'rateLimited', details });
        this.emit('rateLimited', details);
        return;
      }
      case 'agneta/sessionStopped': {
        // Agneta's reason, when it gives one, is the detail: `reason` already says how the session ended.
        const detail = typeof params.reason === 'string' ? { detail: params.reason } : {};
        this.#turn?.push({ type: 'stopped', stoppedBy: params.stoppedBy, ...detail });
        this.end({ reason: 'stopped', stoppedBy: params.stoppedBy, ...detail });
        return;
      }
      case 'agneta/trace':
        if (Array.isArray(params.records) && params.records.length) this.emit('trace', params.records);
        if (params.overflow && typeof params.overflow.after === 'number') this.emit('traceOverflow', params.overflow.after);
        return;
    }
  }

  /** @internal */
  end(end: SessionEnd): void {
    if (this.#ended) return;
    this.#ended = end;
    this.#host.forget(this);
    this.emit('ended', end);
  }

  #track(update: SessionUpdate): void {
    if (update.sessionUpdate === 'config_option_update' && Array.isArray(update.configOptions)) this.#setConfigOptions(update.configOptions);
    if (update.sessionUpdate === 'current_mode_update' && typeof update.currentModeId === 'string') {
      if (this.#modes) this.#modes = { ...this.#modes, currentModeId: update.currentModeId };
      this.emit('mode', update.currentModeId);
    }
  }

  #setConfigOptions(options: SessionConfigOption[]): void {
    this.#configOptions = options;
    this.emit('configOptions', options);
  }

  async #setCategory(category: string, value: string, options?: RequestOptions): Promise<SessionConfigOption[]> {
    const option = findConfigOption(this.#configOptions, category);
    if (!option) throw new TypeError(`${this.engine ?? 'This engine'} offers no ${category === 'thought_level' ? 'reasoning effort' : category} setting in this session.`);
    return this.setConfigOption(option.id, value, options);
  }

  #request<M extends 'session/prompt' | 'agneta/steer' | 'session/close' | 'session/set_config_option' | 'session/set_mode' | 'agneta/instructions/set'>(
    method: M, params: AgnetaRequests[M]['params'], options?: RequestOptions
  ): Promise<AgnetaRequests[M]['result']> {
    if (this.#ended) {
      return Promise.reject(this.#ended.reason === 'disconnected' ? this.#ended.error
        : new InvalidParamsError({ code: -32602, message: 'This session handle has ended' }, method));
    }
    return this.#host.connection.request(method, params, { timeout: this.#host.timeouts.request, ...options });
  }
}

/** A loopback tool server's registration, with its bearer in an Authorization header. */
export function httpMcpServer(options: { name: string; url: string; token?: string; headers?: Record<string, string> }): McpServerHttp {
  const headers = Object.entries(options.headers ?? {}).map(([name, value]) => ({ name, value }));
  if (options.token) headers.unshift({ name: 'Authorization', value: `Bearer ${options.token}` });
  return { type: 'http', name: options.name, url: options.url, headers };
}
