// The window's state: the connection and the app's sandbox grant, the choice of provider, engine, sandbox mode, model
// and effort, the current run with its live transcript and evidence, the modes check, and the matrix runner with its
// reports. It lives in Electron's main process (the
// renderer only sees `view` and calls the fixed actions main.mjs exposes), and drives the same BenchRun and
// runMatrix as the headless runner, so what a person tries by hand is measured exactly as the matrix measures it.
import { EventEmitter } from 'node:events';
import { readdir, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Agneta, describeError, memoryTokens } from './agneta.mjs';
import { plan, resultsFolder, runMatrix, timestamp } from './bench.mjs';
import { checkModes } from './modes.mjs';
import { duration, gotText, writeReport } from './report.mjs';
import { BenchRun } from './run.mjs';
import { expectedMode, meaning, modes, uncontainedMeaning, whoDecides } from './sandbox.mjs';
import { expectation, scenario as named, scenarios } from './scenarios.mjs';

const noSettings = { models: [], model: '', efforts: [], effort: '' };

/** What the renderer shows of a run: its transcript (the latest entries), checks and evidence, never its servers' secrets. */
function runView(run) {
  if (!run) return null;
  const evidence = run.evidence;
  const record = run.record();
  return {
    scenario: run.scenario?.name ?? null,
    title: run.scenario?.title ?? 'Free run',
    workspace: run.workspace,
    phase: run.phase,
    status: run.status,
    transcript: run.transcript.slice(-400).map((entry) => ({ ...entry })),
    outcome: record.outcome,
    expected: record.expected,
    checks: record.checks,
    gateway: { count: evidence.gateway.filter(({ ok }) => ok).length, refused: evidence.gateway.filter(({ ok }) => !ok).length, recent: evidence.gateway.slice(-6).map(({ op, ok, samples, at }) => ({ op, ok, samples, at })) },
    mcp: evidence.mcp.slice(-30).map(({ tool, ok, summary, at, ms }) => ({ tool, ok, summary, at, ms })),
    commands: evidence.commands.length,
    refusals: record.refusals.slice(-12),
    refused: run.refused,
    sandbox: run.choice.sandbox,
    got: run.got,
    scores: evidence.scores.map(({ ok, rmsErrorDb, message, at }) => ({ ok, db: Number.isFinite(rmsErrorDb) ? rmsErrorDb : rmsErrorDb < 0 ? '-inf' : null, message, at })),
    usage: { modelCalls: record.modelCalls, cost: record.cost, costKind: record.costKind, time: duration(record.turnMs) }
  };
}

/** Steps of getting Agneta the window's panel shows (`@agneta/client` words each one); the rest go in the status line. */
const panelSteps = new Set(['notInstalled', 'installing', 'onDiskImage', 'installed', 'notRunning', 'opening', 'slow', 'outdated', 'needsProvider', 'settingUp']);

export class BenchApp extends EventEmitter {
  #agneta;
  #tokens;
  /** How to find and open Agneta (main.mjs: `electronEnvironment`), and more of the client's options. */
  #environment;
  #clientOptions;
  /** Ends the connect in progress: its waits for Agneta, and a question on screen. */
  #controller = null;
  /** Answers the question the panel shows. */
  #answer = null;
  /** The run on screen: prepared ahead (its session open, so the model and effort can be picked), or done. */
  #run = null;
  #preparing = null;
  #wanted = {};
  #matrixStop = false;

  constructor(port, { home, tokens = memoryTokens(), environment = undefined, name = 'Agneta', client = {} }) {
    super();
    this.port = port;
    this.home = home;
    this.name = name;
    this.#tokens = tokens;
    this.#environment = environment;
    this.#clientOptions = client;
    this.view = {
      phase: 'disconnected', status: 'Connect to start.', code: '', home,
      // While getting Agneta: what the panel shows ({ step, title, detail }), with the question to answer, if any.
      guide: null,
      providers: [], account: '', engine: '', sandbox: 'contained',
      // The grant's mode (the ceiling the user set in Agneta), what the chosen engine would give, and the words for both.
      grant: null, prediction: null, explain: { meaning, whoDecides, uncontained: uncontainedMeaning },
      ...noSettings,
      scenarios: [], run: null,
      modes: { running: false, rows: [], log: [], report: null },
      matrix: { running: false, log: [], scenario: 'all', engines: 'all', sandbox: 'both', report: null },
      reports: []
    };
    this.#refreshScenarios();
  }

  #update(fields = {}) {
    Object.assign(this.view, fields);
    const engine = this.view.providers.find((entry) => entry.id === this.view.account)?.engines.find((entry) => entry.id === this.view.engine);
    this.view.prediction = engine ? expectedMode({ grant: this.view.grant, levels: engine.levels, asked: this.view.sandbox }) : null;
    this.view.run = runView(this.#run);
    this.emit('change', this.view);
  }

  #refreshScenarios() {
    const engine = this.view.engine;
    this.view.scenarios = scenarios.map((entry) => ({
      name: entry.name, title: entry.title, about: entry.about, minutes: entry.minutes,
      expected: expectation(entry, engine, this.view.sandbox),
      last: this.view.scenarios?.find((shown) => shown.name === entry.name)?.last ?? null
    }));
  }

  /**
   * Connects (pairing when needed). When Agneta isn't installed or running, the window's panel asks the user and shows
   * each step (docs/APP_PROTOCOL.md, Getting Agneta); `quiet` (at launch) only offers to open it to someone with kept
   * access, and never pairs.
   */
  async connect({ quiet = false, pair = false } = {}) {
    if (this.view.phase !== 'disconnected') return;
    this.#update({ phase: 'connecting', status: `Connecting to ${this.name}…`, code: '', guide: null });
    const agneta = new Agneta(this.port, { home: this.home, tokens: this.#tokens, name: this.name, environment: this.#environment, client: this.#clientOptions });
    this.#agneta = agneta;
    const controller = this.#controller = new AbortController();
    agneta.on('code', (code) => { if (this.#agneta === agneta) this.#update({ code, phase: 'pairing', guide: null, status: `Approve Replica Bench in ${this.name}: check the code matches.` }); });
    // Every step of every connect (the bench pairs again when its grant no longer covers its folder).
    agneta.client.on('progress', (progress) => { if (this.#agneta === agneta) this.#progress(progress); });
    agneta.on('access', () => { if (this.#agneta === agneta && this.view.phase !== 'connecting') this.#setAccess(); });
    agneta.on('disconnected', () => {
      if (this.#agneta !== agneta) return;
      this.#dropRun();
      this.#agneta = undefined;
      this.#update({ phase: 'disconnected', status: `${this.name} closed the connection. Connect to go on.`, providers: [], ...noSettings });
    });
    try {
      const access = await agneta.connect({
        quiet, pair, signal: controller.signal,
        // Without an environment (the headless runner's tests, an isolated instance) nothing can be opened or asked.
        ...(this.#environment ? { guide: (question) => this.#ask(question, agneta) } : {})
      });
      if (this.#agneta !== agneta) return;
      if (!access) {
        this.#agneta = undefined;
        this.#update({ phase: 'disconnected', status: 'Connect to start.', guide: null });
        return;
      }
      this.#setAccess();
      this.#update({ phase: 'ready', status: 'Ready', code: '', guide: null });
      this.#prepare();
    } catch (error) {
      if (this.#agneta !== agneta) return;
      this.#agneta = undefined;
      const status = {
        declined: 'Connect to start.', aborted: 'Connect to start.',
        notInstalled: `${this.name} isn't installed. Connect to get it.`, notRunning: `${this.name} isn't running. Connect to open it.`
      }[error?.kind] ?? describeError(error);
      this.#update({ phase: 'disconnected', code: '', guide: null, status });
    }
  }

  /** A question only the user answers, in the window's panel; resolves to their answer. */
  #ask(question, agneta) {
    if (this.#agneta !== agneta) return false;
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
    if (['installing', 'onDiskImage'].includes(this.view.guide?.step)) await this.#agneta?.client.openInstallPage();
  }

  /** Homebrew's command, for the panel's Copy (main.mjs puts it on the clipboard). */
  get homebrew() {
    return this.#agneta?.client.homebrew ?? null;
  }

  /** Steps of getting Agneta go in the panel; pairing and connecting in the status line. */
  #progress(progress) {
    if (panelSteps.has(progress.step)) {
      const homebrew = ['notInstalled', 'installing'].includes(progress.step) ? this.homebrew : null;
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

  #setAccess() {
    const providers = this.#agneta.providers();
    const provider = providers.find((entry) => entry.id === this.view.account && !entry.paused) ?? providers.find((entry) => !entry.paused && entry.engines.length);
    const engine = provider?.engines.some((entry) => entry.id === this.view.engine) ? this.view.engine : provider?.engines[0]?.id ?? '';
    this.view.engine = engine;
    this.#refreshScenarios();
    this.#update({
      providers, account: provider?.id ?? '', engine, grant: this.#agneta.grant
    });
  }


  disconnect() {
    // Ends a wait for Agneta, and answers no to a question on screen.
    this.#controller?.abort();
    this.#controller = null;
    this.answer('no');
    this.#matrixStop = true;
    this.#dropRun();
    const agneta = this.#agneta;
    this.#agneta = undefined;
    agneta?.close();
    this.#update({ phase: 'disconnected', status: 'Disconnected.', code: '', guide: null, providers: [], grant: null, ...noSettings });
  }

  /** Pairs again: the approval window lets the user change the app's sandbox mode, and covers a moved bench folder. */
  async pairAgain() {
    this.disconnect();
    await this.connect({ pair: true });
  }

  /** Picks the provider, engine and sandbox mode for the next run; the prepared run, made for the old choice, closes. */
  async choose({ account, engine, sandbox } = {}) {
    if (this.view.phase !== 'ready') return;
    const provider = this.view.providers.find((entry) => entry.id === (account ?? this.view.account));
    if (!provider) return;
    const chosen = provider.engines.some((entry) => entry.id === engine) ? engine : provider.id === this.view.account ? this.view.engine : provider.engines[0]?.id ?? '';
    const mode = modes.includes(sandbox) ? sandbox : this.view.sandbox;
    if (provider.id === this.view.account && chosen === this.view.engine && mode === this.view.sandbox) return;
    this.view.engine = chosen;
    this.view.sandbox = mode;
    this.#refreshScenarios();
    this.#dropRun();
    this.#update({ account: provider.id, engine: chosen, sandbox: mode, ...noSettings });
    this.#prepare();
  }

  /** Opens the next run's session ahead of its first prompt, so its model and effort can be chosen first. */
  #prepare() {
    if (this.#run || this.#preparing || this.view.phase !== 'ready' || this.view.matrix.running) return;
    const preparing = this.#newRun(null).catch((error) => {
      this.#update({ status: describeError(error) });
      return null;
    }).finally(() => { if (this.#preparing === preparing) this.#preparing = null; });
    this.#preparing = preparing;
  }

  async #newRun(scenario) {
    const run = new BenchRun(this.#agneta, this.home, scenario, {
      account: this.view.account, engine: this.view.engine, sandbox: this.view.sandbox, model: this.#wanted.model, effort: this.#wanted.effort
    });
    this.#show(run);
    await run.start();
    if (this.#run !== run) {
      await run.close();
      return null;
    }
    this.#update({ ...run.config.view });
    return run;
  }

  #show(run) {
    this.#run = run;
    let pending = false;
    run.on('change', () => {
      if (this.#run !== run || pending) return;
      // Busy runs change hundreds of times a second: the window hears at most ten.
      pending = true;
      setTimeout(() => { pending = false; if (this.#run === run) this.#update(); }, 100);
    });
    this.#update();
  }

  #dropRun() {
    const run = this.#run;
    this.#run = null;
    this.#preparing = null;
    run?.close();
  }

  /** A run that hasn't had a turn yet, ready for one: the prepared one, or a new one. */
  async #freshRun() {
    if (this.#preparing) await this.#preparing;
    let run = this.#run;
    if (!run || run.evidence.turns.length > 0 || run.phase !== 'ready') {
      this.#dropRun();
      run = await this.#newRun(null);
    }
    return run;
  }

  /** Runs one scenario in a fresh workspace and session, then judges it. Follow-ups go to the same run. */
  async runScenario(name) {
    const entry = named(name);
    if (!entry || this.view.phase !== 'ready' || this.view.matrix.running) return;
    this.#update({ phase: 'running', status: `Running ${entry.title}…` });
    try {
      const run = await this.#freshRun();
      if (!run) return;
      run.scenario = entry;
      if (run.phase === 'ready') {
        await run.prompt(entry.prompt({ home: homedir(), workspace: run.workspace }));
        await run.followUp();
      }
      await run.evaluate();
      const shown = this.view.scenarios.find((item) => item.name === name);
      if (shown) shown.last = run.record().outcome;
    } catch (error) {
      this.#update({ status: describeError(error) });
    } finally {
      if (this.view.phase === 'running') this.#update({ phase: 'ready', status: this.#run?.status ?? 'Ready' });
    }
  }

  /** A free-form prompt: to the run on screen (a follow-up), or to a fresh one. */
  async send(text) {
    if (this.view.phase !== 'ready' || typeof text !== 'string' || this.view.matrix.running) return;
    text = text.trim();
    if (!text || text.length > 20_000) return;
    this.#update({ phase: 'running', status: 'Starting the turn…' });
    try {
      let run = this.#run;
      if (this.#preparing) run = await this.#preparing;
      if (!run || run.phase !== 'ready') run = await this.#freshRun();
      if (!run) return;
      await run.prompt(text);
      await run.evaluate();
    } catch (error) {
      this.#update({ status: describeError(error) });
    } finally {
      if (this.view.phase === 'running') this.#update({ phase: 'ready', status: this.#run?.status ?? 'Ready' });
    }
  }

  stop() {
    if (this.view.matrix.running) {
      this.#matrixStop = true;
      this.#update({ status: 'Stopping the matrix after this run…' });
    }
    this.#run?.cancel();
  }

  /** Closes the run on screen and prepares the next. */
  async newRun() {
    if (this.view.phase !== 'ready' || this.view.matrix.running) return;
    this.#dropRun();
    this.#update({ status: 'Ready', ...noSettings });
    this.#prepare();
  }

  async configure({ model, effort } = {}) {
    if (this.view.phase !== 'ready' || !this.#run) return;
    if (model) this.#wanted.model = model;
    if (effort) this.#wanted.effort = effort;
    await this.#run.configure({ model, effort });
    this.#update({ ...this.#run.config.view });
  }

  /**
   * The modes check from the Sandbox tab: every provider × engine asked for each mode, with no prompt; what each got
   * or why Agneta refused. Written as a report too, so it can be shared.
   */
  async checkModes() {
    if (this.view.phase !== 'ready' || this.view.matrix.running || this.view.modes.running) return;
    this.#dropRun();
    const log = [];
    this.#update({ phase: 'running', status: 'Checking the sandbox modes…', modes: { running: true, rows: [], log, report: null } });
    try {
      const rows = await checkModes(this.#agneta, this.home, {
        log: (line) => { log.push(line); this.#update(); }
      });
      const report = await writeReport(join(resultsFolder, `${timestamp()}-modes`), {
        modes: rows, meta: { agneta: `${this.name} (port ${this.port})`, home: this.home, grant: this.view.grant }
      });
      this.view.modes = { running: false, rows, log, report };
      this.#update({ status: `Modes checked: ${rows.filter(({ verdict }) => verdict === 'as declared').length} of ${rows.length} as Agneta declared.` });
    } catch (error) {
      this.view.modes.running = false;
      this.#update({ status: describeError(error) });
    } finally {
      this.#update({ phase: this.#agneta?.connected ? 'ready' : 'disconnected' });
      await this.loadReports();
      this.#prepare();
    }
  }

  /** The matrix from the Results tab: the chosen scenarios × engines × sandbox modes, each in a fresh run. */
  async runMatrix({ scenario = 'all', engines = 'all', sandbox = 'both' } = {}) {
    if (this.view.phase !== 'ready' || this.view.matrix.running) return;
    let runs;
    try {
      runs = plan(this.#agneta, { scenario, engine: engines === 'current' ? this.view.engine : engines, sandbox: sandbox === 'current' ? this.view.sandbox : sandbox, account: this.view.account });
    } catch (error) {
      this.#update({ status: error.message });
      return;
    }
    this.#dropRun();
    this.#matrixStop = false;
    const log = [];
    const started = Date.now();
    this.#update({ phase: 'running', status: `Running ${runs.length} runs…`, matrix: { ...this.view.matrix, scenario, engines, sandbox, running: true, log, report: null } });
    try {
      const results = await runMatrix(this.#agneta, this.home, runs, {
        model: this.#wanted.model, effort: this.#wanted.effort,
        log: (line) => {
          log.push(`${duration(Date.now() - started)} ${line}`);
          if (log.length > 300) log.splice(0, log.length - 300);
          this.#update();
        },
        current: (run) => { if (run) this.#show(run); },
        stopped: () => this.#matrixStop
      });
      const paths = await writeReport(join(resultsFolder, timestamp()), {
        results, meta: { agneta: `${this.name} (port ${this.port})`, home: this.home, grant: this.view.grant }
      });
      this.view.matrix.report = paths;
      this.#update({ status: `Report written: ${paths.md}` });
    } catch (error) {
      this.#update({ status: describeError(error) });
    } finally {
      this.#run = null;
      this.view.matrix.running = false;
      this.#update({ phase: this.#agneta?.connected ? 'ready' : 'disconnected' });
      await this.loadReports();
      this.#prepare();
    }
  }

  /** The reports in results/, newest first, with their summary sentences. */
  async loadReports() {
    const folders = await readdir(resultsFolder).catch(() => []);
    const reports = [];
    for (const folder of folders.sort().reverse().slice(0, 30)) {
      try {
        const report = JSON.parse(await readFile(join(resultsFolder, folder, 'report.json'), 'utf8'));
        reports.push({
          id: folder, generated: report.generated, summary: report.summary, md: join(resultsFolder, folder, 'report.md'), grant: report.grant ?? null,
          rows: (report.results ?? []).map((result) => ({
            scenario: result.scenario, engine: result.engine, sandbox: result.sandbox, got: gotText(result), reason: result.refused?.reason ?? null,
            outcome: result.outcome, achieved: result.achieved, why: result.expected?.why ?? null, boundary: result.expected?.boundary ?? false, time: duration(result.turnMs),
            modelCalls: result.modelCalls, cost: result.cost, costKind: result.costKind
          })),
          modes: (report.modes ?? []).map(({ provider, engine, levels, uncontained, sandbox, got, refused, error, verdict }) => ({
            provider, engine, levels, uncontained, sandbox, got: error ? 'error' : refused ? 'refused' : got, reason: refused?.reason ?? error ?? null, verdict
          }))
        });
      } catch {}
    }
    this.#update({ reports });
    return reports;
  }

  /** The workspace of the run on screen, for Show in Finder. */
  get workspace() {
    return this.#run?.workspace ?? null;
  }
}
