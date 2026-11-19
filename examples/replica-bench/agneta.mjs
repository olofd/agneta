// The bench's side of Agneta: what a demanding app asks for, on top of @agneta/client (clients/typescript), which
// does the protocol's work (connecting, pairing, the kept token, access changes, sessions, errors). Shared by the
// headless runner and the Electron window, so both measure exactly the same client.
//
// The bench asks for workspace tools in its own data folder and its toolchain, and every provider, engine and mode, so
// the approval window's picker starts at developer access. The user decides: the grant's mode (access.scope.sandbox)
// is the ceiling every session is held to, and the bench shows it rather than assuming it.
import { EventEmitter } from 'node:events';
import { realpath } from 'node:fs/promises';
import {
  AgnetaClient, builds, configSetting, findConfigOption, installPageURL, isAgnetaError, memoryTokenStore, NeedsPairingError,
  providerEngines
} from '@agneta/client';
import { toolchainFolders } from './toolchain.mjs';

/** The release and the development build: their ports, and the URLs that open them. */
export const agnetas = [
  { id: 'release', name: builds.release.name, port: builds.release.port, url: builds.release.openURL },
  { id: 'dev', name: builds.dev.name, port: builds.dev.port, url: builds.dev.openURL }
];

/** Keeps nothing: the token lasts as long as the process runs. Electron passes a Keychain-backed store (main.mjs). */
export const memoryTokens = memoryTokenStore;

/**
 * What the headless runner says when no Agneta answers, from each build's `presence()` (`found`: the release first,
 * then Agneta Dev): to open one that's installed, to drag one off its disk image, else how to get the release (the
 * install page for this Mac and Homebrew). A script has no one to ask, so it never opens anything itself
 * (docs/APP_PROTOCOL.md, Getting Agneta).
 */
export function whatIsMissing(found, architecture = null) {
  const first = (state) => found.find(({ presence }) => presence.state === state);
  const installed = first('notRunning');
  if (installed) return `${installed.agneta.agnetaName} isn't running. Open it (it lives in the menu bar), then run this again.`;
  const onImage = first('onDiskImage');
  if (onImage) return `${onImage.agneta.agnetaName} is on its disk image: drag it into Applications, open it from there, and run this again.`;
  const blocked = first('blocked');
  if (blocked) return blocked.presence.reason;
  const missing = first('notInstalled');
  if (missing) {
    const { agnetaName, installURL, homebrew } = missing.agneta;
    return [`${agnetaName} isn't installed. Get it from ${installPageURL(installURL ?? '', architecture) || 'its website'}`,
      homebrew ? `, or install it with: ${homebrew}` : '', '. Then open it and run this again.'].join('');
  }
  return 'Neither Agneta (47321) nor Agneta Dev (47331) is running. Open one, then run this again, or give --port.';
}

/** The fields Agneta says it can't enforce (`UnenforceableError.fields`), or an empty list. */
export function unenforceable(error) {
  return error?.kind === 'unenforceable' ? error.fields : [];
}

/** A refused session, as the report keeps it: Agneta's code, the fields it refused and its reason. Null for other errors. */
export function refusal(error) {
  const fields = unenforceable(error);
  if (error?.code !== -32602 && !fields.length) return null;
  return { code: error.code, fields, reason: error.reason ?? error.message };
}

/** What to show for an error, by the client's typed `kind`. */
export function describeError(error) {
  if (!isAgnetaError(error)) return error?.message ?? String(error);
  switch (error.kind) {
    case 'needsSignIn': return 'Sign in to this account in Agneta, then try again.';
    case 'needsPairing': return 'Agneta no longer accepts this app\'s access. Connect to pair again.';
    case 'notAllowed': return 'Pairing was declined or expired. Connect to try again.';
    case 'paused': return 'This account is paused. Resume it in Agneta, then try again.';
    case 'rateLimited': return `The provider rate-limited this account.${error.resetsAt ? ` It resets at ${error.resetsAt.toISOString()}.` : ''}`;
    case 'unenforceable': return `Agneta refused ${error.fields.join(', ')}: ${error.reason ?? error.message}`;
  }
  if (error.code === -32000) return 'Sign in to this account in Agneta, then try again.';
  return error.message;
}

/**
 * The engine's model and reasoning-effort settings, from the session's `configOptions` (ACP), found by their standard
 * category (`model`, `thought_level`), the model also by the id `model`.
 */
export function settings(configOptions) {
  const model = configSetting(findConfigOption(configOptions, 'model'));
  const effort = configSetting(findConfigOption(configOptions, 'thought_level'));
  const choices = (setting) => (setting?.choices ?? []).map(({ value, name }) => ({ value, name }));
  return {
    ids: { model: model?.id, effort: effort?.id },
    view: { models: choices(model), model: model?.current ?? '', efforts: choices(effort), effort: effort?.current ?? '' }
  };
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
  return (access?.providers ?? []).map((provider) => ({
    id: provider.id,
    label: provider.label,
    paused: provider.paused === true,
    needsSignIn: provider.needsSignIn === true,
    engines: providerEngines(access, provider).map((engine) => ({
      id: engine.id, name: engine.name, state: engine.state, reason: engine.reason,
      levels: engine.sandboxLevels, uncontained: engine.uncontained
    }))
  }));
}

/**
 * One connection to Agneta, with what the bench needs on top of the client: its scope, a grant that still covers its
 * folder, and the providers as its pickers show them. Emits `code` (a pairing code to show), `access` (what the app may
 * use, on connect and on change), `notification` (method, params), `permission` (a request no session answered) and
 * `disconnected` (a connection that was up went). `client` is the @agneta/client underneath.
 */
export class Agneta extends EventEmitter {
  /** Set once connected; a close, or a connect that fails, never reports a disconnection. */
  #up = false;

  /**
   * @param home the bench's data folder (workspace.mjs), the one folder the pairing scope asks for.
   * @param tokens where Always Allow's token is kept (`load`, `save`, `clear`).
   * @param environment how to find and open Agneta on this Mac (`electronEnvironment`, `nodeEnvironment`), for `guide`.
   * @param client more of the client's options (tests: the open URL, install page and bundle ID for a port of their own).
   */
  constructor(port, { home, tokens = memoryTokens(), name = 'Agneta', environment = undefined, client: more = {} }) {
    super();
    this.port = port;
    this.home = home;
    this.name = name;
    this.client = new AgnetaClient({
      name: 'Replica Bench',
      port,
      tokens,
      scope: pairingScope(home),
      clientInfo: { name: 'agneta-replica-bench', title: 'Replica Bench', version: '0.1.0' },
      // The bench's sessions use approval never-ask: the policy is the permission. A request that still arrives is
      // declined, so the bench measures the policy and nothing a person clicked, and counted (each run counts its own).
      permissions: (request) => { this.emit('permission', request); return 'cancel'; },
      timeouts: { session: 60_000 },
      ...(environment ? { environment } : {}),
      ...more
    });
    this.client.on('pairingCode', (code) => this.emit('code', code));
    this.client.on('accessChanged', (access) => this.emit('access', access));
    this.client.on('notification', (method, params) => this.emit('notification', method, params));
    this.client.on('disconnected', () => {
      if (!this.#up) return;
      this.#up = false;
      this.emit('disconnected');
    });
  }

  /** What the app may use now (the client's access report), or null before connecting. */
  get access() {
    return this.client.access;
  }

  /** The grant's sandbox mode, the most any session may get: `contained` or `developer` (null before connecting). */
  get grant() {
    return this.access?.scope?.sandbox ?? null;
  }

  get connected() {
    return this.#up && this.client.state === 'connected' && Boolean(this.access);
  }

  /**
   * Connects with the kept token when there is one, else pairs (Agneta's approval window). A kept grant that no
   * longer covers the bench's folder, or that Agneta forgot, is replaced by pairing again. `quiet` never pairs: it
   * resolves to null when pairing would be needed. `pair` pairs even with a usable token (to widen the grant). `guide`,
   * `onProgress` and `signal` are the client's: getting and opening Agneta when it isn't running (docs/APP_PROTOCOL.md).
   */
  async connect({ quiet = false, pair = false, guide, onProgress, signal } = {}) {
    this.#up = false;
    try {
      const guided = { ...(guide ? { guide } : {}), ...(onProgress ? { onProgress } : {}), ...(signal ? { signal } : {}) };
      let access = await this.client.connect({ pair: pair ? 'always' : quiet ? 'never' : 'if-needed', ...guided }).catch((error) => {
        if (quiet && error instanceof NeedsPairingError) return null;
        throw error;
      });
      if (access && !await this.#covers(access.scope)) {
        // A grant for another folder (the bench's data moved): forget it and ask for the folder now.
        await this.client.forgetToken();
        access = quiet ? null : await this.client.connect({ pair: 'always' });
      }
      if (!access) {
        this.close();
        return null;
      }
      if (typeof access.workspace !== 'string') throw new Error('Use an Agneta build that tells apps what they may use.');
      this.#up = true;
      this.emit('access', access);
      return access;
    } catch (error) {
      this.close();
      throw error;
    }
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

  /**
   * Providers the app may use, each with the engines its tasks may run on (default first), their state here, the
   * sandbox modes each can provide on that provider (`levels`, null where Agneta doesn't say) and whether Agneta can
   * confine its own tools at all (`uncontained`).
   */
  providers() {
    return providersOf(this.access);
  }

  /** A session (`session/new`), as the client opens it: waiting while Agneta downloads the engine, up to ten minutes. */
  newSession(options) {
    return this.client.newSession(options);
  }

  close() {
    this.#up = false;
    this.client.close();
  }
}
