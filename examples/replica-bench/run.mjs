// One run: a fresh workspace, gateway, tool server and Agneta session, the turns sent to it, and the evidence the
// app gathers while they run. Each scenario × engine × policy is one run, so nothing one run did (a file, a running
// job, a warm cache) reaches the next. The headless runner and the window both drive this class.
import { toolchainEnvironment, toolchainFolders } from './toolchain.mjs';
import { EventEmitter } from 'node:events';
import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { describeError, refusal, settings } from './agneta.mjs';
import { modeText } from './sandbox.mjs';
import { startGateway } from './gateway.mjs';
import { findCargo, score } from './referee.mjs';
import { deadline, judge } from './scenarios.mjs';
import { startTools } from './tools.mjs';
import { createRun, listFiles, otherRuns } from './workspace.mjs';

const instructions = [
  'You are the worker agent in Replica Bench, a test bench for what agents can do.',
  'Your workspace is the current folder; README.md there explains the task, the app\'s tools and the Python probe kit.',
  'Do what each message asks, with the shell, files and the app\'s tools as needed.',
  'When something you try is refused or fails, say exactly what happened, then carry on with what you can. Keep replies short.'
].join(' ');

/**
 * The policy each run asks for: a demanding app's worker, in the sandbox mode the run asks for (`contained` or
 * `developer`, sent explicitly so the report shows what was asked; Agneta refuses more than the grant). No gateway
 * port (the modes check) means no toolPorts.
 */
export function policyFor(run, { sandbox, gatewayPort, others = [] }) {
  const policy = {
    tools: 'workspace',
    network: 'none',
    approval: 'never-ask',
    readable: [],
    writable: [],
    readOnly: run.readOnly,
    // Under developer access the home folder is readable, so other runs' workspaces are denied by name too.
    denied: sandbox === 'developer' ? [...run.denied, ...others] : run.denied,
    toolPorts: gatewayPort ? [gatewayPort] : [],
    sandbox,
    limits: { maxTurns: 400, maxSeconds: 5400 }
  };
  // The contained path gets the app's toolchain, as a demanding app supplies its own (toolchain.mjs).
  const environment = sandbox === 'developer' ? undefined : toolchainEnvironment(run.workspace);
  if (environment) {
    policy.readOnly = [...run.readOnly, ...toolchainFolders()];
    policy.toolEnvironment = environment;
  }
  return policy;
}

/**
 * Waits for background work to go quiet, as an app would before asking about it: `lastActivity()` resolves to when the
 * work last did something (ms). Busy means activity within `quietMs` of now. Resolves to {busy} when it wasn't busy at
 * the start (no wait), else {busy, quiet, waitedMs} once quiet for `quietMs`, or at `maxMs` if it never went quiet.
 * `now` and `sleep` are the clock, replaceable in tests.
 */
export async function backgroundQuiet({ lastActivity, quietMs = 10_000, maxMs = 180_000, now = Date.now, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) }) {
  const started = now();
  const busy = (at) => Number.isFinite(at) && now() - at < quietMs;
  if (!busy(await lastActivity())) return { busy: false, quiet: true, waitedMs: 0 };
  for (;;) {
    const waited = now() - started;
    if (waited >= maxMs) return { busy: true, quiet: false, waitedMs: waited };
    await sleep(Math.min(1000, maxMs - waited));
    if (!busy(await lastActivity())) return { busy: true, quiet: true, waitedMs: now() - started };
  }
}

const clip = (text, size = 8000) => typeof text !== 'string' ? '' : text.length <= size ? text : `${text.slice(0, size / 2)}\n…\n${text.slice(-size / 2)}`;
const exact = (db) => Number.isFinite(db) ? db : db < 0 ? '-inf' : null;
const asText = (value) => value === undefined || value === null ? '' : typeof value === 'string' ? value : JSON.stringify(value);

/** The text of a tool call's ACP content blocks and raw output. */
function outputOf(update) {
  const parts = [];
  for (const block of Array.isArray(update.content) ? update.content : []) {
    if (block?.content?.type === 'text') parts.push(block.content.text);
    else if (block?.type === 'diff') parts.push(`diff ${block.path ?? ''}`);
  }
  if (update.rawOutput !== undefined) parts.push(asText(update.rawOutput));
  return parts.join('\n');
}

export class BenchRun extends EventEmitter {
  #agneta;
  /** The run's session (@agneta-ai/client's Session) while it's open. */
  #session = null;
  #tools;
  #gateway;
  /** When the last live trace batch arrived: the trace trails the turn by a batch or two (every 100 ms). */
  #traceAt = 0;
  #transcriptTools = new Map();

  /**
   * @param scenario an entry of scenarios.mjs, or null for a free-form run.
   * @param choice {account, engine, sandbox, model, effort}: `sandbox` is the mode the run asks for.
   */
  constructor(agneta, home, scenario, choice) {
    super();
    this.#agneta = agneta;
    this.home = home;
    this.scenario = scenario;
    this.choice = choice;
    this.phase = 'starting';
    this.status = 'Setting up the workspace…';
    this.session = null;
    /** The session's id after it closed, for the report. */
    this.lastSession = null;
    this.workspace = null;
    this.refused = null;
    /** The sandbox mode the task got (session/new's _meta.agneta.sandbox). */
    this.got = null;
    this.error = null;
    this.config = { ids: {}, view: { models: [], model: '', efforts: [], effort: '' } };
    this.transcript = [];
    this.verdict = null;
    this.evidence = {
      started: Date.now(), ended: null,
      mcp: [], gateway: [], toolCalls: [], commands: [], permissions: [], appPermissions: 0, modelCallRecords: 0,
      reply: '', files: [], candidateBuilt: false, brief: null, scores: [], turns: []
    };
  }

  #change() {
    this.emit('change', this);
  }

  #log(line) {
    this.emit('log', line);
  }

  /**
   * Sets up the workspace, its gateway and its tool server. `start` does this and opens the session; on its own it
   * hosts a run for an agent outside Agneta (bench.mjs --host, for the plain-terminal reference).
   */
  async prepare() {
    const { engine, sandbox } = this.choice;
    const evidence = this.evidence;
    this.#gateway = await startGateway({
      hit: (hit) => {
        evidence.gateway.push(hit);
        const count = evidence.gateway.length;
        if (count === 1 || count % 25 === 0 || !hit.ok) this.#log(`gateway ${hit.op}${hit.ok ? '' : ` refused: ${hit.error}`} (${count} so far)`);
        this.#change();
      }
    });
    const label = [this.scenario?.name, engine, sandbox].filter(Boolean).join('-') || 'run';
    const run = await createRun(this.home, { label, gateway: this.#gateway });
    this.run = run;
    this.workspace = run.workspace;
    const cargo = await findCargo();
    this.#tools = await startTools({
      workspace: run.workspace,
      score: async (folder) => {
        this.#log('referee: building the candidate');
        const scored = await score({ crate: folder, cases: run.heldOut, build: run.build, unreadable: [run.denied[0]], cargo });
        evidence.scores.push({ ...scored, at: Date.now() });
        this.#log(`referee: ${scored.ok ? `${scored.rmsErrorDb.toFixed(1)} dB` : scored.message}`);
        this.#change();
        return scored;
      },
      called: (call) => {
        evidence.mcp.push(call);
        this.#log(`app tool ${call.tool}${call.ok ? '' : ' failed'}${call.summary ? `: ${call.summary}` : ''}`);
        this.#change();
      }
    });
    const others = sandbox === 'developer' ? await otherRuns(this.home, run.workspace) : [];
    this.policy = policyFor(run, { sandbox, gatewayPort: this.#gateway.port, others });
    return { run, tools: this.#tools.registration, gateway: this.#gateway };
  }

  /** Sets up the run and opens its session. A refused session leaves the run `refused`. */
  async start() {
    const { account, engine } = this.choice;
    const evidence = this.evidence;
    const { run } = await this.prepare();
    this.status = 'Opening the session…';
    this.#change();
    let session;
    try {
      session = await this.#agneta.newSession({
        cwd: run.workspace,
        account,
        engine: engine || undefined,
        mcpServers: [this.#tools.registration],
        policy: this.policy,
        instructions,
        task: { title: `${this.scenario?.title ?? 'Free run'} · Replica Bench`, stopWarning: 'Replica Bench keeps the workspace and the scores so far.' },
        trace: true,
        // Attached before the session is returned: live trace records can arrive before session/new answers.
        on: {
          update: (update) => this.#update(update),
          trace: (records) => this.#trace(records),
          queued: (position) => {
            this.status = `Waiting for room · position ${position}`;
            this.#change();
          },
          ended: (end) => this.#ended(end)
        },
        // Sessions use approval never-ask: a request that still arrives is declined, and counted.
        permissions: () => {
          evidence.appPermissions += 1;
          return 'cancel';
        },
        onDownloadProgress: (downloading) => {
          const share = downloading.total ? ` ${Math.round(100 * downloading.received / downloading.total)}%` : '';
          this.status = `Agneta is getting ${downloading.engine ?? 'the engine'} ready…${share}`;
          this.#change();
        }
      });
    } catch (error) {
      this.refused = refusal(error);
      if (!this.refused) this.error = describeError(error);
      this.status = this.refused ? `Agneta refused the session (${this.refused.fields.join(', ') || 'session/new'}): ${this.refused.reason}` : this.error;
      if (this.refused) this.transcript.push({ role: 'refusal', text: this.status });
      this.phase = 'ended';
      this.#log(this.status);
      await this.close();
      return false;
    }
    this.attach(session);
    this.config = settings(session.configOptions);
    const { model, effort } = this.choice;
    if (model || effort) await this.configure({ model, effort });
    this.phase = 'ready';
    this.status = 'Ready';
    this.#log(`session ${this.session} on ${this.capabilities?.engine ?? engine ?? 'the default engine'}, ${modeText(this.record())}, in ${run.workspace}`);
    this.#change();
    return true;
  }

  /** Takes an open session as the run's (`start` does; tests give one of their own). */
  attach(session) {
    this.#session = session;
    this.session = session.id;
    this.capabilities = session.capabilities ?? null;
    // What the task really got, which may differ from what was asked only if Agneta and its access report disagree.
    this.got = session.sandbox ?? null;
    this.phase = 'ready';
  }

  /** Sets the model or effort between turns, where the engine offers them (session/set_config_option). */
  async configure({ model, effort } = {}) {
    for (const [key, value] of [['model', model], ['effort', effort]]) {
      const id = this.config.ids[key];
      if (!value || !id || value === this.config.view[key]) continue;
      const offered = this.config.view[key === 'model' ? 'models' : 'efforts'].some((entry) => entry.value === value);
      if (!offered) {
        this.#log(`${key} ${value} isn't offered by this engine; keeping ${this.config.view[key] || 'its default'}`);
        continue;
      }
      try {
        this.config = settings(await this.#session.setConfigOption(id, value));
      } catch (error) {
        this.#log(`couldn't set the ${key}: ${describeError(error)}`);
      }
    }
    this.#change();
  }

  /** One turn. The run's own deadline cancels it (the clone's 20 minutes); Agneta's limits stay as a backstop. */
  async prompt(text, { ms = this.scenario ? deadline(this.scenario) : 30 * 60_000 } = {}) {
    if (this.phase !== 'ready') return null;
    const turn = { prompt: text, started: Date.now(), ended: null, stopReason: null, usage: null, limit: null, error: null, deadline: false };
    this.evidence.turns.push(turn);
    this.transcript.push({ role: 'user', text });
    this.phase = 'running';
    this.status = 'Waiting for the agent…';
    this.#change();
    const timer = setTimeout(() => {
      turn.deadline = true;
      this.#log(`deadline of ${Math.round(ms / 60_000)} min: stopping the turn`);
      this.cancel();
    }, ms);
    try {
      // The reply streams through the session's events (#update); the result says how the turn ended.
      const result = await this.#session.prompt(text, { timeout: ms + 180_000 });
      turn.stopReason = result?.stopReason ?? null;
      turn.usage = result?.usage ?? null;
      turn.limit = result?.limit ?? null;
    } catch (error) {
      turn.error = describeError(error);
    } finally {
      clearTimeout(timer);
    }
    turn.ended = Date.now();
    if (this.session) {
      this.phase = 'ready';
      this.status = turn.error ? turn.error
        : turn.deadline ? 'Stopped at the scenario\'s time limit.'
        : turn.limit ? `Stopped at Agneta's ${turn.limit.limit} limit.`
        : turn.stopReason === 'cancelled' ? 'Turn stopped.'
        : 'Ready';
    }
    const calls = turn.usage?.modelCalls;
    this.#log(`turn ended: ${turn.error ?? turn.stopReason ?? 'no stop reason'} after ${((turn.ended - turn.started) / 1000).toFixed(0)} s${Number.isInteger(calls) ? `, ${calls} model calls` : ''}`);
    this.#change();
    return turn;
  }

  /**
   * The scenario's follow-up, as a real app would send it. `background-quiet`: when the first turn ended while the
   * run's background work was still going (gateway calls, or its output files growing), wait until it goes quiet
   * (bounded), then send the follow-up prompt in the same session, once. Resolves to what happened, or null.
   */
  async followUp({ now, sleep } = {}) {
    const rule = this.scenario?.followUp;
    if (!rule || rule.when !== 'background-quiet' || this.phase !== 'ready' || this.evidence.followUp) return null;
    const lastActivity = async () => {
      const times = this.evidence.gateway.map(({ at }) => at);
      for (const path of rule.files ?? []) {
        const info = await stat(join(this.workspace, path)).catch(() => null);
        if (info) times.push(info.mtimeMs);
      }
      return times.length ? Math.max(...times) : NaN;
    };
    const quietMs = (rule.quietSeconds ?? 10) * 1000, maxMs = (rule.maxSeconds ?? 180) * 1000;
    const busyAtEnd = await backgroundQuiet({ lastActivity, quietMs, maxMs: 0, now });
    if (!busyAtEnd.busy) return null;
    this.#log(`background work still running after the turn: waiting up to ${rule.maxSeconds ?? 180} s for it to go quiet`);
    this.status = 'Waiting for the background work to finish…';
    this.#change();
    const waited = await backgroundQuiet({ lastActivity, quietMs, maxMs, now, sleep });
    this.evidence.followUp = { waitedMs: waited.waitedMs, quiet: waited.quiet };
    this.#log(waited.quiet ? `background work quiet after ${Math.round(waited.waitedMs / 1000)} s: sending the follow-up` : `background work still busy after ${Math.round(waited.waitedMs / 1000)} s: sending the follow-up anyway`);
    const turn = await this.prompt(rule.prompt);
    if (turn) turn.followUp = true;
    return { ...this.evidence.followUp, turn };
  }

  cancel() {
    if (this.phase !== 'running' || !this.session) return;
    this.#session?.cancel();
    this.status = 'Stopping…';
    this.#change();
  }

  /** Reads what the workspace holds now and judges the scenario (when the run has one). */
  async evaluate() {
    const evidence = this.evidence;
    // Let the trace's last batches (the final commands' records) arrive first: quiet for 500 ms, at most 5 s.
    for (const waited = Date.now(); this.session && Date.now() - waited < 5000 && Date.now() - Math.max(this.#traceAt, waited) < 500; ) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    evidence.ended = Date.now();
    if (this.workspace) {
      evidence.files = await listFiles(this.workspace);
      evidence.candidateBuilt = false;
      for (const profile of ['release', 'debug']) {
        const built = await stat(join(this.workspace, 'candidate', 'target', profile, 'candidate')).catch(() => null);
        if (built && built.mtimeMs > evidence.started) evidence.candidateBuilt = true;
      }
      evidence.brief = await readFile(join(this.workspace, 'brief.md'), 'utf8').then((text) => text.slice(0, 65536), () => null);
    }
    if (this.scenario && !this.refused && !this.error) this.verdict = await judge(this.scenario, evidence, { engine: this.capabilities?.engine ?? this.choice.engine, sandbox: this.choice.sandbox });
    this.#change();
    return this.verdict;
  }

  /** Keeps Agneta's explanation visible after the outstanding prompt settles. */
  #ended(end) {
    if (end.reason !== 'stopped') return;
    this.#log(`session stopped by ${end.stoppedBy}`);
    this.lastSession = this.session;
    this.session = null;
    this.#session = null;
    this.phase = 'ended';
    const reason = {
      user: 'Stopped in Agneta.', limit: 'Stopped at its limit.', engine: 'The engine stopped.',
      reach: 'A tool socket or port is no longer reachable.'
    }[end.stoppedBy] ?? 'The session stopped.';
    this.status = end.detail ? `${reason} ${end.detail}` : reason;
    this.#change();
  }

  /** Live trace records: the commands the broker ran, the permission decisions, the model calls. */
  #trace(records) {
    const evidence = this.evidence;
    this.#traceAt = Date.now();
    for (const record of records) {
      const at = Date.parse(record.t) || Date.now();
      if (record.type === 'shell') {
        evidence.commands.push({ command: record.command, exit: record.exit ?? null, signal: record.signal ?? null, refused: record.refused ?? null, at, output: record.stderrTail ?? '' });
        if (record.refused) this.#log(`command refused: ${record.refused}`);
      } else if (record.type === 'permission') {
        evidence.permissions.push({ decision: record.decision, kind: record.toolKind, title: record.title, at });
        if (record.decision === 'refused-by-policy') this.#log(`refused by policy: ${record.toolKind ?? ''} ${asText(record.title).slice(0, 80)}`);
      } else if (record.type === 'event' && record.kind === 'model-call') {
        evidence.modelCallRecords += 1;
      }
    }
  }

  /** A session update: the reply as it streams, and each tool call as it goes. */
  #update(update) {
    const evidence = this.evidence;
    if (update.sessionUpdate === 'agent_message_chunk' && typeof update.content?.text === 'string') {
      evidence.reply += update.content.text;
      const last = this.transcript.at(-1);
      if (last?.role === 'assistant') last.text += update.content.text; else this.transcript.push({ role: 'assistant', text: update.content.text });
      this.status = 'Receiving the reply…';
      this.#change();
    } else if (update.sessionUpdate === 'tool_call' || update.sessionUpdate === 'tool_call_update') {
      const id = update.toolCallId;
      let call = evidence.toolCalls.find((entry) => entry.id === id);
      if (!call) {
        call = { id, title: '', kind: null, status: 'pending', started: Date.now(), ended: null, input: '', output: '' };
        evidence.toolCalls.push(call);
      }
      if (typeof update.title === 'string' && update.title) call.title = update.title;
      if (typeof update.kind === 'string') call.kind = update.kind;
      if (update.rawInput !== undefined) call.input = clip(asText(update.rawInput), 4000);
      const output = outputOf(update);
      if (output) call.output = clip(output);
      // Codex streams a command's output as terminal deltas in _meta (ACP's terminal metadata), with its exit code at
      // the end: appended, since each update carries only the new part.
      const terminal = update._meta?.terminal_output_delta?.data ?? update._meta?.terminal_output?.data;
      if (typeof terminal === 'string' && terminal) call.output = clip((call.output ? `${call.output}` : '') + terminal);
      const exit = update._meta?.terminal_exit?.exit_code;
      if (Number.isInteger(exit)) call.exitCode = exit;
      if (typeof update.status === 'string' && update.status !== call.status) {
        call.status = update.status;
        if (['completed', 'failed'].includes(call.status)) {
          call.ended = Date.now();
          this.#log(`${call.status === 'failed' ? 'failed' : 'done'}: ${call.title || call.kind || 'tool'}`.slice(0, 160));
        }
      }
      let row = this.#transcriptTools.get(id);
      if (!row) {
        row = { role: 'tool', id };
        this.#transcriptTools.set(id, row);
        this.transcript.push(row);
      }
      Object.assign(row, { title: call.title || call.kind || 'Tool call', status: call.status, kind: call.kind });
      this.#change();
    }
  }

  /** What the report keeps of this run. */
  record() {
    const evidence = this.evidence;
    const turns = evidence.turns;
    const sum = (key) => turns.reduce((total, turn) => total + (Number.isFinite(turn.usage?.[key]) ? turn.usage[key] : 0), 0);
    const known = (key) => turns.some((turn) => Number.isFinite(turn.usage?.[key]));
    const okScores = evidence.scores.filter((scored) => scored.ok);
    const refusals = [
      ...evidence.permissions.filter(({ decision }) => decision === 'refused-by-policy').map(({ kind, title }) => ({ what: kind ?? 'tool', why: asText(title).slice(0, 120) })),
      ...evidence.commands.filter(({ refused }) => refused).map(({ command, refused }) => ({ what: 'command', why: `${refused}: ${asText(command).slice(0, 80)}` }))
    ];
    return {
      scenario: this.scenario?.name ?? null,
      title: this.scenario?.title ?? 'Free run',
      account: this.choice.account,
      engine: this.capabilities?.engine ?? this.choice.engine ?? null,
      sandbox: this.choice.sandbox,
      got: this.got,
      model: this.config.view.model || null,
      effort: this.config.view.effort || null,
      session: this.session ?? this.lastSession ?? null,
      workspace: this.workspace,
      policy: this.policy ?? null,
      outcome: this.refused ? 'refused' : this.error ? 'error' : this.verdict?.outcome ?? null,
      achieved: this.verdict?.achieved ?? null,
      attempted: this.verdict?.attempted ?? null,
      expected: this.verdict?.expected ?? null,
      checks: this.verdict?.verdicts ?? [],
      refused: this.refused,
      error: this.error ?? turns.find((turn) => turn.error)?.error ?? null,
      ms: (evidence.ended ?? Date.now()) - evidence.started,
      turnMs: turns.reduce((total, turn) => total + ((turn.ended ?? Date.now()) - turn.started), 0),
      stopReasons: turns.map((turn) => turn.deadline ? 'deadline' : turn.limit?.limit ?? turn.stopReason ?? (turn.error ? 'error' : null)),
      modelCalls: known('modelCalls') ? sum('modelCalls') : evidence.modelCallRecords || null,
      cost: known('cost') ? sum('cost') : null,
      costKind: turns.find((turn) => turn.usage?.costKind)?.usage.costKind ?? null,
      tokens: known('inputTokens') ? { input: sum('inputTokens'), output: sum('outputTokens') } : null,
      toolCalls: evidence.toolCalls.length,
      failedToolCalls: evidence.toolCalls.filter(({ status }) => status === 'failed').length,
      mcpCalls: evidence.mcp.length,
      gatewayHits: evidence.gateway.filter(({ ok }) => ok).length,
      commands: evidence.commands.length,
      refusals,
      permissionsAsked: evidence.appPermissions,
      // An exact clone scores -Infinity, which JSON can't carry.
      bestScoreDb: okScores.length ? exact(Math.min(...okScores.map(({ rmsErrorDb }) => rmsErrorDb))) : null,
      scores: evidence.scores.length,
      // The scenario's follow-up turn, when its background work outlived the first turn: how long the bench waited.
      followUp: evidence.followUp ?? null
    };
  }

  /** Ends the session and stops the run's servers. The workspace stays, for a person to look at. */
  async close() {
    const session = this.session;
    if (session) {
      this.lastSession = session;
      this.session = null;
      await this.#session?.close({ timeout: 10_000 }).catch(() => {});
      this.#session = null;
    }
    this.#tools?.close();
    this.#gateway?.close();
    if (this.phase !== 'ended') {
      this.phase = 'ended';
      this.#change();
    }
  }
}
