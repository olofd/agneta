import { EventEmitter } from 'node:events';
import { AgnetaClient, configSetting, findConfigOption, memoryTokenStore } from '@agneta-ai/client';
import { project, startProjectTools } from './project-tools.mjs';

const limits = { maxTurns: 12, maxSeconds: 90 };
const instructions = [
  'You are the assistant in Project Chat. Use read_project_brief for facts about the sample project.',
  'When asked to draft a note, read the brief and call propose_note with a short draft.',
  'The draft is only a proposal. The user reviews and saves it in the app.',
  'Use plain text and keep replies brief.'
].join(' ');

/** What to show for an error from Agneta (`@agneta-ai/client` types each one by `kind`). */
function describeError(error) {
  switch (error?.kind) {
    case 'blocked': return 'Project Chat may not connect to Agneta here (a sandbox without the network client entitlement).';
    case 'outdated': return error.message;
    case 'needsSignIn': return 'Sign in to this account in Agneta, then try again.';
    case 'notAllowed': return 'Pairing was declined or expired. Select Connect to try again.';
    case 'paused': return 'This account is paused. Resume it in Agneta, then try again.';
    case 'rateLimited': return 'The provider rate-limited this account. Try again later.';
    // A limit the user set for this app in Agneta: their choice, said with when it resets (Agneta's message has it).
    case 'appLimit': return `${error.message} You can change it in Agneta's settings.`;
  }
  if (error?.code === -32000) return 'Sign in to this account in Agneta, then try again.';
  return error?.message ?? String(error);
}

/** Keeps nothing: the token lasts as long as the app runs. Electron passes a Keychain-backed store (main.mjs). */
export const memoryTokens = memoryTokenStore;

/**
 * The engine's model and reasoning-effort settings, from the session's `configOptions` (ACP), found by their standard
 * category (`model`, `thought_level`) rather than each engine's own ids. Either is absent when the engine doesn't offer it.
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
 * Steps of getting Agneta that the window's panel shows (with the question, when there is one); the rest go in the
 * status line. `@agneta-ai/client` words each one; the panel shows them as they are.
 */
const panelSteps = new Set(['notInstalled', 'installing', 'onDiskImage', 'installed', 'notRunning', 'opening', 'slow', 'outdated', 'needsProvider', 'settingUp']);

/** No session, so no settings to show. */
const noSettings = { models: [], model: '', efforts: [], effort: '' };

/** Bytes as people read them: "45 MB". */
function size(bytes) {
  return Number.isFinite(bytes) ? `${Math.round(bytes / 1e6)} MB` : '';
}

export class ProjectChat extends EventEmitter {
  /** One client for this Agneta: it connects, pairs, keeps the token and routes what Agneta sends. */
  #client;
  /** Counts connection attempts: work from an earlier one that finishes late is dropped. */
  #attempt = 0;
  #session;
  #tools;
  #access;
  #tokens;
  /** Ends the connect in progress: its waits for Agneta, and a question on screen. */
  #controller = null;
  /** Answers the question the panel shows. */
  #answer = null;
  /** The session being opened ahead of the first message, so the model and effort can be chosen before it. */
  #opening = null;
  /** Counts chats: a session that finishes opening after its chat was closed or switched is closed, not used. */
  #chat = 0;
  /** The engine's ids for the model and effort settings, and what the user picked, kept for the next chat. */
  #settingIds = {};
  #wanted = {};

  /**
   * @param tokens where the token from Always Allow is kept between launches (`load`, `save`, `clear`).
   * @param environment how to find and open Agneta on this Mac (main.mjs: `electronEnvironment({ app, shell })`). Without
   *   it, the app only says Agneta isn't running.
   * @param name what the app calls this Agneta in what it shows: "Agneta" for a release, "Agneta Dev" for a development build.
   * @param client more of the client's options (tests: the open URL, install page and bundle ID for a port of their own).
   */
  constructor(port, { tokens = memoryTokens(), environment = undefined, name = 'Agneta', client: more = {} } = {}) {
    super();
    this.port = port;
    this.name = name;
    this.#tokens = tokens;
    this.#client = new AgnetaClient({
      name: 'Project Chat',
      port,
      tokens,
      ...(environment ? { environment } : {}),
      // The app's own tools and no user folders.
      scope: { tools: 'app-only', folders: [] },
      clientInfo: { name: 'agneta-project-chat', title: 'Project Chat', version: '0.1.0' },
      timeouts: { session: 30_000, prompt: 120_000 },
      ...more
    });
    const client = this.#client;
    client.on('pairingCode', (code) => { if (this.view.phase === 'pairing') this.#update({ code }); });
    // The user changed what this app may use, or an engine arrived or went away.
    client.on('accessChanged', (access) => this.#setAccess(access));
    client.on('disconnected', () => {
      // Let the pending handshake surface its more specific connection error.
      if (['disconnected', 'connecting', 'guide', 'pairing'].includes(this.view.phase)) return;
      const remembered = client.remembered;
      this.disconnect('Connection closed. Connect to start a new chat.');
      // Agneta closes an app's connections when its access is removed: reconnecting with the token says whether
      // that's what happened (or Agneta quit).
      if (remembered) setTimeout(() => this.connect({ quiet: true }), 1000);
    });
    this.view = {
      project,
      phase: 'disconnected',
      status: 'Connect to start chatting.',
      code: '',
      // While getting Agneta: what the panel shows ({ step, title, detail }), with the question to answer, if any.
      guide: null,
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
   * opens Agneta's approval window (after Agneta's window for connecting a provider, when none is). When Agneta isn't
   * installed or running, the window's panel asks the user and shows each step (docs/APP_PROTOCOL.md, Getting Agneta).
   * A token Agneta no longer accepts (access removed there) is forgotten. `quiet` (at launch, and after the connection
   * drops) never opens the approval window, and only offers to open Agneta to someone with a kept token.
   */
  async connect({ quiet = false } = {}) {
    if (this.view.phase !== 'disconnected') return;
    const attempt = ++this.#attempt;
    const controller = this.#controller = new AbortController();
    this.#update({
      phase: 'connecting', status: `Connecting to ${this.name}…`, code: '', guide: null,
      messages: [], draft: null, usage: null
    });
    const kept = await this.#tokens.load();
    try {
      await this.#client.connect({
        pair: quiet ? 'never' : 'if-needed',
        setup: true,
        // Without an environment (tests, an isolated instance) the client can't open anything, so nothing is asked.
        ...(this.#client.options.environment ? { guide: (question) => this.#ask(question, attempt) } : {}),
        onProgress: (progress) => { if (this.#attempt === attempt) this.#progress(progress); },
        signal: controller.signal
      });
      if (this.#attempt !== attempt) return;
      if (typeof this.#client.workspace !== 'string') throw new Error('Use an Agneta build that tells apps what they may use.');
      this.#setAccess(this.#client.access);
      if (!this.view.account) throw new Error(`No active provider was granted. Connect one in ${this.name} and pair again.`);
      this.#update({ phase: 'ready', status: 'Ready', code: '', guide: null });
      this.#prepare();
    } catch (error) {
      if (this.#attempt !== attempt) return;
      switch (error?.kind) {
        case 'needsPairing': return this.disconnect(kept ? `Your access was removed in ${this.name}. Connect to ask again.` : 'Connect to start chatting.');
        case 'declined': case 'aborted': return this.disconnect('Connect to start chatting.');
        case 'notInstalled': return this.disconnect(`${this.name} isn't installed. Connect to get it.`);
        case 'notRunning': return this.disconnect(`${this.name} isn't running. Connect to open it.`);
        default: return this.disconnect(describeError(error));
      }
    }
  }

  /** A question only the user answers, in the window's panel; resolves to their answer. */
  #ask(question, attempt) {
    if (this.#attempt !== attempt) return false;
    return new Promise((resolve) => {
      this.#answer = resolve;
      this.#update({
        phase: 'guide', status: question.title,
        guide: {
          step: question.kind, title: question.title, detail: question.detail,
          question: { kind: question.kind, confirm: question.confirm, cancel: question.cancel },
          homebrew: question.kind === 'install' && !question.onDiskImage ? question.homebrew : null
        }
      });
    });
  }

  /** The user's answer to the panel's question (`yes`), or Keep Waiting while Agneta is slow to open (`wait`). */
  answer(choice) {
    if (choice === 'wait' && this.view.guide?.keepWaiting) {
      this.#update({ guide: { ...this.view.guide, keepWaiting: false } });
      return;
    }
    const resolve = this.#answer;
    this.#answer = null;
    resolve?.(choice === 'yes');
  }

  /** Opens the install page again (the user closed it), during the install wait. */
  async openInstallPage() {
    if (this.view.guide?.step === 'installing' || this.view.guide?.step === 'onDiskImage') await this.#client.openInstallPage();
  }

  /** Homebrew's command, for the panel's Copy (main.mjs puts it on the clipboard). */
  get homebrew() {
    return this.#client.homebrew;
  }

  #progress(progress) {
    if (panelSteps.has(progress.step)) {
      const homebrew = ['notInstalled', 'installing'].includes(progress.step) ? this.#client.homebrew : null;
      this.#update({
        phase: 'guide', status: progress.title,
        guide: { step: progress.step, title: progress.title, detail: progress.detail, homebrew, keepWaiting: progress.step === 'slow' && progress.keepWaiting }
      });
    } else if (progress.step === 'pairing') {
      this.#update({ phase: 'pairing', status: progress.title, guide: null, ...(progress.code ? { code: progress.code } : {}) });
    } else if (progress.step === 'connecting' || progress.step === 'looking') {
      this.#update({ phase: 'connecting', status: progress.title, guide: null });
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
    this.#update({ account: provider.id, engine: chosen });
    await this.newChat();
  }

  /** Opens the chat's session ahead of its first message, in the background, so its settings can be shown. */
  #prepare() {
    if (this.#session || this.#opening || this.view.phase !== 'ready') return;
    const attempt = this.#attempt, chat = this.#chat;
    this.#opening = this.#openSession()
      .catch((error) => {
        if (this.#attempt === attempt && this.#chat === chat) this.#update({ status: describeError(error) });
      })
      .finally(() => { if (this.#chat === chat) this.#opening = null; });
  }

  /**
   * Sets the model or reasoning effort (`session/set_config_option`) between turns; the engine answers with its
   * options as they are now (another model may offer other efforts). Kept for the next chat.
   */
  async configure({ model, effort } = {}) {
    if (this.view.phase !== 'ready' || !this.#session) return;
    const session = this.#session;
    for (const [key, value] of [['model', model], ['effort', effort]]) {
      if (typeof value !== 'string' || !this.#settingIds[key] || value === this.view[key]) continue;
      this.#wanted[key] = value;
      try {
        const options = await session.setConfigOption(this.#settingIds[key], value, { timeout: 15_000 });
        if (this.#session !== session) return;
        this.#showSettings(options);
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

  async #openSession() {
    const attempt = this.#attempt, chat = this.#chat;
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
    if (this.#attempt !== attempt) {
      tools.close();
      return;
    }
    this.#tools = tools;
    // An engine Agneta is still downloading: the client waits (up to 10 minutes), and the status shows the progress.
    const session = await this.#client.newSession({
      account: this.view.account,
      engine: this.view.engine || undefined,
      mcpServers: [tools.registration],
      policy: { tools: 'app-only', network: 'none', approval: 'never-ask', limits },
      instructions,
      task: `${project.name} · Project Chat`,
      onDownloadProgress: (downloading) => {
        if (this.#attempt !== attempt) return;
        const name = this.view.providers.flatMap((entry) => entry.engines).find((entry) => entry.id === downloading.engine)?.name ?? 'the engine';
        const progress = downloading.total ? ` · ${size(downloading.received)} of ${size(downloading.total)}` : '';
        this.#update({ status: `${this.name} is downloading ${name}${progress}…` });
      }
    });
    if (this.#attempt !== attempt) return;
    if (this.#chat !== chat) {
      // Its chat was closed or switched meanwhile: not this chat's session.
      tools.close();
      session.close({ timeout: 8000 }).catch(() => {});
      return;
    }
    this.#session = session;
    session.on('queued', (position, waitingFor) => {
      if (this.#session !== session || this.view.phase !== 'running') return;
      this.#update({ status: waitingFor === 'app' ? 'Waiting: your limit of tasks at once in Agneta' : `Queued · position ${position}` });
    });
    session.on('ended', (end) => {
      if (this.#session !== session || end.reason !== 'stopped') return;
      const reason = {
        user: `Stopped in ${this.name}.`, engine: 'The engine stopped.', limit: 'The session reached its limit.',
        reach: 'A project tool is no longer reachable.'
      }[end.stoppedBy] ?? 'The session stopped.';
      const status = end.detail ? `${reason} ${end.detail}` : reason;
      this.#dropSession();
      // A close in progress still owns the reset.
      if (this.view.phase === 'resetting') return;
      this.#message('notice', `${status} Your next message starts a new session.`, { phase: 'ready', status });
    });
    this.#showSettings(session.configOptions);
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
    const attempt = this.#attempt;
    let session = this.#session;
    this.#message('user', text, { phase: 'opening', status: 'Starting the turn…', usage: null });
    try {
      if (!session) {
        // The session opening ahead, or a new one if that failed.
        await this.#opening;
        if (!this.#session) await this.#openSession();
        session = this.#session;
        if (this.#attempt !== attempt || !session) return;
      }
      this.#update({ phase: 'running', status: 'Waiting for the agent…' });
      const turn = session.prompt(text);
      let reply = null;
      for await (const piece of turn.textStream()) {
        if (this.#session !== session || this.view.phase !== 'running') continue;
        if (reply !== this.view.messages.at(-1)) reply = null;
        if (reply) {
          const offset = reply.text.length;
          reply.text += piece;
          if (this.view.status === 'Receiving reply…') {
            this.emit('change', this.view, { index: this.view.messages.length - 1, offset, text: piece });
          } else {
            this.#update({ status: 'Receiving reply…' });
          }
        } else {
          reply = this.#message('assistant', piece, { status: 'Receiving reply…' });
        }
      }
      const result = await turn;
      if (this.#attempt !== attempt || this.#session !== session) return;
      const status = result.limit?.limit === 'appSpend' ? 'Stopped: the spending limit you set in Agneta is reached.'
        : result.limit ? `Stopped at the ${result.limit.limit} limit.`
        : result.cancelled ? 'Turn stopped.'
        : result.stopReason === 'end_turn' ? 'Ready'
        : `Turn ended (${result.stopReason}).`;
      this.#update({ phase: 'ready', status, usage: result.usage });
    } catch (error) {
      if (this.#attempt !== attempt || (session && this.#session !== session)) return;
      if (!this.#session) this.#dropSession();
      this.#update({ phase: 'ready', status: describeError(error) });
    }
  }

  stop() {
    if (this.view.phase !== 'running') return;
    this.#session.cancel();
    this.#update({ phase: 'stopping', status: 'Stopping…' });
  }

  async newChat() {
    if (this.view.phase !== 'ready') return;
    const attempt = this.#attempt;
    const session = this.#session;
    this.#update({ phase: 'resetting', status: 'Closing the chat…' });
    try {
      if (session) await session.close({ timeout: 8000 });
    } catch (error) {
      if (this.#attempt === attempt && this.#session) {
        this.disconnect(describeError(error));
        return;
      }
    }
    if (this.#attempt !== attempt) return;
    this.#dropSession();
    this.#update({ phase: 'ready', status: 'Ready', messages: [], draft: null, usage: null, ...noSettings });
    this.#prepare();
  }

  disconnect(status = 'Disconnected. Connect to start a new chat.') {
    this.#attempt += 1;
    // Ends a wait for Agneta, and answers no to a question on screen.
    this.#controller?.abort();
    this.#controller = null;
    this.answer('no');
    this.#dropSession();
    this.#update({ phase: 'disconnected', status, code: '', guide: null, providers: [], account: '', engine: '', ...noSettings });
    this.#client.close();
  }

  #dropSession() {
    this.#chat += 1;
    this.#opening = null;
    this.#settingIds = {};
    this.#session = undefined;
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
}
