// The high-level client: connect (getting and opening Agneta when the user agrees: docs/APP_PROTOCOL.md, Getting
// Agneta), pair or initialize with a kept token, keep the access report current, open sessions, and route Agneta's
// notifications and permission requests to them.
import type { Implementation, SessionUpdate } from './acp.js';
import { Connection, probeAgneta, type OpenOptions, type PortProbe, type RequestOptions, type WebSocketConstructor } from './connection.js';
import { Emitter } from './emitter.js';
import {
  AbortedError, ConnectionClosedError, DeclinedError, TimeoutError, EngineDownloadingError, MethodNotFoundError, NeedsPairingError,
  NotInstalledError, NotRunningError, OutdatedError, ProtocolError, UnsupportedByAgnetaError, UnsupportedEnvironmentError,
  type DownloadProgress
} from './errors.js';
import {
  compareVersions, installPageURL, lookUpAgneta, type AgnetaEnvironment, type AgnetaPresence, type Architecture,
  type ConnectProgress, type Guide, type GuideQuestion
} from './install.js';
import {
  builds, protocolVersion, type Access, type AgnetaNotifications, type AgnetaRequests, type Build, type Catalog,
  type InitializeResult, type JsonSchema, type PairingCodeParams, type PairingScope, type PairResult, type ProviderKind, type QueuedParams,
  type RateLimitedParams, type SessionRequestMeta, type SessionResult, type SessionStoppedParams, type TraceReadParams,
  type TraceReadResult, type TraceRecord
} from './protocol.js';
import {
  Answer, prepareDeclaration, recordedSchemas, resultExtension, type AskOptions, type FromSchema, type FromStandardSchema, type PreparedDeclaration,
  type PreparedSchema, type SchemaInput
} from './results.js';
import {
  permissionResponse, Session, type ForkOptions, type LoadSessionOptions, type NewSessionOptions, type PermissionHandler,
  type PromptInput, type SessionHost, type SessionOptionsBase, type TraceRecordsOptions, type Turn
} from './session.js';
import type { StandardJSONSchemaV1 } from './standard-schema.js';
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
  /** Waiting for Agneta after opening it (a first launch waits for macOS's confirmation). Default 5 minutes; 0 for none. */
  open: number;
  /** After opening Agneta, the `slow` progress step: macOS may be asking whether to open it. Default 15 s. */
  slow: number;
  /** After opening Agneta, the `slow` step again with `keepWaiting`: offer Keep Waiting or Cancel. Default 60 s. */
  keepWaiting: number;
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
  /** Where the user gets this Agneta. Default: the build's (the install page for a release); null for none. */
  installURL?: string | null;
  /** The bundle identifier an installed Agneta must have (another app may claim its URL scheme). Default: the build's. */
  bundleIdentifier?: string | null;
  /**
   * How to find and open Agneta on this Mac: `nodeEnvironment()` or `electronEnvironment({ app, shell })` from
   * `@agneta/client/node`, or your own. Without one, the client can't tell "not installed" from "not running", and the
   * guided connect can't open anything.
   */
  environment?: AgnetaEnvironment;
  /**
   * The Agneta version the app needs (`"0.5.0"`: up to three numbers, else a TypeError): older is `outdated`, before
   * opening it and once connected. Versions compare by their numbers only (`0.5.0-beta` counts as `0.5.0`); a
   * development build (`0.0.0`) or one with no bundle (`dev`) is never too old.
   */
  minimumVersion?: string;
  /** Where the token from Always Allow is kept. Default: memory only. */
  tokens?: TokenStore;
  /** Sent in `initialize`. Default: the app's name. */
  clientInfo?: Implementation;
  /** Answers permission requests (`approval: "ask-app"`) for sessions without their own handler. Default: declined. */
  permissions?: PermissionHandler;
  /** Reconnect by itself, quietly, when a connection with a remembered token drops. Default off. */
  reconnect?: boolean | ReconnectOptions;
  timeouts?: Partial<Timeouts>;
  /** A WebSocket class, where there's no global one. */
  WebSocket?: WebSocketConstructor;
  /** What answers on Agneta's port, when the connection fails. Default: `probeAgneta`. For tests and unusual transports. */
  probe?: (url: string) => Promise<PortProbe>;
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
  /** Each step of `connect` (and `waitForAgneta`): what to show while the user gets, opens, sets up and approves Agneta. */
  progress: [progress: ConnectProgress];
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
  /**
   * Asks the user each question the protocol leaves to them (get Agneta, open it, update it, connect a provider),
   * resolving to their answer; a no rejects with `DeclinedError`. Needs the client's `environment`. Without it, connect
   * rejects with `NotInstalledError`, `NotRunningError` or `OutdatedError` instead. With `pair: 'never'` it's asked
   * only to open Agneta, and only when a token is kept (someone who has used the app before).
   */
  guide?: Guide;
  /** Each step, as the `progress` event. */
  onProgress?: (progress: ConnectProgress) => void;
  signal?: AbortSignal;
}

export interface WaitForAgnetaOptions {
  /** The user is installing Agneta: also look for it (steps `installed`, `onDiskImage`). No timeout unless given. */
  installing?: boolean;
  /** With `installing`: open Agneta once it's installed. Only when the user's yes covered that (their yes to `install`). */
  openWhenInstalled?: boolean;
  /** Agneta was just opened: steps `opening` and `slow`, and the `open` timeout. */
  opened?: boolean;
  /** Give up after this many ms with `NotRunningError`; 0 for never. Default: `timeouts.open` after an open, else none. */
  timeout?: number;
  signal?: AbortSignal;
  onProgress?: (progress: ConnectProgress) => void;
}

/**
 * What `client.ask` takes: the session's options (without `results`, which is the schema), and the ask's `attempts` and
 * `timeout` (the prompt's). `signal` cancels opening and the turn. Without a `policy`: app-only tools, never-ask.
 */
export type OneShotOptions = Omit<NewSessionOptions, 'results' | 'timeout'> & Pick<AskOptions, 'attempts' | 'timeout'> & {
  /** The turn, once the session is open and the prompt sent: to stream its events, or cancel it. */
  onTurn?: (turn: Turn) => void;
};

const defaults: Timeouts = {
  request: 30_000, connect: 5000, pair: 310_000, session: 180_000, prompt: 0, open: 300_000, slow: 15_000, keepWaiting: 60_000
};

/** What a provider kind is called where the user reads it. */
const kindNames: Record<string, string> = {
  claude: 'a Claude plan', chatgpt: 'a ChatGPT plan', 'anthropic-key': 'an Anthropic API key', 'openai-key': 'an OpenAI API key'
};

export class AgnetaClient extends Emitter<ClientEvents> {
  readonly options: AgnetaClientOptions;
  /** The WebSocket address. */
  readonly url: string;
  readonly openURL: string | null;
  /** Where the user gets this Agneta: the install page for a release, the README's Build and run for Agneta Dev. */
  readonly installURL: string | null;
  /** Homebrew's command, for a release. */
  readonly homebrew: string | null;
  /** The bundle identifier an installed Agneta must have. */
  readonly bundleIdentifier: string | null;
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
  #operations = new Set<AbortController>();
  /** Reconnecting: never guide (Agneta quit; it comes back when the user opens it), and no progress. */
  #quiet = false;
  /** The connect in progress: its progress listener, and whether the user already agreed to update Agneta. */
  #flow: { options: ConnectOptions; updateAsked: boolean } | null = null;

  constructor(options: AgnetaClientOptions) {
    super();
    if (!options || typeof options.name !== 'string' || !options.name) throw new TypeError('AgnetaClient needs the app\'s name.');
    this.options = options;
    const build = builds[options.build ?? 'release'];
    const port = options.port ?? build.port;
    this.url = options.url ?? `ws://127.0.0.1:${port}/acp`;
    const known = Object.values(builds).find((entry) => entry.port === port && !options.url);
    this.openURL = options.openURL !== undefined ? options.openURL : known?.openURL ?? null;
    this.installURL = options.installURL !== undefined ? options.installURL : known?.installURL ?? null;
    this.homebrew = known?.homebrew ?? null;
    this.bundleIdentifier = options.bundleIdentifier !== undefined ? options.bundleIdentifier : known?.bundleIdentifier ?? null;
    if (options.minimumVersion !== undefined && !/^\d+(\.\d+){0,2}$/.test(options.minimumVersion)) {
      throw new TypeError(`minimumVersion must be a version such as "0.5.0", not ${JSON.stringify(options.minimumVersion)}.`);
    }
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
   * `guide` is asked whether to get it or open it; without it, this rejects with `NotInstalledError`, `NotRunningError`
   * or `OutdatedError`.
   */
  connect(options: ConnectOptions = {}): Promise<Access> {
    if (this.#state === 'connected' && this.#connection?.isOpen && this.#access && options.pair !== 'always') return Promise.resolve(this.#access);
    // One connect at a time: a second call while one runs gets the same outcome.
    if (this.#connecting) return this.#connecting;
    const connecting = this.#cancellable(options.signal, (signal) => this.#connect({ ...options, signal })).finally(() => { if (this.#connecting === connecting) this.#connecting = null; });
    this.#connecting = connecting;
    return connecting;
  }

  async #connect(options: ConnectOptions): Promise<Access> {
    if (options.guide && !this.options.environment) {
      throw new TypeError('connect({ guide }) needs the client\'s environment: nodeEnvironment() or electronEnvironment() from @agneta/client/node.');
    }
    this.#closing = false;
    this.#cancelReconnect();
    // Already connected (pairing again for a wider scope): a failure, the user's Don't Allow included, keeps what works.
    const wasConnected = this.#state === 'connected' && this.#connection?.isOpen === true && this.#access !== null;
    this.#flow = { options, updateAsked: false };
    try {
      const connection = await this.#reach(options);
      try {
        if (this.options.minimumVersion) await this.#checkVersion(options);
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
          if (options.setup) await this.#setUpProvider(options.setup === true ? undefined : options.setup, options);
          await this.pair(options.scope ?? this.options.scope, { signal: options.signal });
        }
        this.#setState('connected');
        this.#progress({ step: 'connected' });
        return this.#access!;
      } catch (error) {
        // The connection may have been replaced meanwhile (reopened during setup, or after an update).
        const current = this.#connection;
        if (current) {
          if (wasConnected && current === connection && current.isOpen) this.#setState('connected');
          else this.#drop(current);
        }
        throw error;
      }
    } finally {
      this.#flow = null;
    }
  }

  /** Opens the connection, or, when Agneta isn't running, finds out why and guides the user. */
  async #reach(options: ConnectOptions): Promise<Connection> {
    this.#progress({ step: 'looking' });
    try {
      return await this.open(options.signal ? { signal: options.signal } : {});
    } catch (error) {
      if (!(error instanceof NotRunningError) || this.#quiet) throw error;
      try {
        return await this.#getAgneta(error, options);
      } catch (failure) {
        if (!this.#connection) this.#setState('disconnected');
        throw failure;
      }
    }
  }

  /** Agneta didn't answer: not installed, only on its disk image, too old, or not running. One question for each. */
  async #getAgneta(notRunning: NotRunningError, options: ConnectOptions): Promise<Connection> {
    const { guide, signal } = options;
    const atLaunch = options.pair === 'never';
    const presence = await this.#lookUp();
    stopIfAborted(signal);
    if (presence.state === 'notInstalled' || presence.state === 'onDiskImage') {
      const onDiskImage = presence.state === 'onDiskImage';
      this.#progress({ step: onDiskImage ? 'onDiskImage' : 'notInstalled' });
      if (!guide || atLaunch || !this.installURL) throw new NotInstalledError(this.installURL, this.homebrew, onDiskImage);
      if (!await this.#ask(guide, this.#question('install', { onDiskImage }), signal)) throw new DeclinedError('install');
      // The yes covers opening Agneta once it's installed, in this flow (docs/APP_PROTOCOL.md, Getting Agneta).
      if (!onDiskImage) await this.openInstallPage();
      stopIfAborted(signal);
      return this.waitForAgneta({ installing: true, openWhenInstalled: true, ...(signal ? { signal } : {}) });
    }
    if (presence.state !== 'notRunning') throw notRunning;
    const needed = this.options.minimumVersion;
    if (needed && this.#tooOld(presence.version)) {
      this.#progress({ step: 'outdated', version: presence.version, needed });
      if (!guide || atLaunch) throw new OutdatedError(presence.version, needed);
      if (!await this.#ask(guide, this.#question('update', { version: presence.version, running: false }), signal)) throw new DeclinedError('update');
      this.#flow!.updateAsked = true;
    } else {
      this.#progress({ step: 'notRunning' });
      // At launch, only someone who has used the app (a token kept) is offered to open Agneta.
      if (!guide || (atLaunch && !await this.tokens.load())) throw notRunning;
      stopIfAborted(signal);
      if (!await this.#ask(guide, this.#question('open'), signal)) throw new DeclinedError('open');
    }
    stopIfAborted(signal);
    if (!await this.openAgneta()) throw notRunning;
    return this.waitForAgneta({ opened: true, ...(signal ? { signal } : {}) });
  }

  /**
   * Where Agneta is: `running` (something answers on its port), `blocked` (this app may not connect at all), or, from
   * the environment, installed and not running (with its version), only on its disk image, not installed, or `unknown`
   * without an environment. It never says the path.
   */
  async presence(): Promise<AgnetaPresence> {
    if (this.#connection?.isOpen) return { state: 'running' };
    const found = await (this.options.probe ?? probeAgneta)(this.url).catch((): PortProbe => 'notListening');
    if (found === 'listening') return { state: 'running' };
    if (found === 'blocked') return { state: 'blocked', reason: 'This app may not connect to Agneta: a sandboxed app needs the com.apple.security.network.client entitlement.' };
    return this.#lookUp();
  }

  /**
   * Opens the page where the user gets Agneta (`installURL`), with the Mac's architecture as its fragment so the right
   * download comes first. Only after the user asked. Resolves to whether it opened.
   */
  async openInstallPage(options: { architecture?: Architecture | null } = {}): Promise<boolean> {
    const environment = this.#environment('openInstallPage');
    if (!this.installURL) return false;
    const architecture = options.architecture !== undefined ? options.architecture : await environment.architecture?.().catch(() => null) ?? null;
    return environment.openURL(installPageURL(this.installURL, architecture));
  }

  /** Opens Agneta (`openURL`). Only after the user asked: quitting Agneta is how they stop all of it. Resolves to whether it opened. */
  async openAgneta(): Promise<boolean> {
    const environment = this.#environment('openAgneta');
    if (!this.openURL) return false;
    return environment.openURL(this.openURL);
  }

  /**
   * Waits until Agneta answers, and resolves with the open connection (as `open` does). It polls the port: every 250 ms
   * for 5 s after an open, then every second. With `installing`, it also looks for Agneta to appear (and, with
   * `openWhenInstalled`, opens it). Cancel with the signal.
   */
  waitForAgneta(options: WaitForAgnetaOptions = {}): Promise<Connection> {
    return this.#cancellable(options.signal, (signal) => this.#waitForAgneta({ ...options, signal }));
  }

  async #waitForAgneta(options: WaitForAgnetaOptions): Promise<Connection> {
    if (this.#connection?.isOpen) return this.#connection;
    const report = (progress: ProgressStep) => { const full = this.#progress(progress); options.onProgress?.(full); };
    const open = this.#openOptions(options.signal);
    const started = Date.now();
    let openedAt = options.opened ? started : null;
    let seen: AgnetaPresence['state'] | null = null;
    let looked = -Infinity;
    let slow = 0;
    this.#setState('connecting');
    if (openedAt !== null) report({ step: 'opening' });
    else if (options.installing) report({ step: 'installing' });
    try {
      for (;;) {
        try {
          const connection = await Connection.open(open);
          // Opened meanwhile by another call (`open`, `catalog`): use that one, never leave a second socket open.
          if (this.#connection?.isOpen) {
            connection.close();
            return this.#connection;
          }
          this.#attach(connection);
          report({ step: 'connecting' });
          return connection;
        } catch (error) {
          if (!(error instanceof NotRunningError)) throw error;
        }
        const now = Date.now();
        if (openedAt !== null) {
          const waited = now - openedAt;
          // Once at `slow` (macOS may be asking), once more at `keepWaiting` (offer Keep Waiting or Cancel).
          const due = waited >= this.timeouts.keepWaiting ? 2 : waited >= this.timeouts.slow ? 1 : 0;
          if (due > slow) {
            slow = due;
            report({ step: 'slow', seconds: Math.round(waited / 1000), keepWaiting: due === 2 });
          }
        } else if (options.installing && now - looked >= (this.options.environment?.lookupInterval ?? 1000)) {
          looked = now;
          const presence = await this.#lookUp();
          stopIfAborted(options.signal);
          if (presence.state !== seen) {
            seen = presence.state;
            if (presence.state === 'onDiskImage') report({ step: 'onDiskImage' });
            if (presence.state === 'notRunning') report({ step: 'installed' });
          }
          // Installed: open it. Should opening fail (macOS refused, say), it's tried again at the next look.
          if (presence.state === 'notRunning' && options.openWhenInstalled && await this.openAgneta()) {
            stopIfAborted(options.signal);
            openedAt = Date.now();
            report({ step: 'opening' });
          }
        }
        const limit = options.timeout ?? (openedAt !== null || !options.installing ? this.timeouts.open : 0);
        const since = options.timeout !== undefined ? started : openedAt ?? started;
        if (limit > 0 && Date.now() - since >= limit) throw new NotRunningError(this.url, this.openURL);
        await delay(openedAt !== null && Date.now() - openedAt < 5000 ? 250 : 1000, options.signal);
      }
    } catch (error) {
      if (!this.#connection) this.#setState('disconnected');
      throw error;
    }
  }

  /**
   * Opens the WebSocket only (for `agneta/catalog` and `agneta/setup` before pairing). Resolves with the raw connection;
   * reuses an open one. When Agneta isn't running it rejects (`NotRunningError`): `connect` is what guides the user.
   */
  open(options: { signal?: AbortSignal } = {}): Promise<Connection> {
    if (options.signal?.aborted) return Promise.reject(new AbortedError('connect', { cause: options.signal.reason }));
    if (this.#connection?.isOpen) return Promise.resolve(this.#connection);
    if (this.#opening) return this.#opening;
    const opening = this.#cancellable(options.signal, (signal) => this.#openSocket({ signal })).finally(() => { if (this.#opening === opening) this.#opening = null; });
    this.#opening = opening;
    return opening;
  }

  async #openSocket(options: { signal?: AbortSignal }): Promise<Connection> {
    if (!this.options.WebSocket && typeof (globalThis as { document?: unknown }).document !== 'undefined') {
      throw new UnsupportedEnvironmentError('Agneta refuses connections from web pages (anything sending an Origin header). Connect from Node or Electron\'s main process.');
    }
    this.#setState('connecting');
    let connection: Connection;
    try {
      connection = await Connection.open(this.#openOptions(options.signal));
    } catch (error) {
      this.#setState('disconnected');
      throw error;
    }
    if (options.signal?.aborted) { connection.close(); stopIfAborted(options.signal); }
    this.#attach(connection);
    return connection;
  }

  #openOptions(signal?: AbortSignal): OpenOptions {
    return {
      url: this.url, openURL: this.openURL, connectTimeout: this.timeouts.connect, requestTimeout: this.timeouts.request,
      ...(this.options.WebSocket ? { WebSocket: this.options.WebSocket } : {}), ...(this.options.probe ? { probe: this.options.probe } : {}),
      ...(signal ? { signal } : {})
    };
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
    this.#progress({ step: 'pairing', code: null });
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
    for (const operation of this.#operations) operation.abort();
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
    const declaration = this.#declaration(options);
    const agneta = { ...(options.account ? { account: options.account } : {}), ...(options.engine ? { engine: options.engine } : {}) };
    const meta = this.#meta(options, Object.keys(agneta).length ? agneta : undefined, declaration);
    const params = { cwd, mcpServers: options.mcpServers ?? [], ...(meta ? { _meta: meta } : {}), ...options.params };
    return this.#open('session/new', params, options, (result) => result.sessionId, declaration?.schemas);
  }

  /**
   * `session/load`: reopens one of the app's earlier tasks. Pass the tool servers again (bearers are per session). The
   * replayed conversation is in `session.history`. Instructions appended with `setInstructions` aren't restored.
   */
  async loadSession(sessionId: string, options: LoadSessionOptions = {}): Promise<Session> {
    const cwd = options.cwd ?? this.#requireAccess().workspace;
    if (!cwd) throw new TypeError('loadSession needs a cwd.');
    const declaration = this.#declaration(options);
    const meta = this.#meta(options, undefined, declaration);
    const params = { sessionId, cwd, mcpServers: options.mcpServers ?? [], ...(meta ? { _meta: meta } : {}), ...options.params };
    // Agneta keeps the original's declaration: so does a handle still known here.
    const declared = declaration?.schemas ?? this.#sessions.get(sessionId)?.declaredSchemas;
    this.#early.set(sessionId, []);
    return this.#open('session/load', params, options, () => sessionId, declared);
  }

  /** `agneta/fork`: a new task with a copy of one of the app's tasks, open or finished. Without a policy: the original's, read-only. */
  async fork(source: string | Session, options: ForkOptions = {}): Promise<Session> {
    const sessionId = typeof source === 'string' ? source : source.id;
    const declaration = this.#declaration(options);
    const meta = this.#meta(options, undefined, declaration);
    const params = { sessionId, mcpServers: options.mcpServers ?? [], ...(options.cwd ? { cwd: options.cwd } : {}), ...(meta ? { _meta: meta } : {}), ...options.params };
    // Agneta keeps the original's declaration: so does the fork of a handle known here.
    const declared = declaration?.schemas ?? (typeof source === 'string' ? this.#sessions.get(source) : source)?.declaredSchemas;
    return this.#open('agneta/fork', params, options, (result) => result.sessionId, declared);
  }

  /**
   * One question with a structured answer: opens a session that declares the schema (`{ schema }`), asks, and closes
   * it, also when the ask fails. `await` it for the value, `answer.details` for how it came; `onTurn` gets the turn.
   * The schema forms, checks and errors are `session.ask`'s, and opening's errors are `newSession`'s
   * (`UnenforceableError` with `fields: ['agneta/result']` for a schema Agneta refuses).
   */
  ask<const S extends StandardJSONSchemaV1, T>(input: PromptInput, options: OneShotOptions & { schema: S; parse: (value: FromStandardSchema<S>) => T }): Answer<T>;
  ask<const S extends StandardJSONSchemaV1>(input: PromptInput, options: OneShotOptions & { schema: S }): Answer<FromStandardSchema<S>>;
  ask<T>(input: PromptInput, options: OneShotOptions & { schema: SchemaInput; parse: (value: unknown) => T }): Answer<T>;
  ask<const S extends JsonSchema>(input: PromptInput, options: OneShotOptions & { schema: S }): Answer<FromSchema<S>>;
  ask<T = unknown>(input: PromptInput, options: OneShotOptions & { schema: SchemaInput }): Answer<T>;
  ask(input: PromptInput, options: OneShotOptions & { schema: SchemaInput; parse?: (value: any) => unknown }): Answer<unknown> {
    const { schema, parse, attempts, timeout, policy, onTurn, ...rest } = options;
    return new Answer((async () => {
      let session: Session | undefined;
      try {
        session = await this.newSession({ ...rest, policy: policy ?? { tools: 'app-only', approval: 'never-ask' }, results: { schema } });
        const asked = session.ask(input, {
          name: 'result', schema, ...(parse ? { parse } : {}), ...(attempts !== undefined ? { attempts } : {}),
          ...(timeout !== undefined ? { timeout } : {}), ...(rest.signal ? { signal: rest.signal } : {})
        });
        onTurn?.(asked.turn);
        return await asked.details;
      } finally {
        await session?.close().catch(() => {});
      }
    })());
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

  async #cancellable<T>(signal: AbortSignal | undefined, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const controller = new AbortController();
    this.#operations.add(controller);
    try {
      const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
      stopIfAborted(combined);
      return await run(combined);
    } finally {
      this.#operations.delete(controller);
    }
  }

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

  /** `results` made ready, refused before sending when this Agneta doesn't offer structured results. */
  #declaration(options: SessionOptionsBase): PreparedDeclaration | undefined {
    if (options.results === undefined) return undefined;
    this.#requireAccess();
    if (!this.extensions.includes(resultExtension)) throw new UnsupportedByAgnetaError(resultExtension, 'structured results');
    return prepareDeclaration(options.results);
  }

  #meta(options: SessionOptionsBase, agneta?: SessionRequestMeta['agneta'], declaration?: PreparedDeclaration): SessionRequestMeta | undefined {
    const meta: SessionRequestMeta = {};
    if (agneta) meta.agneta = agneta;
    if (declaration) meta[resultExtension] = declaration.wire;
    if (options.policy) meta['agneta/policy'] = options.policy;
    if (options.task) meta['agneta/task'] = typeof options.task === 'string' ? { title: options.task } : options.task;
    if (options.instructions !== undefined) meta['agneta/instructions'] = { text: options.instructions };
    if (options.appTools) meta['agneta/appTools'] = { load: options.appTools };
    if (options.trace) meta['agneta/trace'] = options.trace === true ? { live: true } : options.trace;
    Object.assign(meta, options.meta);
    return Object.keys(meta).length ? meta : undefined;
  }

  async #open(method: 'session/new' | 'session/load' | 'agneta/fork', params: any, options: SessionOptionsBase,
    idOf: (result: SessionResult) => string | undefined, declared?: ReadonlyMap<string, PreparedSchema>): Promise<Session> {
    const connection = this.#require();
    this.#requireAccess();
    const wait = options.waitForDownload === false ? 0 : typeof options.waitForDownload === 'number' ? options.waitForDownload : 600_000;
    const started = Date.now();
    // A load of a session whose earlier handle is still registered (its close reply was lost) unregisters that handle
    // first, so the load's replay and anything else sent for the id meanwhile reach the new handle, not the old one.
    // A load that fails gives the id back to the earlier handle.
    const stale = method === 'session/load' ? this.#sessions.get(params.sessionId) : undefined;
    if (stale) this.#sessions.delete(params.sessionId);
    let result: SessionResult;
    try {
      for (;;) {
        try {
          result = await this.#openRequest(connection, method, params, options.timeout ?? this.timeouts.session, options.signal);
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
    } catch (error) {
      if (stale && !this.#sessions.has(params.sessionId)) {
        this.#early.delete(params.sessionId);
        this.#sessions.set(params.sessionId, stale);
      }
      throw error;
    } finally {
      if (method === 'session/load') queueMicrotask(() => { if (!this.#sessions.has(params.sessionId)) this.#early.delete(params.sessionId); });
    }
    const id = idOf(result);
    if (typeof id !== 'string' || !id) throw new ProtocolError(`Agneta returned no session id for ${method}.`, result);
    const early = this.#early.get(id) ?? [];
    this.#early.delete(id);
    const history = early.filter(({ method }) => method === 'session/update').map(({ params }) => params.update as SessionUpdate);
    // What it declared: as given, as a handle known here had it, else as Agneta's reply recorded it (a task resumed in
    // another process).
    const schemas = declared?.size ? declared : recordedSchemas(result._meta?.agneta?.results?.schemas);
    const session = new Session(this.#host, id, { ...result, sessionId: id }, history, options.permissions, options.on, schemas);
    if (this.#connection !== connection || !connection.isOpen) {
      session.end({ reason: 'disconnected', error: new ConnectionClosedError(undefined, 'closed while the session opened') });
      throw new ConnectionClosedError(undefined, 'closed while the session opened');
    }
    const previous = this.#sessions.get(id) ?? (stale && id === params.sessionId ? stale : undefined);
    this.#sessions.set(id, session);
    previous?.end({ reason: 'closed' });
    // The rest of what came early (live trace records, a queue place, a stop), to the listeners given in `on`.
    for (const { method, params } of early) if (method !== 'session/update') session.receive(method, params);
    return session;
  }

  /**
   * One attempt at opening, with its own timeout and the caller's signal, so a reply that arrives after the caller gave
   * up is still seen: that session is open in Agneta, and nothing will ever use it, so it's closed.
   */
  #openRequest(connection: Connection, method: 'session/new' | 'session/load' | 'agneta/fork', params: any, timeout: number,
    signal: AbortSignal | undefined): Promise<SessionResult> {
    if (signal?.aborted) return Promise.reject(new AbortedError(method, { cause: signal.reason }));
    const sent = connection.request(method, params, { timeout: 0 });
    return new Promise((resolve, reject) => {
      let gaveUp = false;
      const timer = timeout > 0 && Number.isFinite(timeout) ? setTimeout(() => giveUp(new TimeoutError(method, timeout)), timeout) : undefined;
      const abort = () => giveUp(new AbortedError(method, { cause: signal?.reason }));
      const cleanup = () => {
        if (timer) clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
      };
      const giveUp = (error: Error) => {
        gaveUp = true;
        cleanup();
        reject(error);
      };
      signal?.addEventListener('abort', abort, { once: true });
      sent.then((result) => {
        if (!gaveUp) {
          cleanup();
          resolve(result);
          return;
        }
        const id = result?.sessionId ?? params.sessionId;
        if (method === 'session/load' && this.#sessions.has(id)) return;
        if (typeof id === 'string' && connection.isOpen) connection.request('session/close', { sessionId: id }).catch(() => {});
        this.#early.delete(id);
      }, (error) => {
        if (gaveUp) return;
        cleanup();
        reject(error);
      });
    });
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
      supports: (extension) => client.extensions.includes(extension),
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
          if (this.#state === 'pairing') this.#progress({ step: 'pairing', code: params.code });
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

  /** A quiet connect: never guides nor pairs. */
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

  /** Before pairing, with no provider (of `kind`) connected: asks (with a guide), shows Agneta's window, waits for one. */
  async #setUpProvider(kind: ProviderKind | undefined, options: ConnectOptions): Promise<void> {
    const signal = options.signal;
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
    const kinds = kind ? [kind] : null;
    this.#progress({ step: 'needsProvider', kinds });
    if (options.guide && !await this.#ask(options.guide, this.#question('setup', { kinds }), signal)) throw new DeclinedError('setup');
    let waiting = this.waitForProvider(kind, signal ? { signal } : {});
    waiting.catch(() => {});
    await this.setup(kind ? { kind } : {}, signal ? { signal } : {});
    this.emit('setup', kind);
    this.#progress({ step: 'settingUp', kinds });
    for (;;) {
      try {
        await waiting;
        return;
      } catch (error) {
        // Agneta closes a connection that hasn't paired after 10 minutes, time in setup included, while the user may
        // still be signing in: open another, quietly, and go on waiting. Its window stays up meanwhile.
        if (!(error instanceof ConnectionClosedError) || signal?.aborted || this.#closing) throw error;
        try {
          await this.open(signal ? { signal } : {});
        } catch {
          throw error;
        }
        waiting = this.waitForProvider(kind, signal ? { signal } : {});
      }
    }
  }

  /**
   * With `minimumVersion`: Agneta's version from the catalog (an Agneta without `agneta/catalog` is 0.4.0 or earlier).
   * Too old: ask once (with a guide) and wait while the user updates in Agneta, which relaunches; then check again.
   */
  async #checkVersion(options: ConnectOptions): Promise<void> {
    const needed = this.options.minimumVersion!;
    for (;;) {
      let version: string | null = null;
      let tooOld: boolean;
      try {
        version = (await this.catalog(options.signal ? { signal: options.signal } : {})).version ?? null;
        tooOld = this.#tooOld(version);
      } catch (error) {
        if (!(error instanceof MethodNotFoundError)) throw error;
        // Agneta added agneta/catalog after 0.4.0: one without it is 0.4.0 or earlier.
        tooOld = this.#tooOld(lastWithoutCatalog);
      }
      if (!tooOld) return;
      this.#progress({ step: 'outdated', version, needed });
      if (!options.guide || options.pair === 'never') throw new OutdatedError(version, needed);
      if (!this.#flow!.updateAsked) {
        if (!await this.#ask(options.guide, this.#question('update', { version, running: true }), options.signal)) throw new DeclinedError('update');
        this.#flow!.updateAsked = true;
      }
      const connection = this.#connection;
      if (connection?.isOpen) await abortable(connection.closed, options.signal);
      await this.waitForAgneta({ opened: true, ...(options.signal ? { signal: options.signal } : {}) });
    }
  }

  #tooOld(version: string | null): boolean {
    const comparison = compareVersions(version, this.options.minimumVersion);
    return comparison !== null && comparison < 0;
  }

  #lookUp(): Promise<AgnetaPresence> {
    return lookUpAgneta(this.options.environment, { openURL: this.openURL, bundleIdentifier: this.bundleIdentifier });
  }

  #environment(method: string): AgnetaEnvironment {
    const environment = this.options.environment;
    if (!environment) throw new TypeError(`${method} needs the client's environment: nodeEnvironment() or electronEnvironment() from @agneta/client/node.`);
    return environment;
  }

  /** The guide's answer; a cancelled connect stops waiting for it, and a late yes then counts for nothing. */
  async #ask(guide: Guide, question: GuideQuestion, signal?: AbortSignal): Promise<boolean> {
    stopIfAborted(signal);
    const answer = (await abortable(Promise.resolve(guide(question)), signal)) === true;
    stopIfAborted(signal);
    return answer;
  }

  /** Reports a step of the connect in progress, in words; nothing for a quiet reconnect. */
  #progress(step: ProgressStep): ConnectProgress {
    const progress = { ...step, ...this.#describe(step) } as ConnectProgress;
    if (this.#quiet) return progress;
    try {
      this.#flow?.options.onProgress?.(progress);
    } catch (error) {
      this.emit('error', error);
    }
    this.emit('progress', progress);
    return progress;
  }

  #describe(step: ProgressStep): { title: string; detail: string } {
    const app = this.options.name, agneta = this.agnetaName;
    switch (step.step) {
      case 'looking': return { title: `Connecting to ${agneta}…`, detail: '' };
      case 'notInstalled': return { title: `${app} runs its AI through ${agneta}`, detail: `${agneta} isn't installed on this Mac yet.` };
      case 'installing': return {
        title: `Install ${agneta}`,
        detail: this.homebrew
          ? `Install ${agneta} from the page that opened: open the disk image and drag ${agneta} into Applications. Or use Homebrew. ${app} goes on by itself.`
          : `Install ${agneta} as the page that opened says. ${app} goes on by itself.`
      };
      case 'onDiskImage': return { title: `Drag ${agneta} into Applications`, detail: `${agneta} is on its disk image, not in Applications yet: drag it into Applications. ${app} goes on by itself.` };
      case 'installed': return { title: `${agneta} is installed`, detail: '' };
      case 'notRunning': return { title: `${agneta} isn't running`, detail: `${app} runs its AI tasks through ${agneta}, on the plan or API key you allow.` };
      case 'opening': return { title: `Opening ${agneta}…`, detail: '' };
      case 'slow': return {
        title: `Still opening ${agneta}…`,
        detail: `If macOS asks whether to open ${agneta}, choose Open.${step.keepWaiting ? ' It\'s taking longer than it should: keep waiting, or cancel.' : ''}`
      };
      case 'connecting': return { title: `Connecting to ${agneta}…`, detail: '' };
      case 'outdated': return { title: `${app} needs a newer ${agneta}`, detail: this.#updateText(step.version, step.needed) };
      case 'needsProvider': return { title: `Connect your AI in ${agneta}`, detail: `${app} needs ${kindsText(step.kinds)}: connect one in ${agneta}.` };
      case 'settingUp': return { title: `Connect your AI in ${agneta}`, detail: `Finish in ${agneta}'s window. ${app} goes on once it's connected.` };
      case 'pairing': return {
        title: `Approve ${app} in ${agneta}`,
        detail: step.code ? `Check that ${agneta} shows ${step.code}, then allow ${app}.` : `Allow ${app} in ${agneta}'s window.`
      };
      case 'connected': return { title: `Connected to ${agneta}`, detail: '' };
    }
  }

  #updateText(version: string | null, needed: string): string {
    const app = this.options.name, agneta = this.agnetaName;
    return `${app} needs ${agneta} ${needed} or later${version ? `; this Mac has ${version}` : ''}. Choose Check for Updates… in ${agneta}'s ⋯ menu, in the menu bar. ${app} goes on when it's updated.`;
  }

  #question(kind: 'install', extra: { onDiskImage: boolean }): GuideQuestion;
  #question(kind: 'open'): GuideQuestion;
  #question(kind: 'update', extra: { version: string | null; running: boolean }): GuideQuestion;
  #question(kind: 'setup', extra: { kinds: ProviderKind[] | null }): GuideQuestion;
  #question(kind: GuideQuestion['kind'], extra: any = {}): GuideQuestion {
    const app = this.options.name, agneta = this.agnetaName, agnetaName = agneta;
    switch (kind) {
      case 'install': return extra.onDiskImage
        ? { kind, agnetaName, installURL: this.installURL!, homebrew: this.homebrew, onDiskImage: true, title: `Drag ${agneta} into Applications`,
            detail: `${agneta} is on its disk image, not in Applications yet. Drag it into Applications, and ${app} opens it once it's there.`, confirm: 'Continue', cancel: 'Cancel' }
        : { kind, agnetaName, installURL: this.installURL!, homebrew: this.homebrew, onDiskImage: false, title: `Get ${agneta}`,
            detail: this.homebrew
              ? `${app} runs its AI through ${agneta}, a free, open-source menu bar app that keeps your AI plan or key on your Mac (signed and notarized, macOS 14 or later). ${app} opens it once it's installed.`
              : `${app} runs its AI through ${agneta}, which is built from source. ${app} opens it once it's installed.`,
            confirm: `Get ${agneta}`, cancel: 'Cancel' };
      case 'open': return { kind, agnetaName, title: `${agneta} isn't running`, detail: `${app} runs its AI tasks through ${agneta}, on the plan or API key you allow. Open ${agneta} now?`, confirm: `Open ${agneta}`, cancel: 'Not Now' };
      case 'update': return {
        kind, agnetaName, version: extra.version, needed: this.options.minimumVersion!, running: extra.running, title: `Update ${agneta}`,
        detail: this.#updateText(extra.version, this.options.minimumVersion!), confirm: extra.running ? 'Continue' : `Open ${agneta}`, cancel: 'Cancel'
      };
      case 'setup': return {
        kind, agnetaName, kinds: extra.kinds, title: `Connect your AI in ${agneta}`,
        detail: `${app} needs ${kindsText(extra.kinds)}. ${agneta} shows its window for connecting one.`, confirm: `Connect in ${agneta}`, cancel: 'Cancel'
      };
    }
  }
}

/** A progress step before its words. */
type ProgressStep = ConnectProgress extends infer P ? P extends ConnectProgress ? Omit<P, 'title' | 'detail'> : never : never;

function kindsText(kinds: ProviderKind[] | null): string {
  if (!kinds?.length) return 'a ChatGPT or Claude plan, or an API key';
  return kinds.map((kind) => kindNames[kind] ?? kind).join(' or ');
}

/** The last Agneta release without `agneta/catalog`: an Agneta that answers it with -32601 counts as this version. */
const lastWithoutCatalog = '0.4.0';

/** Throws `AbortedError` once the signal has ended the connect: nothing is opened after a Cancel. */
function stopIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new AbortedError('connect', { cause: signal.reason });
}

/** Resolves with `promise`, or rejects with `AbortedError` when the signal ends the wait first. */
function abortable<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(new AbortedError('wait', { cause: signal.reason }));
  return new Promise((resolve, reject) => {
    const abort = () => reject(new AbortedError('wait', { cause: signal.reason }));
    signal.addEventListener('abort', abort, { once: true });
    promise.then((value) => { signal.removeEventListener('abort', abort); resolve(value); },
      (error) => { signal.removeEventListener('abort', abort); reject(error); });
  });
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
  const { pair, setup, scope, guide, onProgress, signal, ...clientOptions } = options;
  const client = new AgnetaClient({ ...clientOptions, ...(scope ? { scope } : {}) });
  await client.connect({ ...(pair ? { pair } : {}), ...(setup ? { setup } : {}), ...(guide ? { guide } : {}), ...(onProgress ? { onProgress } : {}), ...(signal ? { signal } : {}) });
  return client;
}
