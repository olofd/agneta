import { EventEmitter } from 'node:events';
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
  #access;

  constructor(port) {
    super();
    this.port = port;
    this.view = {
      project,
      phase: 'disconnected',
      status: 'Connect to start chatting.',
      code: '',
      // What Agneta lets this app use (agneta/access), and the provider and engine the next chat runs on.
      providers: [],
      account: '',
      engine: '',
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

  async connect() {
    if (this.view.phase !== 'disconnected') return;
    this.#update({
      phase: 'connecting', status: 'Connecting to Agneta…', code: '',
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
        this.disconnect('Connection closed. Connect to start a new chat.');
      }
    });
    this.#connection = connection;

    try {
      await connection.ready;
      if (this.#connection !== connection) return;
      this.#update({ phase: 'pairing', status: 'Approve Project Chat in Agneta.' });
      // Ask for the app's own tools and no user folders.
      const paired = await connection.request('agneta/pair', {
        name: 'Project Chat', scope: { tools: 'app-only', folders: [] }
      }, 310_000);
      if (typeof paired?.token !== 'string') throw new Error('Agneta returned an incomplete pairing response.');
      // The example uses Allow Once. The token never leaves the main process.
      const initialized = await connection.request('initialize', {
        protocolVersion: 1,
        clientCapabilities: {},
        clientInfo: { name: 'agneta-project-chat', title: 'Project Chat', version: '0.1.0' },
        _meta: { agneta: { token: paired.token } }
      });
      if (this.#connection !== connection) return;
      const access = initialized?._meta?.agneta?.access;
      if (initialized?.protocolVersion !== 1 || typeof access?.workspace !== 'string') {
        throw new Error('Use an Agneta build that tells apps what they may use.');
      }
      this.#workspace = access.workspace;
      this.#setAccess(access);
      if (!this.view.account) throw new Error('No active provider was granted. Connect one in Agneta and pair again.');
      this.#update({ phase: 'ready', status: 'Ready', code: '' });
    } catch (error) {
      if (this.#connection === connection) this.disconnect(describeError(error));
    }
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
    if (this.#session) await this.newChat();
    this.#update({ account: provider.id, engine: chosen });
  }

  async #openSession(connection) {
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
        this.#update({ status: `Agneta is downloading ${name}${progress}…` });
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }
    if (this.#connection !== connection) return;
    if (typeof opened?.sessionId !== 'string') throw new Error('Agneta returned no session ID.');
    this.#session = opened.sessionId;
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
        await this.#openSession(connection);
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
    this.#update({ phase: 'ready', status: 'Ready', messages: [], draft: null, usage: null });
  }

  disconnect(status = 'Disconnected. Connect to start a new chat.') {
    const connection = this.#connection;
    this.#connection = undefined;
    this.#dropSession();
    connection?.close();
    this.#update({ phase: 'disconnected', status, code: '', providers: [], account: '', engine: '' });
  }

  #dropSession() {
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

  #notification(method, params) {
    if (method === 'agneta/pairingCode' && this.view.phase === 'pairing') {
      this.#update({ code: params?.code ?? '' });
    }
    // The user changed what this app may use, or an engine arrived or went away.
    if (method === 'agneta/accessChanged' && params?.access) this.#setAccess(params.access);
    if (!this.#session || params?.sessionId !== this.#session) return;
    if (method === 'agneta/sessionStopped') {
      const status = params.stoppedBy === 'user' ? 'Stopped in Agneta.' : 'The engine stopped.';
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
