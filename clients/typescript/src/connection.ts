// JSON-RPC 2.0 over one WebSocket, one message per text frame: the raw layer. Every Agneta method is typed; any other
// method can still be sent (Agneta answers what it doesn't offer with -32601). It tells "nothing is listening" from
// "something answered but refused the upgrade", and a timeout rejects one call, never the connection.
import { Emitter } from './emitter.js';
import {
  AbortedError, ConnectionClosedError, ConnectionRefusedError, fromRpcError, NotRunningError, TimeoutError,
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
  /** Whether anything listens at the URL's host and port, to tell "not running" from "refused". */
  probe?: (url: string) => Promise<boolean>;
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
   * answered but refused the upgrade, `TimeoutError` when the upgrade takes too long.
   */
  static open(options: OpenOptions): Promise<Connection> {
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
        const probe = options.probe ?? probeWithFetch;
        probe(options.url).catch(() => false).then((listening) => settle(() => reject(listening
          ? new ConnectionRefusedError(options.url)
          : new NotRunningError(options.url, options.openURL ?? null))));
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
        this.#send(message);
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

  #send(message: JsonRpcMessage): void {
    if (this.#socket.readyState !== OPEN) throw this.#closedError ?? new ConnectionClosedError(undefined, 'not open');
    const text = JSON.stringify(message);
    this.emit('message', message, 'out');
    this.#socket.send(text);
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
    if (!message || typeof message !== 'object' || (message as { jsonrpc?: unknown }).jsonrpc !== '2.0') return;
    const value = message as JsonRpcMessage & { id?: JsonRpcId | null; method?: unknown };
    this.emit('message', value, 'in');
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
    if ('error' in value && value.error) {
      const error = value.error;
      pending.reject(fromRpcError({ code: Number(error.code), message: String(error.message ?? ''), data: error.data }, pending.method));
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
        const code = typeof (error as { code?: unknown })?.code === 'number' ? (error as { code: number }).code : -32603;
        const text = error instanceof Error ? error.message : String(error);
        response = { jsonrpc: '2.0', id: request.id, error: { code, message: text } };
      }
    }
    if (this.isOpen) {
      try { this.#send(response); } catch {}
    }
  }

  #end(error: ConnectionClosedError): void {
    if (this.#closedError) return;
    this.#closedError = error;
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
 * Whether anything listens on the URL's host and port: an HTTP request that's refused means nothing does. A request
 * that gets any answer, or none within a second, means something listens and refused the WebSocket upgrade.
 */
async function probeWithFetch(url: string): Promise<boolean> {
  const target = new URL(url);
  target.protocol = target.protocol === 'wss:' ? 'https:' : 'http:';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1000);
  try {
    await fetch(target, { signal: controller.signal, redirect: 'manual' });
    return true;
  } catch (error) {
    if (controller.signal.aborted) return true;
    const code = (error as { cause?: { code?: string } })?.cause?.code;
    // Refused, or no such address: nothing listens. Anything else (the socket closed on us, say) means something does.
    return !(code === 'ECONNREFUSED' || code === 'EADDRNOTAVAIL' || code === 'ENOTFOUND');
  } finally {
    clearTimeout(timer);
  }
}
