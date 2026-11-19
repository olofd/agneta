// The high-level client: connect (opening Agneta when the user agrees), pair or initialize with a kept token, keep the
// access report current, open sessions, and route Agneta's notifications and permission requests to them.
import type { Implementation, SessionUpdate } from './acp.js';
import { Connection, type OpenOptions, type RequestOptions, type WebSocketConstructor } from './connection.js';
import { Emitter } from './emitter.js';
import {
  AbortedError, ConnectionClosedError, EngineDownloadingError, MethodNotFoundError, NeedsPairingError, NotRunningError, ProtocolError,
  UnsupportedEnvironmentError, type DownloadProgress
} from './errors.js';
import {
  builds, protocolVersion, type Access, type AgnetaNotifications, type AgnetaRequests, type Build, type Catalog,
  type InitializeResult, type PairingCodeParams, type PairingScope, type PairResult, type ProviderKind, type QueuedParams,
  type RateLimitedParams, type SessionRequestMeta, type SessionResult, type SessionStoppedParams, type TraceReadParams,
  type TraceReadResult, type TraceRecord
} from './protocol.js';
import {
  permissionResponse, Session, type ForkOptions, type LoadSessionOptions, type NewSessionOptions, type PermissionHandler,
  type SessionHost, type SessionOptionsBase, type TraceRecordsOptions
} from './session.js';
import { memoryTokenStore, type TokenStore } from './tokens.js';

export interface Timeouts {
  /** Most requests. Default 30 s. */
  request: number;
  /** The WebSocket upgrade. Default 5 s. */
  connect: number;
  /** `agneta/pair`: past Agneta's 5-minute approval window. Default 310 s. */
  pair: number;
  /** `session/new`, `session/load`, `agneta/fork`, each attempt (an engine starts within 60 s). Default 180 s. */
  session: number;
  /** `session/prompt`. Default none (0): a policy's `maxSeconds` limits a turn. */
  prompt: number;
}

export interface ReconnectOptions {
  /** First delay; it doubles up to `maxDelay`. Default 1 s. */
  delay?: number;
  /** Default 30 s. */
  maxDelay?: number;
}

export interface AgnetaClientOptions {
  /** The app's name, shown in Agneta's approval window and menu. */
  name: string;
  /** What the app will need (`agneta/pair`'s scope). Default: app-only tools, no folders. */
  scope?: PairingScope;
  /** `release` (port 47321, the default) or `dev` (47331). */
  build?: Build;
  /** Another port, such as an isolated development instance's. */
  port?: number;
  /** The whole address, overriding `build` and `port`. */
  url?: string;
  /** The URL that opens this Agneta. Default: the build's (`agneta://open` or `agneta-dev://open`); null for none. */
  openURL?: string | null;
  /** Where the token from Always Allow is kept. Default: memory only. */
  tokens?: TokenStore;
  /** Sent in `initialize`. Default: the app's name. */
  clientInfo?: Implementation;
  /**
   * When Agneta isn't running: ask the user whether to open it and, when they say yes, open it (`openURL`), resolving to
   * whether it was opened. The client then waits for it and connects. Never open Agneta without asking.
   */
  launch?: (agneta: { name: string; url: string; openURL: string | null }) => boolean | Promise<boolean>;
  /** How long to wait for Agneta after `launch` opened it. Default 20 s. */
  launchTimeout?: number;
  /** Answers permission requests (`approval: "ask-app"`) for sessions without their own handler. Default: declined. */
  permissions?: PermissionHandler;
  /** Reconnect by itself, quietly, when a connection with a remembered token drops. Default off. */
  reconnect?: boolean | ReconnectOptions;
  timeouts?: Partial<Timeouts>;
  /** A WebSocket class, where there's no global one. */
  WebSocket?: WebSocketConstructor;
}

/**
 * `disconnected` → `connecting` (opening, or open and not paired yet) → `pairing` (the approval window is up) →
 * `connected` (initialized); `reconnecting` while waiting to reconnect.
 */
export type ClientState = 'disconnected' | 'connecting' | 'pairing' | 'connected' | 'reconnecting';

export type ClientEvents = {
  state: [state: ClientState];
  /** Show this code while pairing waits: the user allows the app only if it matches Agneta's. */
  pairingCode: [code: string, params: PairingCodeParams];
  /** Before pairing: a provider was connected or removed, or an engine changed. */
  catalogChanged: [catalog: Catalog];
  /** What the app may use changed. `client.access` is already the new one. */
  accessChanged: [access: Access];
  /** `connect({setup})` showed Agneta's window for connecting a provider (of `kind`), and waits until one is connected. */
  setup: [kind: ProviderKind | undefined];
  /** Paired: `remembered` says whether the token was kept. */
  paired: [result: PairResult];
  /** Agneta no longer accepts the kept token, which has been forgotten. Pair again when the user asks to connect. */
  accessRemoved: [error: NeedsPairingError];
  /** Every notification from Agneta, on every connection. */
  notification: [method: string, params: unknown];
  /** The connection closed. Its sessions have ended. */
  disconnected: [error: ConnectionClosedError];
  /** Waiting `delay` ms before reconnect attempt `attempt`. */
  reconnecting: [attempt: number, delay: number];
  reconnected: [access: Access];
  /** A task's engine is downloading; the client tries again shortly. */
  engineDownloading: [progress: DownloadProgress];
  queued: [params: QueuedParams];
  rateLimited: [params: RateLimitedParams];
  sessionStopped: [params: SessionStoppedParams];
  /** A permission handler threw: the request was declined. */
  error: [error: unknown];
};

export interface ConnectOptions {
  /**
   * `if-needed` (the default) pairs when there's no usable token; `never` stops there with `NeedsPairingError` (a quiet
   * connect at launch, which never opens the approval window); `always` pairs even with a usable token (to change the scope).
   */
  pair?: 'if-needed' | 'never' | 'always';
  /**
   * Before pairing, when no provider (of this kind, for a kind) is connected in Agneta: show Agneta's window for
   * connecting one (`agneta/setup`) and wait until one is. Default off: the approval window offers it too.
   */
  setup?: boolean | ProviderKind;
  /** The scope to pair with, instead of the client's. */
  scope?: PairingScope;
  signal?: AbortSignal;
}

const defaults: Timeouts = { request: 30_000, connect: 5000, pair: 310_000, session: 180_000, prompt: 0 };

export class AgnetaClient extends Emitter<ClientEvents> {
  readonly options: AgnetaClientOptions;
  /** The WebSocket address. */
  readonly url: string;
  readonly openURL: string | null;
  /** What the app calls this Agneta: "Agneta", "Agneta Dev", or "Agneta on port …". */
  readonly agnetaName: string;
  readonly timeouts: Timeouts;
  readonly tokens: TokenStore;
  #connection: Connection | null = null;
  #state: ClientState = 'disconnected';
  #access: Access | null = null;
  #initialized: InitializeResult | null = null;
  #token: string | null = null;
  #remembered = false;
  #pairingCode: string | null = null;
  #sessions = new Map<string, Session>();
  /**
   * Notifications for sessions not known yet: ones that arrive before `session/new` answers (updates, the first live
   * trace records), and a load's replay. Given to the session when it opens.
   */
  #early = new Map<string, Array<{ method: string; params: any }>>();
  #reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  #connecting: Promise<Access> | null = null;
  #opening: Promise<Connection> | null = null;
  #closing = false;
  /** Reconnecting: never ask `launch` (Agneta quit; it comes back when the user opens it). */
  #quiet = false;

  constructor(options: AgnetaClientOptions) {
    super();
    if (!options || typeof options.name !== 'string' || !options.name) throw new TypeError('AgnetaClient needs the app\'s name.');
    this.options = options;
    const build = builds[options.build ?? 'release'];
    const port = options.port ?? build.port;
    this.url = options.url ?? `ws://127.0.0.1:${port}/acp`;
    const known = Object.values(builds).find((entry) => entry.port === port && !options.url);
    this.openURL = options.openURL !== undefined ? options.openURL : known?.openURL ?? null;
    this.agnetaName = known?.name ?? (options.url ? 'Agneta' : `Agneta on port ${port}`);
    this.timeouts = { ...defaults, ...options.timeouts };
    this.tokens = options.tokens ?? memoryTokenStore();
  }

  get state(): ClientState { return this.#state; }
  /** The raw connection while connected (or connecting): send any request, read every message. */
  get connection(): Connection | null { return this.#connection; }
  /** What the app may use, kept current by `agneta/accessChanged`. Null until connected. */
  get access(): Access | null { return this.#access; }
  /** The app's own workspace. */
  get workspace(): string | undefined { return this.#access?.workspace; }
  /** `initialize`'s result. */
  get initializeResult(): InitializeResult | null { return this.#initialized; }
  /** Agneta's extensions, from `initialize`. */
  get extensions(): readonly string[] { return this.#initialized?._meta?.agneta?.extensions ?? []; }
  /** Whether this connection's access is remembered (Always Allow); still so in `disconnected` listeners. */
  get remembered(): boolean { return this.#remembered; }
  /** The pairing code while pairing waits, for an app Agneta can't verify. */
  get pairingCode(): string | null { return this.#pairingCode; }
  /** The open sessions. */
  get sessions(): Session[] { return [...this.#sessions.values()]; }
  session(id: string): Session | undefined { return this.#sessions.get(id); }

  // MARK: Connecting

  /**
   * Connects and resolves with what the app may use: with the kept token when there is one, else by pairing (Agneta's
   * approval window). A kept token Agneta no longer accepts is forgotten (`accessRemoved`). When Agneta isn't running,
   * `launch` is asked; without it, this rejects with `NotRunningError`.
   */
  connect(options: ConnectOptions = {}): Promise<Access> {
    if (this.#state === 'connected' && this.#connection?.isOpen && this.#access && options.pair !== 'always') return Promise.resolve(this.#access);
    // One connect at a time: a second call while one runs gets the same outcome.
    if (this.#connecting) return this.#connecting;
    const connecting = this.#connect(options).finally(() => { if (this.#connecting === connecting) this.#connecting = null; });
    this.#connecting = connecting;
    return connecting;
  }

  async #connect(options: ConnectOptions): Promise<Access> {
    this.#closing = false;
    this.#cancelReconnect();
    // Already connected (pairing again for a wider scope): a failure, the user's Don't Allow included, keeps what works.
    const wasConnected = this.#state === 'connected' && this.#connection?.isOpen === true && this.#access !== null;
    const connection = await this.open({ signal: options.signal });
    try {
      const pair = options.pair ?? 'if-needed';
      const kept = pair === 'always' ? null : await this.tokens.load();
      let initialized = false;
      if (kept) {
        try {
          await this.initialize(kept, { signal: options.signal });
          this.#remembered = true;
          initialized = true;
        } catch (error) {
          if (!(error instanceof NeedsPairingError)) throw error;
          await this.tokens.clear();
          this.emit('accessRemoved', error);
          if (pair === 'never') throw error;
        }
      }
      if (!initialized) {
        if (pair === 'never') throw new NeedsPairingError({ code: -32001, message: 'Pair with Agneta first', data: { agneta: { needsPairing: true } } }, 'initialize');
        if (options.setup) await this.#setUpProvider(options.setup === true ? undefined : options.setup, options.signal);
        await this.pair(options.scope ?? this.options.scope, { signal: options.signal });
      }
      this.#setState('connected');
      return this.#access!;
    } catch (error) {
      if (this.#connection === connection) {
        if (wasConnected && connection.isOpen) this.#setState('connected');
        else this.#drop(connection);
      }
      throw error;
    }
  }

  /**
   * Opens the WebSocket only (for `agneta/catalog` and `agneta/setup` before pairing). Asks `launch` when Agneta isn't
   * running. Resolves with the raw connection; reuses an open one.
   */
  open(options: { signal?: AbortSignal } = {}): Promise<Connection> {
    if (this.#connection?.isOpen) return Promise.resolve(this.#connection);
    if (this.#opening) return this.#opening;
    const opening = this.#openSocket(options).finally(() => { if (this.#opening === opening) this.#opening = null; });
    this.#opening = opening;
    return opening;
  }

  async #openSocket(options: { signal?: AbortSignal }): Promise<Connection> {
    if (!this.options.WebSocket && typeof (globalThis as { document?: unknown }).document !== 'undefined') {
      throw new UnsupportedEnvironmentError('Agneta refuses connections from web pages (anything sending an Origin header). Connect from Node or Electron\'s main process.');
    }
    this.#setState('connecting');
    const open: OpenOptions = {
      url: this.url, openURL: this.openURL, connectTimeout: this.timeouts.connect, requestTimeout: this.timeouts.request,
      ...(this.options.WebSocket ? { WebSocket: this.options.WebSocket } : {}), ...(options.signal ? { signal: options.signal } : {})
    };
    let connection: Connection;
    try {
      connection = await Connection.open(open);
    } catch (error) {
      if (!(error instanceof NotRunningError) || !this.options.launch || this.#quiet) {
        this.#setState('disconnected');
        throw error;
      }
      const launched = await this.options.launch({ name: this.agnetaName, url: this.url, openURL: this.openURL });
      if (!launched) {
        this.#setState('disconnected');
        throw error;
      }
      connection = await this.#waitForAgneta(open, options.signal);
    }
    this.#attach(connection);
    return connection;
  }

  /** `agneta/catalog`: what Agneta offers any app, before pairing too. Opens the connection if needed. */
  async catalog(options?: RequestOptions): Promise<Catalog> {
    const connection = await this.open({ signal: options?.signal });
    return connection.request('agneta/catalog', {}, options);
  }

  /**
   * `agneta/setup`: Agneta comes forward with its window for connecting a provider, naming the app. Ask only when the
   * user asked to connect. Wait for it with `waitForProvider`.
   */
  async setup(params: { kind?: ProviderKind; name?: string } = {}, options?: RequestOptions): Promise<{ shown: boolean }> {
    const connection = await this.open({ signal: options?.signal });
    return connection.request('agneta/setup', { name: params.name ?? this.options.name, ...(params.kind ? { kind: params.kind } : {}) }, options);
  }

  /** Resolves with the catalog once a provider (of `kind`, when given) is connected: now, or at an `agneta/catalogChanged`. */
  async waitForProvider(kind?: ProviderKind, options: { signal?: AbortSignal; timeout?: number } = {}): Promise<Catalog> {
    const has = (catalog: Catalog) => kind ? catalog.providers.some((provider) => provider.kind === kind && provider.connected) : catalog.connected;
    const signals = [options.signal, options.timeout ? AbortSignal.timeout(options.timeout) : undefined].filter((signal): signal is AbortSignal => !!signal);
    const signal = signals.length > 1 ? AbortSignal.any(signals) : signals[0];
    // Ends both waits below when this returns, so no listener is left behind.
    const done = new AbortController();
    const listening = signal ? AbortSignal.any([signal, done.signal]) : done.signal;
    try {
      // Listen first, so a change between the catalog's answer and the wait isn't missed.
      const changed = this.next('catalogChanged', { filter: (catalog) => has(catalog), signal: listening });
      changed.catch(() => {});
      const closed = this.next('disconnected', { signal: listening });
      closed.catch(() => {});
      const now = await this.catalog(signal ? { signal } : {});
      if (has(now)) return now;
      return await Promise.race([changed.then(([catalog]) => catalog), closed.then(([error]) => { throw error; })])
        .catch((error) => { throw signal?.aborted ? new AbortedError('waitForProvider', { cause: signal.reason }) : error; });
    } finally {
      done.abort();
    }
  }

  /**
   * Pairs (`agneta/pair`): Agneta's approval window shows the scope. Show `pairingCode` while it waits. A remembered
   * token is kept in the token store. Then initializes, so the client is connected when this resolves.
   */
  async pair(scope: PairingScope | undefined = this.options.scope, options: { signal?: AbortSignal } = {}): Promise<PairResult> {
    const connection = await this.open(options);
    this.#setState('pairing');
    let result: PairResult;
    try {
      result = await connection.request('agneta/pair', { name: this.options.name, ...(scope ? { scope } : {}) }, { timeout: this.timeouts.pair, ...options });
    } catch (error) {
      // Still open and not paired (or paired before): the app may ask again.
      if (this.#connection === connection && connection.isOpen) this.#setState(this.#initialized ? 'connected' : 'connecting');
      throw error;
    } finally {
      this.#pairingCode = null;
    }
    if (typeof result?.token !== 'string') throw new ProtocolError('Agneta returned an incomplete pairing response.', result);
    if (result.remembered) await this.tokens.save(result.token);
    this.#remembered = result.remembered === true;
    this.emit('paired', result);
    await this.initialize(result.token, options);
    return result;
  }

  /** `initialize` with a token: needed on every connection. Rejects with `NeedsPairingError` for a token Agneta doesn't accept. */
  async initialize(token: string, options: { signal?: AbortSignal } = {}): Promise<InitializeResult> {
    const connection = await this.open(options);
    const clientInfo = this.options.clientInfo ?? { name: this.options.name, version: '0.0.0' };
    const result = await connection.request('initialize', {
      protocolVersion, clientCapabilities: {}, clientInfo, _meta: { agneta: { token } }
    }, options.signal ? { signal: options.signal } : {});
    const access = result?._meta?.agneta?.access;
    if (result?.protocolVersion !== protocolVersion || !access || !Array.isArray(access.providers)) {
      throw new ProtocolError('Use an Agneta build that tells apps what they may use.', result);
    }
    if (this.#connection !== connection) throw new ConnectionClosedError(undefined, 'the connection was replaced');
    this.#token = token;
    this.#initialized = result;
    this.#access = access;
    this.#setState('connected');
    return result;
  }

  /** `agneta/access`: what the app may use, now. */
  async refreshAccess(options?: RequestOptions): Promise<Access> {
    const access = await this.#require().request('agneta/access', {}, options);
    this.#access = access;
    return access;
  }

  /** Forgets the kept token (the user's access in Agneta stays until they remove it there). */
  async forgetToken(): Promise<void> {
    this.#token = null;
    this.#remembered = false;
    await this.tokens.clear();
  }

  /** Disconnects. Open sessions end; no reconnect follows. */
  close(): void {
    this.#closing = true;
    this.#cancelReconnect();
    const connection = this.#connection;
    if (connection) this.#drop(connection);
    else this.#setState('disconnected');
  }

  // MARK: Sessions

  /** `session/new`: a task, in the app's workspace unless `cwd` says otherwise. Waits out an engine download by default. */
  async newSession(options: NewSessionOptions = {}): Promise<Session> {
    const cwd = options.cwd ?? this.#requireAccess().workspace;
    if (!cwd) throw new TypeError('newSession needs a cwd: this Agneta gives the app no workspace of its own.');
    const agneta = { ...(options.account ? { account: options.account } : {}), ...(options.engine ? { engine: options.engine } : {}) };
    const meta = this.#meta(options, Object.keys(agneta).length ? agneta : undefined);
    const params = { cwd, mcpServers: options.mcpServers ?? [], ...(meta ? { _meta: meta } : {}), ...options.params };
    return this.#open('session/new', params, options, (result) => result.sessionId);
  }

  /**
   * `session/load`: reopens one of the app's earlier tasks. Pass the tool servers again (bearers are per session). The
   * replayed conversation is in `session.history`. Instructions appended with `setInstructions` aren't restored.
   */
  async loadSession(sessionId: string, options: LoadSessionOptions = {}): Promise<Session> {
    const cwd = options.cwd ?? this.#requireAccess().workspace;
    if (!cwd) throw new TypeError('loadSession needs a cwd.');
    const meta = this.#meta(options);
    const params = { sessionId, cwd, mcpServers: options.mcpServers ?? [], ...(meta ? { _meta: meta } : {}), ...options.params };
    this.#early.set(sessionId, []);
    return this.#open('session/load', params, options, () => sessionId);
  }

  /** `agneta/fork`: a new task with a copy of one of the app's tasks, open or finished. Without a policy: the original's, read-only. */
  async fork(source: string | Session, options: ForkOptions = {}): Promise<Session> {
    const sessionId = typeof source === 'string' ? source : source.id;
    const meta = this.#meta(options);
    const params = { sessionId, mcpServers: options.mcpServers ?? [], ...(options.cwd ? { cwd: options.cwd } : {}), ...(meta ? { _meta: meta } : {}), ...options.params };
    return this.#open('agneta/fork', params, options, (result) => result.sessionId);
  }

  /** One page of a task's trace (`agneta/trace/read`): running or finished, the app's own tasks only. */
  readTrace(sessionId: string, params: Omit<TraceReadParams, 'sessionId'> = {}, options?: RequestOptions): Promise<TraceReadResult> {
    return this.#require().request('agneta/trace/read', { sessionId, ...params }, options);
  }

  /** Every trace record of a task after `after`, page by page, until there are no more for now. */
  async *traceRecords(sessionId: string, options: TraceRecordsOptions = {}): AsyncGenerator<TraceRecord> {
    let after = options.after ?? 0;
    for (;;) {
      const page = await this.readTrace(sessionId, { after, ...(options.types ? { types: options.types } : {}), ...(options.limit ? { limit: options.limit } : {}) },
        options.signal ? { signal: options.signal } : {});
      for (const record of page.records) yield record;
      const last = page.records.at(-1)?.seq;
      if (page.complete || page.records.length === 0) return;
      after = page.next ?? last ?? after;
    }
  }

  // MARK: Raw

  /** Any request, typed for Agneta's methods. The same as `client.connection.request`. */
  request<M extends keyof AgnetaRequests>(method: M, params: AgnetaRequests[M]['params'], options?: RequestOptions): Promise<AgnetaRequests[M]['result']>;
  request<Result = unknown, M extends string = string>(method: M extends keyof AgnetaRequests ? never : M, params?: unknown, options?: RequestOptions): Promise<Result>;
  request(method: string, params?: unknown, options?: RequestOptions): Promise<unknown> {
    return this.#require().request(method, params, options);
  }

  /** Any notification. */
  notify(method: string, params?: unknown): void {
    this.#require().notify(method, params);
  }

  /** Listens for one notification method from Agneta, on every connection, typed. */
  onNotification<M extends keyof AgnetaNotifications>(method: M, listener: (params: AgnetaNotifications[M]) => void): () => void;
  onNotification(method: string, listener: (params: unknown) => void): () => void;
  onNotification(method: string, listener: (params: any) => void): () => void {
    return this.on('notification', (received, params) => { if (received === method) listener(params); });
  }

  // MARK: Inside

  #require(): Connection {
    if (!this.#connection?.isOpen) throw new ConnectionClosedError(undefined, 'not connected');
    return this.#connection;
  }

  #requireAccess(): Access {
    this.#require();
    if (!this.#access) throw new NeedsPairingError({ code: -32001, message: 'Pair with Agneta first', data: { agneta: { needsPairing: true } } });
    return this.#access;
  }

  #setState(state: ClientState): void {
    if (this.#state === state) return;
    this.#state = state;
    this.emit('state', state);
  }

  #meta(options: SessionOptionsBase, agneta?: SessionRequestMeta['agneta']): SessionRequestMeta | undefined {
    const meta: SessionRequestMeta = {};
    if (agneta) meta.agneta = agneta;
    if (options.policy) meta['agneta/policy'] = options.policy;
    if (options.task) meta['agneta/task'] = typeof options.task === 'string' ? { title: options.task } : options.task;
    if (options.instructions !== undefined) meta['agneta/instructions'] = { text: options.instructions };
    if (options.trace) meta['agneta/trace'] = options.trace === true ? { live: true } : options.trace;
    Object.assign(meta, options.meta);
    return Object.keys(meta).length ? meta : undefined;
  }

  async #open(method: 'session/new' | 'session/load' | 'agneta/fork', params: any, options: SessionOptionsBase, idOf: (result: SessionResult) => string | undefined): Promise<Session> {
    const connection = this.#require();
    this.#requireAccess();
    const wait = options.waitForDownload === false ? 0 : typeof options.waitForDownload === 'number' ? options.waitForDownload : 600_000;
    const started = Date.now();
    let result: SessionResult;
    try {
      for (;;) {
        try {
          result = await connection.request(method, params, { timeout: options.timeout ?? this.timeouts.session, ...(options.signal ? { signal: options.signal } : {}) });
          break;
        } catch (error) {
          if (!(error instanceof EngineDownloadingError) || Date.now() - started >= wait) throw error;
          if (error.progress) {
            options.onDownloadProgress?.(error.progress);
            this.emit('engineDownloading', error.progress);
          }
          await delay(2000, options.signal);
        }
      }
    } finally {
      if (method === 'session/load') queueMicrotask(() => { if (!this.#sessions.has(params.sessionId)) this.#early.delete(params.sessionId); });
    }
    const id = idOf(result);
    if (typeof id !== 'string' || !id) throw new ProtocolError(`Agneta returned no session id for ${method}.`, result);
    const early = this.#early.get(id) ?? [];
    this.#early.delete(id);
    const history = early.filter(({ method }) => method === 'session/update').map(({ params }) => params.update as SessionUpdate);
    const session = new Session(this.#host, id, { ...result, sessionId: id }, history, options.permissions, options.on);
    if (this.#connection !== connection || !connection.isOpen) {
      session.end({ reason: 'disconnected', error: new ConnectionClosedError(undefined, 'closed while the session opened') });
      throw new ConnectionClosedError(undefined, 'closed while the session opened');
    }
    this.#sessions.set(id, session);
    // The rest of what came early (live trace records, a queue place, a stop), to the listeners given in `on`.
    for (const { method, params } of early) if (method !== 'session/update') session.receive(method, params);
    return session;
  }

  /** What sessions use of the client: the connection they were opened on. */
  #host!: SessionHost;

  #makeHost(connection: Connection): SessionHost {
    const client = this;
    return {
      connection,
      timeouts: this.timeouts,
      forget: (session) => { if (client.#sessions.get(session.id) === session) client.#sessions.delete(session.id); },
      fork: (source, options) => client.fork(source, options),
      readTrace: (sessionId, params, options) => client.readTrace(sessionId, params, options),
      traceRecords: (sessionId, options) => client.traceRecords(sessionId, options)
    };
  }

  #attach(connection: Connection): void {
    this.#connection = connection;
    this.#host = this.#makeHost(connection);
    this.#initialized = null;
    this.#access = null;
    connection.on('notification', (method, params) => this.#notification(connection, method, params));
    connection.handle('session/request_permission', async (params) => {
      const session = this.#sessions.get(params?.sessionId);
      const handler = session?.permissionHandler ?? this.options.permissions;
      // No handler: declined, by the engine's own reject option where it offers one (Agneta's preference too).
      if (!handler) return permissionResponse('reject', params?.options ?? []);
      try {
        return permissionResponse(await handler({ ...params, session }), params?.options ?? []);
      } catch (error) {
        this.emit('error', error);
        return permissionResponse('reject', params?.options ?? []);
      }
    });
    connection.on('close', (error) => {
      if (this.#connection !== connection) return;
      this.#dropped(error);
    });
  }

  #notification(connection: Connection, method: string, params: any): void {
    if (this.#connection !== connection) return;
    switch (method) {
      case 'agneta/pairingCode':
        if (typeof params?.code === 'string') {
          this.#pairingCode = params.code;
          this.emit('pairingCode', params.code, params);
        }
        break;
      case 'agneta/catalogChanged':
        if (params?.catalog) this.emit('catalogChanged', params.catalog);
        break;
      case 'agneta/accessChanged':
        if (params?.access) {
          this.#access = params.access;
          this.emit('accessChanged', params.access);
        }
        break;
      case 'agneta/queued': this.emit('queued', params); break;
      case 'agneta/rateLimited': this.emit('rateLimited', params); break;
      case 'agneta/sessionStopped': this.emit('sessionStopped', params); break;
    }
    const id = params?.sessionId;
    if (typeof id === 'string') {
      const session = this.#sessions.get(id);
      if (session) session.receive(method, params);
      else if (method !== 'session/update' || params?.update) this.#hold(id, method, params);
    }
    this.emit('notification', method, params);
  }

  /** Keeps a notification for a session not registered yet: a few sessions' worth, bounded. */
  #hold(id: string, method: string, params: unknown): void {
    let list = this.#early.get(id);
    if (!list) {
      if (this.#early.size >= 16) this.#early.delete(this.#early.keys().next().value!);
      this.#early.set(id, list = []);
    }
    if (list.length < 10_000) list.push({ method, params });
  }

  #drop(connection: Connection): void {
    connection.close();
    // close() emits `close` synchronously, which runs #dropped.
  }

  #dropped(error: ConnectionClosedError): void {
    const hadToken = this.#remembered && this.#token !== null;
    this.#connection = null;
    this.#initialized = null;
    this.#access = null;
    this.#token = null;
    this.#pairingCode = null;
    this.#early.clear();
    for (const session of [...this.#sessions.values()]) session.end({ reason: 'disconnected', error });
    this.#sessions.clear();
    this.#setState('disconnected');
    this.emit('disconnected', error);
    this.#remembered = false;
    if (hadToken && this.options.reconnect && !this.#closing) this.#scheduleReconnect(1);
  }

  #scheduleReconnect(attempt: number): void {
    const settings = typeof this.options.reconnect === 'object' ? this.options.reconnect : {};
    const wait = Math.min((settings.delay ?? 1000) * 2 ** (attempt - 1), settings.maxDelay ?? 30_000);
    this.#setState('reconnecting');
    this.emit('reconnecting', attempt, wait);
    this.#reconnectTimer = setTimeout(async () => {
      this.#reconnectTimer = null;
      if (this.#closing) return;
      try {
        const access = await this.#reconnectOnce();
        this.emit('reconnected', access);
      } catch (error) {
        if (this.#closing || error instanceof NeedsPairingError) {
          this.#setState('disconnected');
          return;
        }
        this.#scheduleReconnect(attempt + 1);
      }
    }, wait);
  }

  /** A quiet connect: never asks `launch` nor pairs. */
  async #reconnectOnce(): Promise<Access> {
    this.#quiet = true;
    try {
      return await this.connect({ pair: 'never' });
    } finally {
      this.#quiet = false;
    }
  }

  #cancelReconnect(): void {
    if (this.#reconnectTimer) clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = null;
  }

  async #setUpProvider(kind: ProviderKind | undefined, signal?: AbortSignal): Promise<void> {
    let catalog: Catalog;
    try {
      catalog = await this.catalog(signal ? { signal } : {});
    } catch (error) {
      // An Agneta from before agneta/catalog: its approval window is the only way to connect a provider.
      if (error instanceof MethodNotFoundError) return;
      throw error;
    }
    const connected = kind ? catalog.providers.some((provider) => provider.kind === kind && provider.connected) : catalog.connected;
    if (connected) return;
    const waiting = this.waitForProvider(kind, signal ? { signal } : {});
    waiting.catch(() => {});
    await this.setup(kind ? { kind } : {});
    this.emit('setup', kind);
    await waiting;
  }

  async #waitForAgneta(open: OpenOptions, signal?: AbortSignal): Promise<Connection> {
    const deadline = Date.now() + (this.options.launchTimeout ?? 20_000);
    for (;;) {
      try {
        return await Connection.open(open);
      } catch (error) {
        if (!(error instanceof NotRunningError) || Date.now() >= deadline) {
          this.#setState('disconnected');
          throw error;
        }
        await delay(500, signal);
      }
    }
  }
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new AbortedError('wait', { cause: signal.reason }));
    const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
    const abort = () => { clearTimeout(timer); reject(new AbortedError('wait', { cause: signal?.reason })); };
    signal?.addEventListener('abort', abort, { once: true });
  });
}

/** A client, connected: `await connect({ name: 'My App' })`. */
export async function connect(options: AgnetaClientOptions & ConnectOptions): Promise<AgnetaClient> {
  const { pair, setup, signal, ...clientOptions } = options;
  const client = new AgnetaClient(clientOptions);
  await client.connect({ ...(pair ? { pair } : {}), ...(setup ? { setup } : {}), ...(signal ? { signal } : {}) });
  return client;
}
