// Agneta's side of the app protocol (docs/APP_PROTOCOL.md): every method an app may call, every notification and
// request Agneta sends, and the shapes they carry. Field names are the wire's, so these types also read raw messages.
import type {
  ContentBlock, Implementation, McpServerHttp, Meta, RequestPermissionRequest, RequestPermissionResponse,
  SessionConfigOption, SessionModeState, SessionNotification, StopReason, Usage
} from './acp.js';

/** The kinds of provider: a Claude or ChatGPT plan, or an Anthropic or OpenAI API key. */
export type ProviderKind = 'claude' | 'chatgpt' | 'anthropic-key' | 'openai-key';
export const providerKinds: readonly ProviderKind[] = ['claude', 'chatgpt', 'anthropic-key', 'openai-key'];

/** The engines Agneta runs today. Another may be added: the type stays open. */
export type EngineId = 'claude-code' | 'codex' | 'goose' | 'opencode' | (string & {});

/** How far a task reaches (docs/APP_PROTOCOL.md, Sandbox). */
export type SandboxLevel = 'contained' | 'developer';

/** The built-in tools a session may use, least first. */
export type ToolsLevel = 'app-only' | 'read' | 'workspace';

export type EngineState = 'ready' | 'downloading' | 'downloadable' | 'failed' | 'unavailable';

// MARK: Before pairing

export interface CatalogEngineOffer {
  id: EngineId;
  /** The modes this engine can provide on this kind of provider. */
  sandboxLevels: SandboxLevel[];
  /** Present (true) where Agneta's policy can't confine the engine's own tools on this kind. */
  uncontained?: boolean;
}

export interface CatalogProvider {
  kind: ProviderKind;
  name: string;
  /** Whether one of this kind is connected in Agneta. */
  connected: boolean;
  engines: CatalogEngineOffer[];
}

export interface CatalogEngine {
  id: EngineId;
  name: string;
  state: EngineState;
  reason?: string;
}

/** `agneta/catalog`: what this Agneta offers any app. It never names the user's accounts. */
export interface Catalog {
  providers: CatalogProvider[];
  engines: CatalogEngine[];
  /** Whether any provider is connected. */
  connected: boolean;
  /** Agneta's version, as its bundle says (`0.0.0` for a development build). Absent from Agnetas before it was added. */
  version?: string;
}

export interface SetupParams {
  /** The app's name, shown in Agneta's window. */
  name?: string;
  /** Narrows the window to one kind of provider. */
  kind?: ProviderKind;
}

// MARK: Pairing

/** What the app will need, shown to the user in Agneta's approval window. Ask for no more than the app's features need. */
export interface PairingScope {
  /** The most built-in tools its sessions will use. Default: `app-only`. */
  tools?: ToolsLevel;
  /** The user's folders its sessions will work in: absolute paths. */
  folders?: string[];
  /** The provider kinds wanted, or `"all"`. Left out, the user picks among all providers. */
  providers?: 'all' | ProviderKind[];
  /** The engines wanted, or `"all"`. Left out, every engine. */
  engines?: 'all' | EngineId[];
  /** The mode wanted. `"any"` is the same as leaving it out. Applies only with `workspace` tools. */
  sandbox?: SandboxLevel | 'any';
}

export interface PairParams {
  name: string;
  scope?: PairingScope;
}

/** Something the scope asked for and didn't get, and why. */
export interface UnmetItem {
  provider?: ProviderKind;
  engine?: EngineId;
  sandbox?: SandboxLevel;
  reason: string;
}

export interface PairResult {
  /** Send it in `initialize`. Keep it only when `remembered`. */
  token: string;
  /** Always Allow (true) or Allow Once (false: the token ends with this connection). */
  remembered: boolean;
  access: Access;
  /** What of the scope wasn't given. Empty when everything was. */
  unmet: UnmetItem[];
}

export interface PairingCodeParams {
  /** Six digits, also shown in Agneta's approval window. */
  code: string;
  name: string;
}

// MARK: Access

/** What a session on an engine can do beyond plain ACP. */
export interface SessionCapabilities {
  engine: EngineId;
  /** `agneta/steer` works. */
  steer: boolean;
  /** `agneta/fork` works. */
  fork: boolean;
  /** `agneta/instructions/set` works. */
  instructionsBetweenTurns: boolean;
  /** Per-call cost is known while the turn runs, so `maxCostUSD` can be enforced. */
  reportsCost: boolean;
}

/** A provider (an account) the app may use. */
export interface AccessProvider {
  /** The account id: `_meta.agneta.account` in `session/new`. */
  id: string;
  label: string;
  kind: ProviderKind;
  /** Paused by the user: nothing new starts on it. */
  paused: boolean;
  /** Waits for the user to sign in again in Agneta. */
  needsSignIn: boolean;
  /** The engines its tasks may run on now or after a download, the default first. */
  engines: EngineId[];
  defaultEngine?: EngineId | null;
  /** Engines here whose own tools Agneta's policy doesn't confine: they provide developer access only. */
  uncontained: EngineId[];
  /** For each engine, the modes it can provide here. */
  sandboxLevels: Record<string, SandboxLevel[]>;
}

interface AccessEngineBase {
  id: EngineId;
  name: string;
}

/** An engine the app may use, as it is on this Mac, discriminated by `state`. */
export type AccessEngine =
  | (AccessEngineBase & { state: 'ready'; capabilities?: SessionCapabilities })
  | (AccessEngineBase & { state: 'downloading'; received?: number; total?: number })
  | (AccessEngineBase & { state: 'downloadable'; size?: number })
  | (AccessEngineBase & { state: 'failed'; reason?: string })
  | (AccessEngineBase & { state: 'unavailable'; reason?: string });

export interface AccessScope {
  tools: ToolsLevel;
  folders: string[];
  /** The most the app's tasks may do, as the user chose. */
  sandbox: SandboxLevel;
}

/** What the app may use: the same object from `initialize`, pairing, `agneta/access` and `agneta/accessChanged`. */
export interface Access {
  providers: AccessProvider[];
  engines: AccessEngine[];
  /** `"all"` (including engines added later) or the ids the user ticked. */
  allowedEngines: 'all' | EngineId[];
  scope: AccessScope;
  /** The app's own workspace, made by Agneta. */
  workspace?: string;
}

// MARK: initialize

export interface InitializeParams {
  protocolVersion: number;
  clientCapabilities: Record<string, unknown>;
  clientInfo?: Implementation;
  _meta: { agneta: { token: string }; [key: string]: unknown };
}

/** Agneta's extensions, listed in `initialize`. */
export type AgnetaExtension =
  | 'agneta/policy' | 'agneta/access' | 'agneta/catalog' | 'agneta/setup' | 'agneta/task' | 'agneta/instructions'
  | 'agneta/steer' | 'agneta/usage' | 'agneta/limit' | 'agneta/queue' | 'agneta/fork' | 'agneta/rateLimited' | 'agneta/trace'
  | (string & {});

export interface InitializeResult {
  protocolVersion: number;
  agentCapabilities: {
    loadSession?: boolean;
    promptCapabilities?: { image?: boolean; audio?: boolean; embeddedContext?: boolean };
    mcpCapabilities?: { http?: boolean; sse?: boolean };
    sessionCapabilities?: Record<string, unknown>;
    [key: string]: unknown;
  };
  authMethods?: unknown[];
  agentInfo?: Implementation;
  _meta: { agneta: { extensions: AgnetaExtension[]; access: Access }; [key: string]: unknown };
}

// MARK: Sessions

/** The session policy, `_meta["agneta/policy"]` (docs/APP_PROTOCOL.md, agneta/policy). Anything Agneta can't enforce is refused. */
export interface Policy {
  /** Default `workspace` (no more than the grant's). */
  tools?: ToolsLevel;
  /** `none` (the default) for contained sessions. A list of hosts isn't supported yet; `{allow: []}` means `none`. */
  network?: 'none' | { allow: string[] };
  /** What this session should get, no more than the grant's. Without it: the grant's for `workspace` tools, else contained. */
  sandbox?: SandboxLevel;
  /** `ask-app` (the default): permission requests reach the app. `never-ask`: the policy is the permission. */
  approval?: 'ask-app' | 'never-ask';
  readable?: string[];
  writable?: string[];
  /** Read-only even inside the workspace. */
  readOnly?: string[];
  /** Neither readable nor writable, even inside allowed folders. */
  denied?: string[];
  /** Variables for shell commands (some names are refused: see the protocol). */
  toolEnvironment?: Record<string, string>;
  /** Loopback ports shell commands may reach. */
  toolPorts?: number[];
  /** Unix sockets shell commands may reach. */
  toolSockets?: string[];
  limits?: PolicyLimits;
}

export interface PolicyLimits {
  /** Model calls within one prompt (default 200). */
  maxTurns?: number;
  /** A prompt's wall time (default 4 hours). */
  maxSeconds?: number;
  /** The task's known cost so far, across resumes. Only on engines that report cost while a turn runs. */
  maxCostUSD?: number;
}

/** `_meta["agneta/task"]`: shown in Agneta's menu. */
export interface TaskInfo {
  title?: string;
  /** What the user is told before pressing Stop, such as "Example App keeps the work so far". */
  stopWarning?: string;
}

/** `_meta["agneta/trace"]`: live trace delivery. */
export interface TraceDelivery {
  live: boolean;
  /** `["acp"]` adds the raw JSON-RPC frames of both connections. */
  include?: TraceRecordType[];
}

/** The `_meta` of `session/new`, `session/load` and `agneta/fork`. */
export interface SessionRequestMeta {
  agneta?: { account?: string; engine?: EngineId; [key: string]: unknown };
  'agneta/policy'?: Policy;
  'agneta/task'?: TaskInfo;
  'agneta/instructions'?: { text: string };
  'agneta/trace'?: TraceDelivery;
  [key: string]: unknown;
}

export interface NewSessionParams {
  /** Absolute; the session's workspace. */
  cwd: string;
  mcpServers: McpServerHttp[];
  /** ACP's instructions field; `_meta["agneta/instructions"]` is Agneta's. */
  systemPrompt?: { content: ContentBlock[] } | unknown;
  _meta?: SessionRequestMeta;
  [key: string]: unknown;
}

export interface LoadSessionParams {
  sessionId: string;
  cwd: string;
  /** Pass the tool servers again: their bearers are per session. */
  mcpServers: McpServerHttp[];
  _meta?: SessionRequestMeta;
  [key: string]: unknown;
}

export interface ForkParams {
  /** The task to copy, open or finished. */
  sessionId: string;
  mcpServers: McpServerHttp[];
  cwd?: string;
  _meta?: SessionRequestMeta;
  [key: string]: unknown;
}

/** What Agneta adds to the reply of `session/new`, `session/load` and `agneta/fork`. */
export interface SessionResultAgneta {
  account: string;
  /** Whether the session has an engine process of its own. */
  dedicatedEngine: boolean;
  capabilities: SessionCapabilities;
  /** The mode the task really got. */
  sandbox: SandboxLevel;
  /** `session/load`: true. */
  resumed?: boolean;
  /** `agneta/fork`: the source task. */
  forkOf?: string;
  [key: string]: unknown;
}

export interface SessionResult {
  /** Agneta's id (a load's reply has none: it's the id loaded). */
  sessionId?: string;
  configOptions?: SessionConfigOption[] | null;
  modes?: SessionModeState | null;
  _meta: { agneta: SessionResultAgneta; [key: string]: unknown };
  [key: string]: unknown;
}

// MARK: Turns

export interface PromptParams {
  sessionId: string;
  prompt: ContentBlock[];
  _meta?: Meta;
}

/** A turn's usage from the engine's own records (docs/APP_PROTOCOL.md, Turns). Unknown values are null, never guessed. */
export interface AgnetaUsage {
  modelCalls: number | null;
  models: string[];
  inputTokens: number | null;
  outputTokens: number | null;
  cacheReadTokens: number | null;
  cacheWriteTokens: number | null;
  cost: number | null;
  /** `estimated` for API keys; `plan-equivalent` for subscriptions, where nothing is charged per call. */
  costKind: 'estimated' | 'plan-equivalent' | null;
  /** The task's known cost so far, across resumes. */
  taskCost: number | null;
  billing: 'api-key' | 'subscription' | 'unknown' | (string & {});
  account: string;
  ms: number | null;
  msToFirstToken: number | null;
  /** `engine-ledger` (per-call records) or `engine-turn-totals` (the engine's own totals). */
  basis: 'engine-ledger' | 'engine-turn-totals' | (string & {});
}

/** Which policy limit stopped a turn. */
export interface LimitHit {
  limit: 'maxTurns' | 'maxSeconds' | 'maxCostUSD';
  value: number;
  /** The engine didn't stop in time, so Agneta ended the session: load it again to go on. */
  sessionEnded?: boolean;
}

export interface PromptResult {
  sessionId?: string;
  stopReason: StopReason;
  usage?: Usage;
  _meta?: { 'agneta/usage'?: AgnetaUsage; 'agneta/limit'?: LimitHit; [key: string]: unknown };
  [key: string]: unknown;
}

export interface SteerParams {
  sessionId: string;
  prompt: ContentBlock[];
}

export interface SteerResult {
  delivery: 'accepted';
  runId: string | null;
}

export interface InstructionsSetParams {
  sessionId: string;
  text: string;
  /** `replace` (the default) sets the instructions; `append` adds a named part. */
  mode?: 'replace' | 'append';
  /** For `append`: a later append with the same key replaces it. Default `app`. */
  key?: string;
}

export interface SetConfigOptionParams {
  sessionId: string;
  configId: string;
  value: string | boolean;
}

export interface SetConfigOptionResult {
  /** The options as they are now: another model may offer other efforts, or none. */
  configOptions?: SessionConfigOption[];
  [key: string]: unknown;
}

export interface SetModeParams {
  sessionId: string;
  modeId: string;
}

export interface SetModelParams {
  sessionId: string;
  modelId: string;
}

// MARK: Notifications from Agneta

export interface QueuedParams {
  sessionId: string;
  /** Place in the queue, from 1. */
  position: number;
}

/** Who ended a session: the user (Stop in Agneta's menu), the engine (it exited), or a policy limit Agneta enforced. */
export type StoppedBy = 'user' | 'engine' | 'limit';

export interface SessionStoppedParams {
  sessionId: string;
  stoppedBy: StoppedBy;
}

export interface RateLimitDetails {
  account: string;
  /** The provider's own words. */
  message: string;
  /** UTC, read from the provider's words; null when they give none. */
  resetsAt: string | null;
}

export interface RateLimitedParams extends RateLimitDetails {
  sessionId: string;
}

export interface TraceParams {
  sessionId: string;
  records: TraceRecord[];
  /** The app read too slowly: live delivery stopped. Read on from `after` with `agneta/trace/read`. */
  overflow?: { after: number };
}

// MARK: Traces (docs/DIAGNOSTICS.md)

export type TraceRecordType =
  | 'meta' | 'config' | 'acp' | 'event' | 'engine.message' | 'engine.usage' | 'permission' | 'shell' | 'stderr' | 'lifecycle' | 'end'
  | (string & {});

interface TraceRecordBase {
  /** Format version, 1. */
  v: number;
  /** Gapless per task, from 1. */
  seq: number;
  /** Wall time, ISO 8601 UTC with microseconds. */
  t: string;
  /** Nanoseconds since the trace was opened or resumed. */
  mono: number;
  /** Agneta's session id. */
  task: string;
  /** 0 before the first prompt, then the turn number. */
  turn: number;
  [key: string]: unknown;
}

export type TraceEventKind =
  | 'init' | 'prompt' | 'text-delta' | 'thinking-delta' | 'tool-call' | 'tool-input' | 'tool-result' | 'model-call'
  | 'usage' | 'plan' | 'turn' | 'rate-limited' | (string & {});

export type PermissionDecision = 'asked-app' | 'allowed-by-policy' | 'refused-by-policy' | 'cancelled' | (string & {});

/** One trace record, discriminated by `type`. Secrets are masked. */
export type TraceRecord =
  | (TraceRecordBase & { type: 'meta' })
  | (TraceRecordBase & { type: 'config'; method?: string; request?: unknown; by?: string })
  | (TraceRecordBase & { type: 'acp'; leg: 'app→agneta' | 'agneta→engine' | 'engine→agneta' | 'agneta→app'; msg: unknown })
  | (TraceRecordBase & { type: 'event'; kind: TraceEventKind })
  | (TraceRecordBase & { type: 'engine.message' })
  | (TraceRecordBase & { type: 'engine.usage' })
  | (TraceRecordBase & { type: 'permission'; decision: PermissionDecision })
  | (TraceRecordBase & { type: 'shell'; command?: string; cwd?: string; ms?: number })
  | (TraceRecordBase & { type: 'stderr' })
  | (TraceRecordBase & { type: 'lifecycle'; event: string })
  | (TraceRecordBase & { type: 'end' });

export interface TraceReadParams {
  sessionId: string;
  /** The last sequence number already read (0 for the start). */
  after?: number;
  /** Record types; without it, all but `acp`. */
  types?: TraceRecordType[];
  /** Up to 5,000 a page (default 500). */
  limit?: number;
}

export interface TraceReadResult {
  records: TraceRecord[];
  /** The `after` for the next page, or null. */
  next: number | null;
  /** Nothing more to read now. */
  complete: boolean;
}

// MARK: The method map

/** Every request an app may send, with its params and result. */
export interface AgnetaRequests {
  'agneta/catalog': { params: Record<string, never>; result: Catalog };
  'agneta/setup': { params: SetupParams; result: { shown: boolean } };
  'agneta/pair': { params: PairParams; result: PairResult };
  'initialize': { params: InitializeParams; result: InitializeResult };
  'agneta/access': { params: Record<string, never>; result: Access };
  'session/new': { params: NewSessionParams; result: SessionResult };
  'session/load': { params: LoadSessionParams; result: SessionResult };
  'agneta/fork': { params: ForkParams; result: SessionResult };
  'session/prompt': { params: PromptParams; result: PromptResult };
  'session/close': { params: { sessionId: string }; result: Record<string, unknown> };
  'session/set_config_option': { params: SetConfigOptionParams; result: SetConfigOptionResult };
  'session/set_mode': { params: SetModeParams; result: Record<string, unknown> };
  'session/set_model': { params: SetModelParams; result: Record<string, unknown> };
  'agneta/steer': { params: SteerParams; result: SteerResult };
  'agneta/instructions/set': { params: InstructionsSetParams; result: Record<string, unknown> };
  'agneta/trace/read': { params: TraceReadParams; result: TraceReadResult };
}

export type AgnetaMethod = keyof AgnetaRequests;

/** The notification an app may send. */
export interface AppNotifications {
  'session/cancel': { sessionId: string };
}

/** Every notification Agneta sends an app. */
export interface AgnetaNotifications {
  'session/update': SessionNotification;
  'agneta/pairingCode': PairingCodeParams;
  'agneta/catalogChanged': { catalog: Catalog };
  'agneta/accessChanged': { access: Access };
  'agneta/queued': QueuedParams;
  'agneta/sessionStopped': SessionStoppedParams;
  'agneta/rateLimited': RateLimitedParams;
  'agneta/trace': TraceParams;
}

/** The requests Agneta sends an app. */
export interface AgnetaClientRequests {
  'session/request_permission': { params: RequestPermissionRequest; result: RequestPermissionResponse };
}

/** The ACP protocol version Agneta speaks. */
export const protocolVersion = 1;

/**
 * Release and development builds of Agneta: their ports, the URLs that open them, their bundle identifiers, where the
 * user gets them, and Homebrew's command (releases only). docs/APP_PROTOCOL.md, Getting Agneta.
 */
export const builds = {
  release: {
    name: 'Agneta', port: 47321, openURL: 'agneta://open', bundleIdentifier: 'com.objectivecoder.agneta',
    installURL: 'https://agneta.dahlbom.io/get/', homebrew: 'brew install olofd/tap/agneta'
  },
  dev: {
    name: 'Agneta Dev', port: 47331, openURL: 'agneta-dev://open', bundleIdentifier: 'com.objectivecoder.agneta.dev',
    installURL: 'https://github.com/olofd/agneta#build-and-run', homebrew: null
  }
} as const;

export type Build = keyof typeof builds;
