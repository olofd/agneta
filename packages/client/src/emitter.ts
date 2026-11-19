// A small typed event emitter, so the core needs nothing from Node. `on` returns a function that removes the listener.

export type Listener<Args extends unknown[]> = (...args: Args) => void;

export class Emitter<Events extends { [name: string]: unknown[] }> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  #listeners = new Map<keyof Events, Set<(...args: any[]) => void>>();

  /** Calls `listener` for every `name` event until the returned function is called. */
  on<Name extends keyof Events>(name: Name, listener: Listener<Events[Name]>): () => void {
    let set = this.#listeners.get(name);
    if (!set) this.#listeners.set(name, set = new Set());
    set.add(listener);
    return () => this.off(name, listener);
  }

  /** Calls `listener` for the next `name` event only. */
  once<Name extends keyof Events>(name: Name, listener: Listener<Events[Name]>): () => void {
    const off = this.on(name, ((...args: Events[Name]) => {
      off();
      listener(...args);
    }) as Listener<Events[Name]>);
    return off;
  }

  off<Name extends keyof Events>(name: Name, listener: Listener<Events[Name]>): void {
    this.#listeners.get(name)?.delete(listener);
  }

  /** Resolves with the next `name` event's arguments (the first of them for one-argument events), or rejects on `signal`. */
  next<Name extends keyof Events>(name: Name, options: { signal?: AbortSignal; filter?: (...args: Events[Name]) => boolean } = {}): Promise<Events[Name]> {
    return new Promise((resolve, reject) => {
      const { signal, filter } = options;
      if (signal?.aborted) return reject(signal.reason);
      const off = this.on(name, ((...args: Events[Name]) => {
        if (filter && !filter(...args)) return;
        off();
        signal?.removeEventListener('abort', abort);
        resolve(args);
      }) as Listener<Events[Name]>);
      const abort = () => { off(); reject(signal?.reason); };
      signal?.addEventListener('abort', abort, { once: true });
    });
  }

  protected emit<Name extends keyof Events>(name: Name, ...args: Events[Name]): void {
    const set = this.#listeners.get(name);
    if (!set) return;
    for (const listener of [...set]) {
      try {
        listener(...args);
      } catch (error) {
        // A listener's mistake mustn't break the connection's message loop: report it as an unhandled error would be.
        queueMicrotask(() => { throw error; });
      }
    }
  }

  /** Whether anything listens for `name`. */
  protected listening(name: keyof Events): boolean {
    return (this.#listeners.get(name)?.size ?? 0) > 0;
  }

  protected removeAllListeners(): void {
    this.#listeners.clear();
  }
}
