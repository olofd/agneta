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

export class ProjectChat extends EventEmitter {
  #connection;
  #session;
  #tools;
  #account;
  #workspace;
  #reply;

  constructor(port) {
    super();
    this.port = port;
    this.view = {
      project,
      phase: 'disconnected',
      status: 'Connect to start chatting.',
      code: '',
      account: '',
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
      const agneta = initialized?._meta?.agneta;
      if (initialized?.protocolVersion !== 1 || typeof agneta?.workspace !== 'string') {
        throw new Error('Use an Agneta build that provides a workspace when pairing.');
      }
      const account = agneta.accounts?.find((entry) => entry.paused === false);
      if (!account) throw new Error('No active account was granted. Connect an account in Agneta and pair again.');
      this.#account = account.id;
      this.#workspace = agneta.workspace;
      this.#update({ phase: 'ready', account: account.label, status: 'Ready', code: '' });
    } catch (error) {
      if (this.#connection === connection) this.disconnect(describeError(error));
    }
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
    const opened = await connection.request('session/new', {
      cwd: this.#workspace,
      mcpServers: [tools.registration],
      _meta: {
        agneta: { account: this.#account },
        'agneta/policy@1': { tools: 'app-only', network: 'none', approval: 'never-ask', limits },
        'agneta/instructions': { text: instructions },
        'agneta/task@1': { title: `${project.name} · Project Chat` }
      }
    }, 30_000);
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
      const limit = result?._meta?.['agneta/limit@1']?.limit;
      const status = limit ? `Stopped at the ${limit} limit.`
        : result?.stopReason === 'cancelled' ? 'Turn stopped.'
        : !result?.stopReason || result.stopReason === 'end_turn' ? 'Ready'
        : `Turn ended (${result.stopReason}).`;
      this.#update({ phase: 'ready', status, usage: result?._meta?.['agneta/usage@1'] ?? null });
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
    this.#update({ phase: 'disconnected', status, code: '', account: '' });
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
