// JSON-RPC 2.0 over one WebSocket, one message per text frame: the raw layer. Every Agneta method is typed; any other
// method can still be sent (Agneta answers what it doesn't offer with -32601). It tells "nothing is listening" from
// "something answered but refused the upgrade", and a timeout rejects one call, never the connection.
import { Emitter } from './emitter.js';
import {
  AbortedError, ConnectionClosedError, ConnectionRefusedError, fromRpcError, NetworkBlockedError, NotRunningError, ProtocolError, TimeoutError,
  type RpcErrorObject
} from './errors.js';
import type { AgnetaClientRequests, AgnetaNotifications, AgnetaRequests, AppNotifications } from './protocol.js';

export type JsonRpcId = number | string;

export interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: JsonRpcId;
  method: string;
  params?: unknown;
}

export interface JsonRpcNotification {
  jsonrpc: '2.0';
  method: string;
  params?: unknown;
}

export type JsonRpcResponse =
  | { jsonrpc: '2.0'; id: JsonRpcId | null; result: unknown }
  | { jsonrpc: '2.0'; id: JsonRpcId | null; error: RpcErrorObject };

export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

/** `in`: from Agneta. `out`: to Agneta. */
export type Direction = 'in' | 'out';

/** What the library needs of a WebSocket: the WHATWG one (Node 22+, Electron's main process), or a compatible one. */
export interface WebSocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: 'open' | 'message' | 'close' | 'error', listener: (event: any) => void, options?: { once?: boolean }): void;
}

export type WebSocketConstructor = new (url: string) => WebSocketLike;

/** What answers at an address: something (`listening`), nothing, or nothing this app may reach (`blocked`: `EPERM`). */
export type PortProbe = 'listening' | 'notListening' | 'blocked';

export interface RequestOptions {
  /** Milliseconds; 0 or Infinity for none. Default: the connection's `requestTimeout`. */
  timeout?: number;
  signal?: AbortSignal;
}

export interface OpenOptions {
  url: string;
  /** The URL that opens this Agneta, put in `NotRunningError`. */
  openURL?: string | null;
  WebSocket?: WebSocketConstructor;
  /** How long to wait for the upgrade. Default 5 s. */
  connectTimeout?: number;
  /** Default timeout for requests. Default 30 s. */
  requestTimeout?: number;
  /**
   * Whether anything listens at the URL's host and port, to tell "not running" from "refused" (and both from an app
   * that may not connect at all). Default: `probeAgneta`.
   */
  probe?: (url: string) => Promise<PortProbe>;
  signal?: AbortSignal;
}

/** Answers one request from Agneta. A thrown error with a numeric `code` becomes that JSON-RPC error. */
export type RequestHandler<Params = unknown, Result = unknown> = (params: Params, request: JsonRpcRequest) => Result | Promise<Result>;

export type ConnectionEvents = {
  /** Every notification from Agneta. */
  notification: [method: string, params: unknown];
  /** Every message, both ways, as sent or received. */
  message: [message: JsonRpcMessage, direction: Direction];
  /** The connection closed. Pending requests have been rejected with this error. */
  close: [error: ConnectionClosedError];
};

interface Pending {
  method: string;
  resolve(value: unknown): void;
  reject(error: unknown): void;
  cleanup(): void;
}

const OPEN = 1;

export class Connection extends Emitter<ConnectionEvents> {
  readonly url: string;
  readonly requestTimeout: number;
  #socket: WebSocketLike;
  #pending = new Map<JsonRpcId, Pending>();
  #handlers = new Map<string, RequestHandler<any, any>>();
  #nextId = 1;
  #writing = false;
  #outgoing: Array<{ message: JsonRpcMessage; text: string; signal: AbortSignal | undefined }> = [];
  #closedError: ConnectionClosedError | null = null;
  #closed: Promise<ConnectionClosedError>;
  #markClosed!: (error: ConnectionClosedError) => void;

  private constructor(socket: WebSocketLike, url: string, requestTimeout: number) {
    super();
    this.#socket = socket;
    this.url = url;
    this.requestTimeout = requestTimeout;
    this.#closed = new Promise((resolve) => { this.#markClosed = resolve; });
    socket.addEventListener('message', (event: { data: unknown }) => this.#receive(event.data));
    socket.addEventListener('close', (event: { code?: number; reason?: string }) => this.#end(new ConnectionClosedError(event?.code, event?.reason || undefined)), { once: true });
  }

  /**
   * Opens the WebSocket. Rejects with `NotRunningError` when nothing listens, `ConnectionRefusedError` when something
   * answered but refused the upgrade, `NetworkBlockedError` when this app may not connect at all (a sandbox without the
   * network client entitlement), `TimeoutError` when the upgrade takes too long.
   */
  static open(options: OpenOptions): Promise<Connection> {
    if (options.signal?.aborted) return Promise.reject(new AbortedError('connect', { cause: options.signal.reason }));
    const WebSocketClass = options.WebSocket ?? (globalThis as { WebSocket?: WebSocketConstructor }).WebSocket;
    if (!WebSocketClass) return Promise.reject(new TypeError('No WebSocket here: use Node 22 or later, or pass the WebSocket option.'));
    const timeout = options.connectTimeout ?? 5000;
    return new Promise<Connection>((resolve, reject) => {
      let socket: WebSocketLike;
      try {
        socket = new WebSocketClass(options.url);
      } catch (error) {
        reject(error);
        return;
      }
      let settled = false;
      const settle = (outcome: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        options.signal?.removeEventListener('abort', abort);
        outcome();
      };
      const timer = setTimeout(() => settle(() => {
        reject(new TimeoutError('connect', timeout));
        try { socket.close(); } catch {}
      }), timeout);
      const abort = () => settle(() => {
        reject(new AbortedError('connect', { cause: options.signal?.reason }));
        try { socket.close(); } catch {}
      });
      if (options.signal?.aborted) return abort();
      options.signal?.addEventListener('abort', abort, { once: true });
      // The connection exists before `open`, so no message is missed between the upgrade and the caller's handlers.
      const connection = new Connection(socket, options.url, options.requestTimeout ?? 30_000);
      socket.addEventListener('open', () => settle(() => resolve(connection)), { once: true });
      const failed = () => {
        if (settled) return;
        const probe = options.probe ?? probeAgneta;
        probe(options.url).catch((): PortProbe => 'notListening').then((found) => settle(() => {
          try { socket.close(); } catch {}
          reject(found === 'listening' ? new ConnectionRefusedError(options.url)
            : found === 'blocked' ? new NetworkBlockedError(options.url)
              : new NotRunningError(options.url, options.openURL ?? null));
        }));
      };
      socket.addEventListener('error', failed, { once: true });
      socket.addEventListener('close', failed, { once: true });
    });
  }

  /** Whether the connection is open. */
  get isOpen(): boolean {
    return !this.#closedError && this.#socket.readyState === OPEN;
  }

  /** Resolves when the connection closes, with why. */
  get closed(): Promise<ConnectionClosedError> {
    return this.#closed;
  }

  /** Sends a request and resolves with its result, or rejects with a typed error (`AgnetaRpcError` for Agneta's). */
  request<M extends keyof AgnetaRequests>(method: M, params: AgnetaRequests[M]['params'], options?: RequestOptions): Promise<AgnetaRequests[M]['result']>;
  /** Any other method. (A known method's params must match its type.) */
  request<Result = unknown, M extends string = string>(method: M extends keyof AgnetaRequests ? never : M, params?: unknown, options?: RequestOptions): Promise<Result>;
  request(method: string, params?: unknown, options: RequestOptions = {}): Promise<unknown> {
    if (this.#closedError) return Promise.reject(this.#closedError);
    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const timeout = options.timeout ?? this.requestTimeout;
      const timer = timeout > 0 && Number.isFinite(timeout)
        ? setTimeout(() => { this.#pending.delete(id); cleanup(); reject(new TimeoutError(method, timeout)); }, timeout)
        : undefined;
      const abort = () => { this.#pending.delete(id); cleanup(); reject(new AbortedError(method, { cause: options.signal?.reason })); };
      const cleanup = () => {
        if (timer) clearTimeout(timer);
        options.signal?.removeEventListener('abort', abort);
      };
      if (options.signal?.aborted) return abort();
      options.signal?.addEventListener('abort', abort, { once: true });
      this.#pending.set(id, { method, resolve, reject, cleanup });
      const message: JsonRpcRequest = { jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) };
      try {
        this.#send(message, options.signal);
      } catch (error) {
        this.#pending.delete(id);
        cleanup();
        reject(error);
      }
    });
  }

  /** Sends a notification. The only one Agneta takes from apps is `session/cancel`. */
  notify<M extends keyof AppNotifications>(method: M, params: AppNotifications[M]): void;
  notify(method: string, params?: unknown): void;
  notify(method: string, params?: unknown): void {
    if (this.#closedError) throw this.#closedError;
    this.#send({ jsonrpc: '2.0', method, ...(params === undefined ? {} : { params }) });
  }

  /** Answers Agneta's requests of `method` (one handler per method). Unhandled requests get -32601. */
  handle<M extends keyof AgnetaClientRequests>(method: M, handler: RequestHandler<AgnetaClientRequests[M]['params'], AgnetaClientRequests[M]['result']>): () => void;
  handle(method: string, handler: RequestHandler): () => void;
  handle(method: string, handler: RequestHandler): () => void {
    this.#handlers.set(method, handler);
    return () => { if (this.#handlers.get(method) === handler) this.#handlers.delete(method); };
  }

  /** Listens for one notification method, typed. */
  onNotification<M extends keyof AgnetaNotifications>(method: M, listener: (params: AgnetaNotifications[M]) => void): () => void;
  onNotification(method: string, listener: (params: unknown) => void): () => void;
  onNotification(method: string, listener: (params: any) => void): () => void {
    return this.on('notification', (received, params) => { if (received === method) listener(params); });
  }

  /** Sends any message as it is (a response to a request you answer yourself, say). */
  sendRaw(message: JsonRpcMessage): void {
    if (this.#closedError) throw this.#closedError;
    this.#send(message);
  }

  /** Closes the connection. Pending requests reject with `ConnectionClosedError`. */
  close(code = 1000, reason?: string): void {
    try { this.#socket.close(code, reason); } catch {}
    this.#end(new ConnectionClosedError(code, reason ?? 'closed by the app'));
  }

  #send(message: JsonRpcMessage, signal?: AbortSignal): void {
    if (this.#closedError || this.#socket.readyState !== OPEN) throw this.#closedError ?? new ConnectionClosedError(undefined, 'not open');
    const item = { message, text: JSON.stringify(message), signal };
    this.#outgoing.push(item);
    // A message observer may synchronously send cancel or another frame. It belongs after this frame.
    if (this.#writing) return;
    this.#writing = true;
    let failed = false, failure: unknown;
    try {
      for (let next = this.#outgoing.shift(); next; next = this.#outgoing.shift()) {
        try {
          if (this.#closedError || this.#socket.readyState !== OPEN) throw this.#closedError ?? new ConnectionClosedError(undefined, 'not open');
          this.emit('message', redacted(JSON.parse(next.text) as JsonRpcMessage), 'out');
          if (this.#closedError || this.#socket.readyState !== OPEN) throw this.#closedError ?? new ConnectionClosedError(undefined, 'not open');
          if (next.signal?.aborted) throw new AbortedError('method' in next.message ? next.message.method : 'send', { cause: next.signal.reason });
          this.#socket.send(next.text);
        } catch (error) {
          const request = next.message;
          const id = 'method' in request && 'id' in request ? request.id : undefined;
          const pending = id !== undefined && id !== null ? this.#pending.get(id) : undefined;
          if (pending && id !== undefined && id !== null) {
            this.#pending.delete(id);
            pending.cleanup(); pending.reject(error);
          }
          if (next === item) { failed = true; failure = error; }
          else if (!pending && !this.#closedError && !next.signal?.aborted) this.close(1011, 'could not send a queued message');
        }
      }
    } finally { this.#writing = false; }
    if (failed) throw failure;
  }

  #receive(data: unknown): void {
    if (this.#closedError) return;
    let text: string;
    if (typeof data === 'string') text = data;
    else if (data instanceof ArrayBuffer) text = new TextDecoder().decode(data);
    else if (ArrayBuffer.isView(data)) text = new TextDecoder().decode(data);
    else return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return; // Agneta sends JSON only; anything else isn't a message.
    }
    for (const message of Array.isArray(parsed) ? parsed : [parsed]) this.#dispatch(message);
  }

  #dispatch(message: unknown): void {
    if (this.#closedError) return;
    if (!message || typeof message !== 'object' || (message as { jsonrpc?: unknown }).jsonrpc !== '2.0') return;
    const value = message as JsonRpcMessage & { id?: JsonRpcId | null; method?: unknown };
    this.emit('message', redacted(value), 'in');
    if (this.#closedError) return;
    if (typeof value.method === 'string') {
      if (value.id === undefined || value.id === null) {
        this.emit('notification', value.method, (value as JsonRpcNotification).params);
      } else {
        void this.#answer(value as JsonRpcRequest);
      }
      return;
    }
    if (value.id === undefined || value.id === null) return;
    const pending = this.#pending.get(value.id);
    if (!pending) return;
    this.#pending.delete(value.id);
    pending.cleanup();
    const hasResult = 'result' in value;
    const hasError = 'error' in value;
    if (hasResult === hasError || (hasError && (!value.error || typeof value.error !== 'object'
      || !Number.isInteger(value.error.code) || typeof value.error.message !== 'string'))) {
      pending.reject(new ProtocolError('Agneta returned an invalid JSON-RPC response.', value));
    } else if (hasError && 'error' in value) {
      pending.reject(fromRpcError(value.error, pending.method));
    } else {
      pending.resolve((value as { result?: unknown }).result);
    }
  }

  async #answer(request: JsonRpcRequest): Promise<void> {
    const handler = this.#handlers.get(request.method);
    let response: JsonRpcResponse;
    if (!handler) {
      response = { jsonrpc: '2.0', id: request.id, error: { code: -32601, message: `${request.method} isn't handled by this app` } };
    } else {
      try {
        const result = await handler(request.params, request);
        response = { jsonrpc: '2.0', id: request.id, result: result ?? null };
      } catch (error) {
        const rawCode = (error as { code?: unknown })?.code;
        const code = typeof rawCode === 'number' && Number.isSafeInteger(rawCode) ? rawCode : -32603;
        const text = error instanceof Error ? error.message : String(error);
        response = { jsonrpc: '2.0', id: request.id, error: { code, message: text } };
      }
    }
    if (this.isOpen) {
      try { this.#send(response); } catch {
        if (this.isOpen) {
          try { this.#send({ jsonrpc: '2.0', id: request.id, error: { code: -32603, message: 'The app handler returned a value that is not JSON.' } }); } catch {}
        }
      }
    }
  }

  #end(error: ConnectionClosedError): void {
    if (this.#closedError) return;
    this.#closedError = error;
    this.#outgoing.length = 0;
    for (const pending of this.#pending.values()) {
      pending.cleanup();
      pending.reject(error);
    }
    this.#pending.clear();
    this.#markClosed(error);
    this.emit('close', error);
  }
}

/**
 * What answers at a WebSocket address, by an HTTP request to it: refused (or no such address) means nothing listens;
 * `EPERM` or `EACCES` means this app may not connect at all (a sandboxed app without
 * `com.apple.security.network.client` gets that from loopback, measured); any answer, or none within a second, means
 * something listens. `fetch` may be replaced (tests).
 */
export async function probeAgneta(url: string, fetchFunction: typeof fetch = fetch): Promise<PortProbe> {
  const target = new URL(url);
  target.protocol = target.protocol === 'wss:' ? 'https:' : 'http:';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1000);
  try {
    await fetchFunction(target, { signal: controller.signal, redirect: 'manual' });
    return 'listening';
  } catch (error) {
    if (controller.signal.aborted) return 'listening';
    const cause = (error as { cause?: { code?: string } })?.cause;
    const code = cause?.code ?? (error as { code?: string })?.code;
    if (code === 'EPERM' || code === 'EACCES') return 'blocked';
    // Refused, or no such address: nothing listens. Anything else (the socket closed on us, say) means something does.
    return code === 'ECONNREFUSED' || code === 'EADDRNOTAVAIL' || code === 'ENOTFOUND' ? 'notListening' : 'listening';
  } finally {
    clearTimeout(timer);
  }
}

/**
 * A message as the `message` tap shows it: the pairing token (in `initialize`'s `_meta.agneta.token` and the pairing
 * result's `token`) replaced, so logging every frame never logs a credential. The wire is unchanged.
 */
function redacted<T extends object>(message: T): T {
  const value = message as { params?: { _meta?: { agneta?: { token?: unknown } } }; result?: { token?: unknown } };
  const inParams = typeof value.params?._meta?.agneta?.token === 'string';
  const inResult = typeof value.result === 'object' && value.result !== null && typeof value.result.token === 'string';
  const copy = structuredClone(message) as typeof value;
  if (inParams) copy.params!._meta!.agneta!.token = '[redacted]';
  if (inResult) copy.result!.token = '[redacted]';
  return copy as T;
}
