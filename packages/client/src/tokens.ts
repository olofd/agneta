// Where the token from Always Allow is kept between launches. Keep one store per Agneta build (release, Dev, or an
// isolated instance): each has its own grants. File and Keychain stores are in `@agneta/client/node`.

/** Keeps the app's pairing token. Methods may be sync or async. `load` returns null when there's none. */
export interface TokenStore {
  load(): Promise<string | null> | string | null;
  save(token: string): Promise<void> | void;
  clear(): Promise<void> | void;
}

/** Keeps the token in memory only: it lasts as long as the process. */
export function memoryTokenStore(initial: string | null = null): TokenStore {
  let token = initial;
  return {
    load: () => token,
    save: (value) => { token = value; },
    clear: () => { token = null; }
  };
}
