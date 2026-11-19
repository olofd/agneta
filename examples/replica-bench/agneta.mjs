// The bench's side of Agneta's app protocol (docs/APP_PROTOCOL.md): connect, pair or initialize with a kept token,
// read what the app may use, and open sessions. Adapted from Project Chat's chat.mjs, which proved it; shared by the
// headless runner and the Electron window, so both measure exactly the same client.
//
// The bench asks for what a demanding app needs: workspace tools in its own data folder and its toolchain, and the
// developer sandbox, so the approval window's picker starts there. The user decides: the grant's mode
// (access.scope.sandbox) is the ceiling every session is held to, and the bench shows it rather than assuming it.
import { toolchainFolders } from './toolchain.mjs';
import { EventEmitter } from 'node:events';
import { createConnection } from 'node:net';
import { realpath } from 'node:fs/promises';
import { AcpConnection } from './acp.mjs';

export const agnetas = [
  { id: 'release', name: 'Agneta', port: 47321, url: 'agneta://open' },
  { id: 'dev', name: 'Agneta Dev', port: 47331, url: 'agneta-dev://open' }
];

/** Keeps nothing: the token lasts as long as the process runs. Electron passes a Keychain-backed store (main.mjs). */
export function memoryTokens() {
  let token = null;
  return {
    load: async () => token,
    save: async (value) => { token = value; },
    clear: async () => { token = null; }
  };
}

/** The fields Agneta says it can't enforce (`data.agneta.unenforceable`), or an empty list. */
export function unenforceable(error) {
  const fields = error?.data?.agneta?.unenforceable;
  return Array.isArray(fields) ? fields.filter((field) => typeof field === 'string') : [];
}

export function describeError(error) {
  const details = error?.data?.agneta;
  if (details?.needsSignIn || error?.code === -32000) return 'Sign in to this account in Agneta, then try again.';
  if (error?.code === -32001) return 'Agneta no longer accepts this app\'s access. Connect to pair again.';
  if (error?.code === -32002) return 'Pairing was declined or expired. Connect to try again.';
  if (error?.code === -32013) return 'This account is paused. Resume it in Agneta, then try again.';
  if (details?.rateLimited) return `The provider rate-limited this account.${details.rateLimited.resetsAt ? ` It resets at ${details.rateLimited.resetsAt}.` : ''}`;
  const fields = unenforceable(error);
  if (fields.length) return `Agneta refused ${fields.join(', ')}: ${details?.reason ?? error.message}`;
  return error?.message ?? String(error);
}

/**
 * The engine's model and reasoning-effort settings, from the session's `configOptions` (ACP), found by their standard
 * category (`model`, `thought_level`), the model also by the id `model`. As in Project Chat.
 */
export function settings(configOptions) {
  const list = Array.isArray(configOptions) ? configOptions : [];
  const model = list.find((option) => option.category === 'model') ?? list.find((option) => option.id === 'model');
  const effort = list.find((option) => option.category === 'thought_level');
  const choices = (option) => {
    const entries = (option?.options ?? [])
      .flatMap((entry) => Array.isArray(entry.options) ? entry.options : [entry])
      .filter((entry) => typeof entry?.value === 'string')
      .map((entry) => ({ value: entry.value, name: entry.name ?? entry.value }));
    // The current one may not be among them (Goose reports its configured model without listing it): shown first.
    const current = option?.currentValue;
    return typeof current === 'string' && current && !entries.some((entry) => entry.value === current) ? [{ value: current, name: current }, ...entries] : entries;
  };
  return {
    ids: { model: model?.id, effort: effort?.id },
    view: { models: choices(model), model: model?.currentValue ?? '', efforts: choices(effort), effort: effort?.currentValue ?? '' }
  };
}

/** Waits until something listens on the port (Agneta, just opened), up to `seconds`. */
export async function listening(port, seconds) {
  for (const started = Date.now(); Date.now() - started < seconds * 1000; ) {
    const up = await new Promise((resolve) => {
      const probe = createConnection({ host: '127.0.0.1', port }, () => { probe.destroy(); resolve(true); });
      probe.on('error', () => resolve(false));
    });
    if (up) return true;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return false;
}

/**
 * The pairing scope: workspace tools in the bench folder and its toolchain, and the big grant a comparison bench needs:
 * every provider and engine, and any mode (the user's picker starts at developer access).
 */
export function pairingScope(home) {
  return { tools: 'workspace', folders: [home, ...toolchainFolders()], providers: 'all', engines: 'all', sandbox: 'any' };
}

/** An access report's providers and engines, with each engine's sandbox levels and whether it's uncontained. */
export function providersOf(access) {
  const engines = Object.fromEntries((access?.engines ?? []).map((engine) => [engine.id, engine]));
  return (access?.providers ?? []).map((provider) => ({
    id: provider.id,
    label: provider.label,
    paused: provider.paused === true,
    needsSignIn: provider.needsSignIn === true,
    engines: (provider.engines ?? []).map((id) => ({
      id, name: engines[id]?.name ?? id, state: engines[id]?.state ?? 'unknown', reason: engines[id]?.reason,
      levels: Array.isArray(provider.sandboxLevels?.[id]) ? provider.sandboxLevels[id] : null,
      uncontained: Array.isArray(provider.uncontained) && provider.uncontained.includes(id)
    }))
  }));
}

/**
 * One connection to Agneta. Emits `notification` (method, params), `permission` (params of a request that reached
 * the app), `code` (a pairing code to show), `access` (what the app may use, on connect and on change) and
 * `disconnected`.
 */
export class Agneta extends EventEmitter {
  #connection;
  #tokens;

  /**
   * @param home the bench's data folder (workspace.mjs), the one folder the pairing scope asks for.
   * @param tokens where Always Allow's token is kept (`load`, `save`, `clear`).
   */
  constructor(port, { home, tokens = memoryTokens(), name = 'Agneta' }) {
    super();
    this.port = port;
    this.home = home;
    this.name = name;
    this.#tokens = tokens;
    this.access = null;
  }

  /** The grant's sandbox mode, the most any session may get: `contained` or `developer` (null before connecting). */
  get grant() {
    return this.access?.scope?.sandbox ?? null;
  }

  get connected() {
    return Boolean(this.#connection && this.access);
  }

  /**
   * Connects with the kept token when there is one, else pairs (Agneta's approval window). A kept grant that no
   * longer covers the bench's folder, or that Agneta forgot, is replaced by pairing again. `quiet` never pairs: it
   * resolves to null when pairing would be needed. `pair` pairs even with a usable token (to widen the grant).
   */
  async connect({ quiet = false, pair = false } = {}) {
    const connection = new AcpConnection(this.port, {
      notification: (method, params) => {
        if (this.#connection !== connection) return;
        if (method === 'agneta/pairingCode') this.emit('code', params?.code ?? '');
        if (method === 'agneta/accessChanged' && params?.access) this.#setAccess(params.access);
        this.emit('notification', method, params);
      },
      permission: (params) => this.emit('permission', params),
      disconnected: () => {
        if (this.#connection !== connection) return;
        this.#connection = undefined;
        this.access = null;
        this.emit('disconnected');
      }
    });
    this.#connection = connection;
    try {
      await connection.ready;
      const kept = pair ? null : await this.#tokens.load();
      let initialized = kept ? await this.#initialize(connection, kept).catch((error) => {
        if (error.code === -32001) return null;
        throw error;
      }) : null;
      if (initialized && !await this.#covers(initialized?._meta?.agneta?.access?.scope)) initialized = null;
      if (!initialized) {
        if (kept) await this.#tokens.clear();
        if (quiet) {
          this.close();
          return null;
        }
        const token = await this.#pair(connection);
        initialized = await this.#initialize(connection, token);
      }
      const access = initialized?._meta?.agneta?.access;
      if (initialized?.protocolVersion !== 1 || typeof access?.workspace !== 'string') {
        throw new Error('Use an Agneta build that tells apps what they may use.');
      }
      this.#setAccess(access);
      return access;
    } catch (error) {
      if (this.#connection === connection) this.close();
      throw error;
    }
  }

  /** Pairs for workspace tools in the bench's folder and toolchain, asking for the developer sandbox; the user decides. */
  async #pair(connection) {
    const paired = await connection.request('agneta/pair', { name: 'Replica Bench', scope: pairingScope(this.home) }, 310_000);
    if (typeof paired?.token !== 'string') throw new Error('Agneta returned an incomplete pairing response.');
    if (paired.remembered) await this.#tokens.save(paired.token);
    return paired.token;
  }

  /** Whether a grant's scope still covers what the bench needs: workspace tools in its data folder and the toolchain. */
  async #covers(scope) {
    if (scope?.tools !== 'workspace' || !Array.isArray(scope.folders)) return false;
    const granted = await Promise.all(scope.folders.map((folder) => realpath(folder).catch(() => folder)));
    for (const wanted of [this.home, ...toolchainFolders()]) {
      const path = await realpath(wanted).catch(() => wanted);
      if (!granted.some((folder) => path === folder || path.startsWith(folder.endsWith('/') ? folder : `${folder}/`))) return false;
    }
    return true;
  }

  #initialize(connection, token) {
    return connection.request('initialize', {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: 'agneta-replica-bench', title: 'Replica Bench', version: '0.1.0' },
      _meta: { agneta: { token } }
    });
  }

  #setAccess(access) {
    this.access = access;
    this.emit('access', access);
  }

  /**
   * Providers the app may use, each with the engines its tasks may run on (default first), their state here, the
   * sandbox modes each can provide on that provider (`levels`, null where Agneta doesn't say) and whether Agneta can
   * confine its own tools at all (`uncontained`).
   */
  providers() {
    return providersOf(this.access);
  }

  request(method, params, timeout) {
    if (!this.#connection) return Promise.reject(new Error('Not connected to Agneta.'));
    return this.#connection.request(method, params, timeout);
  }

  notify(method, params) {
    this.#connection?.notify(method, params);
  }

  /** session/new, waiting while Agneta downloads the engine (-32015), up to ten minutes. */
  async newSession(request, { progress = () => {} } = {}) {
    for (const started = Date.now(); ; ) {
      try {
        return await this.request('session/new', request, 60_000);
      } catch (error) {
        const downloading = error.data?.agneta?.engineDownloading;
        if (error.code !== -32015 || Date.now() - started > 600_000) throw error;
        progress(downloading);
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }
  }

  close() {
    const connection = this.#connection;
    this.#connection = undefined;
    this.access = null;
    connection?.close();
  }
}
