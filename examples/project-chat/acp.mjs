// ACP travels over a Node WebSocket in Electron's main process. Browser
// WebSockets send an Origin header, which Agneta deliberately refuses.
export class AcpConnection {
  #socket;
  #pending = new Map();
  #nextId = 1;
  #ended = false;

  constructor(port, { notification, disconnected }) {
    this.#socket = new WebSocket(`ws://127.0.0.1:${port}/acp`);
    const socket = this.#socket;

    this.ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`Agneta did not answer on port ${port}.`));
        this.close();
      }, 5000);
      socket.addEventListener('open', () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      const unavailable = () => {
        clearTimeout(timer);
        const error = new Error(`Could not connect on port ${port}. Open Agneta and try again.`);
        error.notRunning = true; // nothing listens: Agneta isn't running
        reject(error);
      };
      socket.addEventListener('error', unavailable, { once: true });
      socket.addEventListener('close', unavailable, { once: true });
    });

    socket.addEventListener('message', ({ data }) => {
      if (this.#ended || socket.readyState !== WebSocket.OPEN) return;
      let message;
      try {
        message = JSON.parse(data);
      } catch {
        this.close();
        return;
      }
      if (message?.jsonrpc !== '2.0') return;
      if (typeof message.method === 'string') {
        if (!Object.hasOwn(message, 'id')) {
          notification(message.method, message.params);
        } else if (message.method === 'session/request_permission') {
          // This example grants the two app tools through policy. Decline any
          // additional permission request.
          this.#send({ id: message.id, result: { outcome: { outcome: 'cancelled' } } });
        } else {
          this.#send({ id: message.id, error: { code: -32601, message: 'Method not supported by Project Chat' } });
        }
        return;
      }

      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(Object.assign(new Error(message.error.message), {
          code: message.error.code,
          data: message.error.data
        }));
      } else {
        pending.resolve(message.result);
      }
    });

    socket.addEventListener('close', () => {
      this.#end(new Error('Connection to Agneta closed.'));
      disconnected();
    }, { once: true });
  }

  #send(fields) {
    if (this.#ended || this.#socket.readyState !== WebSocket.OPEN) {
      throw new Error('Connection to Agneta closed.');
    }
    this.#socket.send(JSON.stringify({ jsonrpc: '2.0', ...fields }));
  }

  request(method, params, timeout = 15_000) {
    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`Agneta timed out during ${method}.`));
        this.close();
      }, timeout);
      this.#pending.set(id, { resolve, reject, timer });
      try {
        this.#send({ id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.#pending.delete(id);
        reject(error);
      }
    });
  }

  notify(method, params) {
    this.#send({ method, params });
  }

  #end(error) {
    this.#ended = true;
    for (const { reject, timer } of this.#pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.#pending.clear();
  }

  close() {
    this.#end(new Error('Disconnected from Agneta.'));
    this.#socket.close();
  }
}
