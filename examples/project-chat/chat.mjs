import { EventEmitter } from 'node:events';
import { createConnection } from 'node:net';
import { AcpConnection } from './acp.mjs';
import { project, startProjectTools } from './project-tools.mjs';

const limits = { maxTurns: 12, maxSeconds: 90 };
const instructions = [
  'You are the assistant in Project Chat. Use read_project_brief for facts about the sample project.',
  'When asked to draft a note, read the brief and call propose_note with a short draft.',
  'The draft is only a proposal. The user reviews and saves it in the app.',
  'Use plain text and keep replies brief.'
].join(' ');

function describeError(error) {
  const details = error.data?.agneta;
  if (details?.needsSignIn || error.code === -32000) return 'Sign in to this account in Agneta, then try again.';
  if (error.code === -32002) return 'Pairing was declined or expired. Select Connect to try again.';
  if (error.code === -32013) return 'This account is paused. Resume it in Agneta, then try again.';
  if (details?.rateLimited) return 'The provider rate-limited this account. Try again later.';
  return error.message;
}

/** Agneta no longer accepts the token: access was removed, or it ended. Pair again. */
function needsPairing(error) {
  return error?.code === -32001;
}

/** Keeps nothing: the token lasts as long as the app runs. Electron passes a Keychain-backed store (main.mjs). */
export function memoryTokens() {
  let token = null;
  return {
    load: async () => token,
    save: async (value) => { token = value; },
    clear: async () => { token = null; }
  };
}

/**
 * The engine's model and reasoning-effort settings, from the session's `configOptions` (ACP): found by their standard
 * category (`model`, `thought_level`) rather than each engine's own ids, the model also by the id `model`. Choices
 * may come in groups; they're flattened. Either is absent when the engine doesn't offer it.
 */
export function settings(configOptions) {
  const list = Array.isArray(configOptions) ? configOptions : [];
  const model = list.find((option) => option.category === 'model') ?? list.find((option) => option.id === 'model');
  const effort = list.find((option) => option.category === 'thought_level');
  const choices = (option) => {
    const list = (option?.options ?? [])
      .flatMap((entry) => Array.isArray(entry.options) ? entry.options : [entry])
      .filter((entry) => typeof entry?.value === 'string')
      .map((entry) => ({ value: entry.value, name: entry.name ?? entry.value }));
    // The current one may not be among them (Goose reports its configured model without listing it): shown first.
    const current = option?.currentValue;
    return typeof current === 'string' && current && !list.some((entry) => entry.value === current) ? [{ value: current, name: current }, ...list] : list;
  };
  return {
    ids: { model: model?.id, effort: effort?.id },
    view: { models: choices(model), model: model?.currentValue ?? '', efforts: choices(effort), effort: effort?.currentValue ?? '' }
  };
}

/** No session, so no settings to show. */
const noSettings = { models: [], model: '', efforts: [], effort: '' };

/** Waits until something listens on the port (Agneta, just opened), up to `seconds`. */
async function listening(port, seconds) {
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

/** Bytes as people read them: "45 MB". */
function size(bytes) {
  return Number.isFinite(bytes) ? `${Math.round(bytes / 1e6)} MB` : '';
}

export class ProjectChat extends EventEmitter {
  #connection;
  #session;
  #tools;
  #workspace;
  #reply;
  /** Waiting for a provider to be connected in Agneta (`agneta/setup`); a disconnect lets the wait go. */
  #onCatalog = null;
  #access;
  #tokens;
  #openAgneta;
  /** The session being opened ahead of the first message, so the model and effort can be chosen before it. */
  #opening = null;
  /** Counts chats: a session that finishes opening after its chat was closed or switched is closed, not used. */
  #chat = 0;
  /** The engine's ids for the model and effort settings, and what the user picked, kept for the next chat. */
  #settingIds = {};
  #wanted = {};
  /** Connected with a kept token: when the connection drops, a quiet reconnect finds out whether access was removed. */
  #remembered = false;

  /**
   * @param tokens where the token from Always Allow is kept between launches (`load`, `save`, `clear`).
   * @param openAgneta when Agneta isn't running: asks the user whether to open it and, if they say yes, opens it;
   *   resolves to whether it did (main.mjs: a dialog, then `agneta://open` or `agneta-dev://open`). Without it, the
   *   app only says so.
   * @param name what the app calls this Agneta in what it shows: "Agneta" for a release, "Agneta Dev" for a development build.
   */
  constructor(port, { tokens = memoryTokens(), openAgneta = null, name = 'Agneta' } = {}) {
    super();
    this.port = port;
    this.name = name;
    this.#tokens = tokens;
    this.#openAgneta = openAgneta;
    this.view = {
      project,
      phase: 'disconnected',
      status: 'Connect to start chatting.',
      code: '',
      // What Agneta lets this app use (agneta/access), and the provider and engine the next chat runs on.
      providers: [],
      account: '',
      engine: '',
      // The engine's models and reasoning efforts, once the chat's session is open, and the current ones.
      models: [],
      model: '',
      efforts: [],
      effort: '',
      messages: [],
      draft: null,
      notes: [],
      usage: null
    };
  }

  #update(fields) {
    Object.assign(this.view, fields);
    this.emit('change', this.view);
  }

  /**
   * Connects to Agneta: with the token kept from an earlier Always Allow when there is one, else by pairing, which
   * opens Agneta's approval window. A token Agneta no longer accepts (access removed there) is forgotten. `quiet` (at
   * launch, and after the connection drops) never opens the approval window: without a usable token it stops and
   * says so.
   */
  async connect({ quiet = false } = {}) {
    if (this.view.phase !== 'disconnected') return;
    this.#update({
      phase: 'connecting', status: `Connecting to ${this.name}…`, code: '',
      messages: [], draft: null, usage: null
    });
    const connection = new AcpConnection(this.port, {
      notification: (method, params) => {
        if (this.#connection === connection) this.#notification(method, params);
      },
      disconnected: () => {
        if (this.#connection !== connection) return;
        // Let the pending handshake surface its more specific connection error.
        if (this.view.phase === 'connecting' || this.view.phase === 'pairing') return;
        const remembered = this.#remembered;
        this.disconnect('Connection closed. Connect to start a new chat.');
        // Agneta closes an app's connections when its access is removed: reconnecting with the token says whether
        // that's what happened (or Agneta quit).
        if (remembered) setTimeout(() => this.connect({ quiet: true }), 1000);
      }
    });
    this.#connection = connection;
    this.#remembered = false;

    try {
      await connection.ready;
      if (this.#connection !== connection) return;
      const kept = await this.#tokens.load();
      let initialized = kept ? await this.#initialize(connection, kept).catch((error) => {
        if (needsPairing(error)) return null;
        throw error;
      }) : null;
      if (this.#connection !== connection) return;
      if (initialized) {
        this.#remembered = true;
      } else {
        if (kept) await this.#tokens.clear();
        if (quiet) {
          this.disconnect(kept ? `Your access was removed in ${this.name}. Connect to ask again.` : 'Connect to start chatting.');
          return;
        }
        // With no AI connected in Agneta yet, ask it to help the user connect one, then pair (the user pressed
        // Connect, so the window is theirs to expect). An Agneta without agneta/catalog just pairs.
        const catalog = await connection.request('agneta/catalog', {}).catch(() => null);
        if (this.#connection !== connection) return;
        if (catalog && catalog.connected === false) {
          this.#update({ phase: 'pairing', status: `Connect your AI in ${this.name} to start chatting.` });
          const connected = this.#providerConnected();
          await connection.request('agneta/setup', { name: 'Project Chat' });
          await connected;
          if (this.#connection !== connection) return;
        }
        this.#update({ phase: 'pairing', status: `Approve Project Chat in ${this.name}.` });
        // Ask for the app's own tools and no user folders.
        const paired = await connection.request('agneta/pair', {
          name: 'Project Chat', scope: { tools: 'app-only', folders: [] }
        }, 310_000);
        if (typeof paired?.token !== 'string') throw new Error('Agneta returned an incomplete pairing response.');
        // Always Allow: kept for the next launch (in the Keychain, through main.mjs). Allow Once ends with this
        // connection. The token never leaves the main process.
        if (paired.remembered) {
          await this.#tokens.save(paired.token);
          this.#remembered = true;
        }
        initialized = await this.#initialize(connection, paired.token);
      }
      if (this.#connection !== connection) return;
      const access = initialized?._meta?.agneta?.access;
      if (initialized?.protocolVersion !== 1 || typeof access?.workspace !== 'string') {
        throw new Error('Use an Agneta build that tells apps what they may use.');
      }
      this.#workspace = access.workspace;
      this.#setAccess(access);
      if (!this.view.account) throw new Error(`No active provider was granted. Connect one in ${this.name} and pair again.`);
      this.#update({ phase: 'ready', status: 'Ready', code: '' });
      this.#prepare();
    } catch (error) {
      if (this.#connection !== connection) return;
      this.disconnect(error.notRunning ? `${this.name} isn't running. Open it, then connect.` : describeError(error));
      // Agneta isn't running: offer to open it (at launch only to someone who has used it, a token kept), then connect.
      if (error.notRunning && this.#openAgneta && (!quiet || await this.#tokens.load())) await this.#offerToOpen(quiet);
    }
  }

  async #offerToOpen(quiet) {
    if (!await this.#openAgneta()) return;
    this.#update({ status: `Opening ${this.name}…` });
    if (!await listening(this.port, 20)) {
      this.#update({ status: `${this.name} didn't start. Open it, then connect.` });
      return;
    }
    await this.connect({ quiet });
  }

  #initialize(connection, token) {
    return connection.request('initialize', {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: 'agneta-project-chat', title: 'Project Chat', version: '0.1.0' },
      _meta: { agneta: { token } }
    });
  }

  /**
   * What this app may use: each provider with the engines its tasks may run on there (the default first). The
   * current choice stays while it's still allowed; otherwise the first active provider and its default engine.
   */
  #setAccess(access) {
    this.#access = access;
    const names = Object.fromEntries((access.engines ?? []).map((engine) => [engine.id, engine.name]));
    const providers = (access.providers ?? []).map((provider) => ({
      id: provider.id,
      label: provider.label,
      paused: provider.paused,
      engines: (provider.engines ?? []).map((id) => ({ id, name: names[id] ?? id }))
    }));
    let provider = providers.find((entry) => entry.id === this.view.account && !entry.paused)
      ?? providers.find((entry) => !entry.paused && entry.engines.length > 0);
    const engine = provider?.engines.some((entry) => entry.id === this.view.engine) ? this.view.engine : provider?.engines[0]?.id;
    this.#update({ providers, account: provider?.id ?? '', engine: engine ?? '' });
  }

  /** Picks the provider and engine for the next chat; the open one, on the old pair, closes. */
  async choose({ account, engine } = {}) {
    if (this.view.phase !== 'ready') return;
    const provider = this.view.providers.find((entry) => entry.id === account);
    if (!provider) return;
    const chosen = provider.engines.some((entry) => entry.id === engine) ? engine : provider.engines[0]?.id ?? '';
    if (provider.id === this.view.account && chosen === this.view.engine) return;
    this.#update({ account: provider.id, engine: chosen });
    await this.newChat();
  }

  /** Opens the chat's session ahead of its first message, in the background, so its settings can be shown. */
  #prepare() {
    if (this.#session || this.#opening || this.view.phase !== 'ready') return;
    const connection = this.#connection, chat = this.#chat;
    this.#opening = this.#openSession(connection)
      .catch((error) => {
        if (this.#connection === connection && this.#chat === chat) this.#update({ status: describeError(error) });
      })
      .finally(() => { if (this.#chat === chat) this.#opening = null; });
  }

  /**
   * Sets the model or reasoning effort (`session/set_config_option`) between turns; the engine answers with its
   * options as they are now (another model may offer other efforts). Kept for the next chat.
   */
  async configure({ model, effort } = {}) {
    if (this.view.phase !== 'ready' || !this.#session) return;
    const connection = this.#connection, session = this.#session;
    for (const [key, value] of [['model', model], ['effort', effort]]) {
      if (typeof value !== 'string' || !this.#settingIds[key] || value === this.view[key]) continue;
      this.#wanted[key] = value;
      try {
        const result = await connection.request('session/set_config_option', { sessionId: session, configId: this.#settingIds[key], value });
        if (this.#session !== session) return;
        if (Array.isArray(result?.configOptions)) this.#showSettings(result.configOptions); else this.#update({ [key]: value });
      } catch (error) {
        if (this.#session === session) this.#update({ status: describeError(error) });
        return;
      }
    }
  }

  #showSettings(configOptions) {
    const { ids, view } = settings(configOptions);
    this.#settingIds = ids;
    this.#update(view);
  }

  async #openSession(connection) {
    const chat = this.#chat;
    const tools = await startProjectTools({
      readBrief: () => {
        if (this.#tools === tools && this.view.phase === 'running') this.#message('tool', 'Read the project brief');
      },
      stageNote: (text) => {
        if (this.#tools !== tools || this.view.phase !== 'running' || this.view.draft !== null) return false;
        this.#message('tool', 'Proposed a note for review', { draft: text });
        return true;
      }
    });
    if (this.#connection !== connection) {
      tools.close();
      return;
    }
    this.#tools = tools;
    const request = {
      cwd: this.#workspace,
      mcpServers: [tools.registration],
      _meta: {
        agneta: { account: this.view.account, engine: this.view.engine || undefined },
        'agneta/policy': { tools: 'app-only', network: 'none', approval: 'never-ask', limits },
        'agneta/instructions': { text: instructions },
        'agneta/task': { title: `${project.name} · Project Chat` }
      }
    };
    let opened;
    // An engine Agneta is still downloading answers -32015 with its progress: wait, showing it, then try again.
    for (const started = Date.now(); ; ) {
      try {
        opened = await connection.request('session/new', request, 30_000);
        break;
      } catch (error) {
        const downloading = error.data?.agneta?.engineDownloading;
        if (error.code !== -32015 || Date.now() - started > 600_000 || this.#connection !== connection) throw error;
        const name = this.view.providers.flatMap((entry) => entry.engines).find((entry) => entry.id === downloading?.engine)?.name ?? 'the engine';
        const progress = downloading?.total ? ` · ${size(downloading.received)} of ${size(downloading.total)}` : '';
        this.#update({ status: `${this.name} is downloading ${name}${progress}…` });
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }
    if (this.#connection !== connection) return;
    if (typeof opened?.sessionId !== 'string') throw new Error('Agneta returned no session ID.');
    if (this.#chat !== chat) {
      // Its chat was closed or switched meanwhile: not this chat's session.
      tools.close();
      connection.request('session/close', { sessionId: opened.sessionId }, 8000).catch(() => {});
      return;
    }
    this.#session = opened.sessionId;
    this.#showSettings(opened.configOptions);
    // What the user picked in an earlier chat, where this engine offers it.
    const keep = Object.fromEntries(['model', 'effort'].filter((key) =>
      this.#wanted[key] && this.view[`${key === 'model' ? 'models' : 'efforts'}`].some((entry) => entry.value === this.#wanted[key])
    ).map((key) => [key, this.#wanted[key]]));
    if (Object.keys(keep).length) await this.configure(keep);
  }

  async send(text) {
    if (this.view.phase !== 'ready' || typeof text !== 'string') return;
    text = text.trim();
    if (!text || text.length > 4000) return;
    const connection = this.#connection;
    let session = this.#session;
    this.#reply = null;
    this.#message('user', text, { phase: 'opening', status: 'Starting the turn…', usage: null });
    try {
      if (!session) {
        // The session opening ahead, or a new one if that failed.
        await this.#opening;
        if (!this.#session) await this.#openSession(connection);
        session = this.#session;
        if (this.#connection !== connection || !session) return;
      }
      this.#update({ phase: 'running', status: 'Waiting for the agent…' });
      const result = await connection.request('session/prompt', {
        sessionId: session, prompt: [{ type: 'text', text }]
      }, 120_000);
      if (this.#connection !== connection || this.#session !== session) return;
      const limit = result?._meta?.['agneta/limit']?.limit;
      const status = limit ? `Stopped at the ${limit} limit.`
        : result?.stopReason === 'cancelled' ? 'Turn stopped.'
        : !result?.stopReason || result.stopReason === 'end_turn' ? 'Ready'
        : `Turn ended (${result.stopReason}).`;
      this.#update({ phase: 'ready', status, usage: result?._meta?.['agneta/usage'] ?? null });
    } catch (error) {
      if (this.#connection !== connection || (session && this.#session !== session)) return;
      if (!this.#session) this.#dropSession();
      this.#update({ phase: 'ready', status: describeError(error) });
    }
  }

  stop() {
    if (this.view.phase !== 'running') return;
    try {
      this.#connection.notify('session/cancel', { sessionId: this.#session });
      this.#update({ phase: 'stopping', status: 'Stopping…' });
    } catch (error) {
      this.disconnect(describeError(error));
    }
  }

  async newChat() {
    if (this.view.phase !== 'ready') return;
    const connection = this.#connection;
    const session = this.#session;
    this.#update({ phase: 'resetting', status: 'Closing the chat…' });
    try {
      if (session) await connection.request('session/close', { sessionId: session }, 8000);
    } catch (error) {
      if (this.#connection === connection && this.#session) {
        this.disconnect(describeError(error));
        return;
      }
    }
    if (this.#connection !== connection) return;
    this.#dropSession();
    this.#update({ phase: 'ready', status: 'Ready', messages: [], draft: null, usage: null, ...noSettings });
    this.#prepare();
  }

  disconnect(status = 'Disconnected. Connect to start a new chat.') {
    const connection = this.#connection;
    this.#connection = undefined;
    this.#onCatalog?.({ connected: true });
    this.#dropSession();
    connection?.close();
    this.#update({ phase: 'disconnected', status, code: '', providers: [], account: '', engine: '', ...noSettings });
  }

  #dropSession() {
    this.#chat += 1;
    this.#opening = null;
    this.#settingIds = {};
    this.#session = undefined;
    this.#reply = null;
    this.#tools?.close();
    this.#tools = undefined;
  }

  review(save) {
    const text = this.view.draft;
    if (text === null) return;
    const notes = save ? [...this.view.notes, text] : this.view.notes;
    this.#update({ draft: null, notes });
  }

  #message(role, text, fields = {}) {
    const message = { role, text };
    this.view.messages.push(message);
    this.#update(fields);
    return message;
  }

  /** Resolves once Agneta says a provider is connected (`agneta/catalogChanged`), or the connection goes. */
  #providerConnected() {
    return new Promise((resolve) => { this.#onCatalog = (catalog) => { if (catalog?.connected) { this.#onCatalog = null; resolve(); } }; });
  }

  #notification(method, params) {
    if (method === 'agneta/catalogChanged') this.#onCatalog?.(params?.catalog);
    if (method === 'agneta/pairingCode' && this.view.phase === 'pairing') {
      this.#update({ code: params?.code ?? '' });
    }
    // The user changed what this app may use, or an engine arrived or went away.
    if (method === 'agneta/accessChanged' && params?.access) this.#setAccess(params.access);
    if (!this.#session || params?.sessionId !== this.#session) return;
    if (method === 'agneta/sessionStopped') {
      const status = params.stoppedBy === 'user' ? `Stopped in ${this.name}.` : 'The engine stopped.';
      this.#dropSession();
      // A close in progress still owns the reset.
      if (this.view.phase === 'resetting') return;
      this.#message('notice', `${status} Your next message starts a new session.`, { phase: 'ready', status });
    }
    if (method === 'agneta/queued' && this.view.phase === 'running') {
      this.#update({ status: `Queued · position ${params.position}` });
    }
    if (method === 'session/update' && this.view.phase === 'running') {
      const update = params.update;
      const text = update?.content?.text;
      if (update?.sessionUpdate !== 'agent_message_chunk' || typeof text !== 'string' || !text) return;
      if (this.#reply !== this.view.messages.at(-1)) this.#reply = null;
      const fields = { status: 'Receiving reply…' };
      if (this.#reply) {
        this.#reply.text += text;
        this.#update(fields);
      } else {
        this.#reply = this.#message('assistant', text, fields);
      }
    }
  }
}
