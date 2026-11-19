// The bench against a real headless Agneta (agnetad) running Goose on a fake model, as Project Chat's smoke test
// does: its own temporary AGNETA_HOME and bench folder, ports in 47900–47999 (Agneta's own Swift tests use 474xx and 476xx), nothing of the user's touched. The
// fake model makes one tool call per prompt ("CALL <tool> <json>"), so this proves the wire path, not an agent:
// connect → pair → session/new with each sandbox mode → a tool call through the app's MCP server and one through the
// shell and the probe gateway → the modes check → the report written. Twice: under agnetad's default grant
// (developer: both modes open as asked), and with agnetad --sandbox contained (developer refused, with the reason).
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { constants } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { Agneta } from '../agneta.mjs';
import { plan, runMatrix } from '../bench.mjs';
import { checkModes } from '../modes.mjs';
import { writeReport } from '../report.mjs';

const repo = fileURLToPath(new URL('../../../', import.meta.url));

/** A free port in 47900–47999: never Agneta's own (47321, 47331), its Swift tests' (474xx, 476xx) or the user's apps'. */
async function portInRange(skip = []) {
  for (let port = 47900 + Math.floor(Math.random() * 50); port < 48000; port++) {
    if (skip.includes(port)) continue;
    const listener = createServer();
    const free = await new Promise((resolve) => {
      listener.once('error', () => resolve(false));
      listener.listen(port, '127.0.0.1', () => resolve(true));
    });
    if (free) {
      await new Promise((resolve) => listener.close(resolve));
      return port;
    }
  }
  throw new Error('No free port in 47900–47999.');
}

/** Starts a process in its own group, so stopping it stops whatever it started. */
function start(command, args) {
  const child = spawn(command, args, { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  let output = '';
  for (const stream of [child.stdout, child.stderr]) {
    stream.setEncoding('utf8');
    stream.on('data', (text) => { output = (output + text).slice(-20000); });
  }
  let stopped = false;
  child.on('error', (error) => { output += error.message; });
  const exited = new Promise((resolve) => child.once('close', () => { stopped = true; resolve(); }));
  const signal = (name) => { try { process.kill(-child.pid, name); } catch {} };
  return {
    pid: child.pid,
    get output() { return output; },
    get stopped() { return stopped; },
    async stop() {
      if (stopped) return;
      signal('SIGTERM');
      const watchdog = setTimeout(() => signal('SIGKILL'), 5000);
      try { await exited; } finally { clearTimeout(watchdog); }
    }
  };
}

async function waitFor(condition, description, process) {
  for (let attempt = 0; attempt < 100 && !process.stopped; attempt++) {
    if (await condition()) return;
    await delay(100);
  }
  assert.fail(`${description}\n${process.output}`);
}

/**
 * A fake model and agnetad (with `--sandbox` when given) in a temporary root, and the bench connected to it. Everything
 * started is stopped, by process group, when the test ends.
 */
async function bench(t, { sandbox } = {}) {
  const hostBinary = join(repo, '.build/debug/agnetad');
  const fakes = join(repo, '.build/debug/agneta-fakes');
  const goose = join(repo, 'Engines', 'bin', process.arch === 'arm64' ? 'arm64' : 'x86_64', 'goose-acp');
  await access(hostBinary, constants.X_OK).catch(() => assert.fail('Run swift build --product agnetad at the repository root.'));
  await access(fakes, constants.X_OK).catch(() => assert.fail('Run swift build --product agneta-fakes at the repository root.'));
  await access(goose, constants.X_OK).catch(() => assert.fail('Run scripts/fetch-engines at the repository root.'));

  const root = await mkdtemp(join(tmpdir(), 'replica-bench-'));
  const home = join(root, 'bench');
  await mkdir(home);
  const children = [];
  const agneta = { current: null };
  t.after(async () => {
    agneta.current?.close();
    for (const child of children.reverse()) await child.stop();
    await rm(root, { recursive: true, force: true });
  });

  const modelPort = await portInRange();
  const modelURL = `http://127.0.0.1:${modelPort}/v1`;
  const model = start(fakes, ['model', String(modelPort), join(root, 'model.jsonl')]);
  children.push(model);
  await waitFor(() => fetch(`${modelURL}/models`, { signal: AbortSignal.timeout(1000) }).then((res) => res.ok, () => false), 'The fake model did not start.', model);

  const port = await portInRange([modelPort]);
  const host = start(hostBinary, ['--goose', goose, '--home', join(root, 'host'), '--port', String(port), ...(sandbox ? ['--sandbox', sandbox] : []),
    '--env', 'GOOSE_MODEL=gpt-4o', '--env', 'OPENAI_API_KEY=fake', '--env', `OPENAI_BASE_URL=${modelURL}`]);
  children.push(host);
  await waitFor(() => host.output.includes('listening on'), 'agnetad did not start.', host);

  agneta.current = new Agneta(port, { home });
  await agneta.current.connect();
  return { agneta: agneta.current, home, root, port, host };
}

const python = 'import sys; sys.path.insert(0, "kit"); import rb; print(rb.evaluate([1.0, 1.0, 1.0], {"time": 2}))';
const prompts = {
  'app-tools': 'CALL bench__describe_target {}',
  'python-probe': `CALL shell ${JSON.stringify({ command: `python3 -c ${JSON.stringify(python)}` })}`
};

test('under the default grant both modes open as asked, the tools and gateway work, and the modes check agrees', { timeout: 180_000 }, async (t) => {
  const { agneta, home, root, port } = await bench(t);
  assert.deepEqual(agneta.providers().map(({ id }) => id), ['dev']);
  // agnetad's default pairing answer is the protocol's default: developer.
  assert.equal(agneta.grant, 'developer');
  const goose = agneta.providers()[0].engines.find(({ id }) => id === 'goose');
  assert.deepEqual(goose.levels, ['contained', 'developer']);
  assert.equal(goose.uncontained, false);

  const lines = [];
  const runs = [
    ...plan(agneta, { scenario: 'app-tools', engine: 'goose', sandbox: 'both' }),
    ...plan(agneta, { scenario: 'python-probe', engine: 'goose', sandbox: 'contained' })
  ];
  const results = await runMatrix(agneta, home, runs, { prompts, log: (line) => lines.push(line) });
  const log = lines.join('\n');
  assert.equal(results.length, 3, log);
  const [contained, developer, probe] = results;

  // Asked and got: each mode sent explicitly, and the reply says the task got it.
  assert.deepEqual([contained.sandbox, contained.got, contained.policy.sandbox], ['contained', 'contained', 'contained']);
  assert.deepEqual([developer.sandbox, developer.got, developer.policy.sandbox], ['developer', 'developer', 'developer']);
  assert.ok(!('access' in contained.policy) && !('access' in developer.policy));
  assert.match(log, /asked contained, got contained/);
  assert.match(log, /asked developer, got developer/);

  for (const run of [contained, developer]) {
    assert.equal(run.engine, 'goose');
    assert.ok(run.session, log);
    assert.equal(run.refused, null);
    assert.equal(run.policy.approval, 'never-ask');
    assert.deepEqual(run.policy.limits, { maxTurns: 400, maxSeconds: 5400 });
    assert.equal(run.policy.toolPorts.length, 1);
    assert.equal(run.mcpCalls, 1, log);
    assert.deepEqual(run.checks.map(({ name, ok }) => [name, ok]), [['described the target', true], ['evaluated the target', false], ['got a plot back', false]]);
    assert.equal(run.outcome, 'unexpected', 'one CALL can\'t evaluate and plot as well');
    assert.ok(run.modelCalls >= 1, log);
  }
  assert.ok(contained.policy.denied.length === 2 && contained.policy.denied.every((path) => !path.startsWith(contained.workspace)));
  // Developer sessions also deny the runs before them (the contained run's workspace).
  assert.ok(developer.policy.denied.includes(contained.workspace), log);

  // Contained: the shell (Goose through Agneta's broker) ran the kit, which reached the gateway on toolPorts.
  assert.equal(probe.got, 'contained');
  assert.ok(probe.toolCalls >= 1, log);
  assert.equal(probe.commands, 1, log);
  assert.ok(probe.gatewayHits >= 1, `The probe never reached the gateway.\n${log}`);

  // The modes check: Goose on an API key provides both, and gives each as asked.
  const modes = await checkModes(agneta, home);
  assert.deepEqual(modes.map(({ engine, sandbox, got, refused, verdict }) => [engine, sandbox, got, refused, verdict]), [
    ['goose', 'contained', 'contained', null, 'as declared'],
    ['goose', 'developer', 'developer', null, 'as declared']
  ]);

  const paths = await writeReport(join(root, 'results'), { results, modes, meta: { agneta: `agnetad (port ${port})`, home, grant: agneta.grant } });
  const report = await readFile(paths.md, 'utf8');
  assert.match(report, /^# Replica Bench report\n\nModes: 2 of 2 sessions got what Agneta declared \(2 opened, 0 refused\)\./);
  assert.match(report, /This app's grant is \*\*developer\*\*/);
  assert.match(report, /\| Development account \| goose \| contained, developer \| contained \| contained \| yes \|/);
  assert.match(report, /\| goose · gpt-4o \| contained \| contained \| \*\*unexpected\*\*: failed \|/);
  assert.match(report, /\| goose · gpt-4o \| developer \| developer \|/);
  const json = JSON.parse(await readFile(paths.json, 'utf8'));
  assert.equal(json.results.length, 3);
  assert.equal(json.modes.length, 2);
  assert.equal(json.grant, 'developer');
  t.diagnostic(report.split('\n')[2]);
});

test('under a contained grant developer is refused with Agneta\'s reason, and contained still works', { timeout: 180_000 }, async (t) => {
  const { agneta, home, root, port } = await bench(t, { sandbox: 'contained' });
  assert.equal(agneta.grant, 'contained');

  const lines = [];
  const results = await runMatrix(agneta, home, plan(agneta, { scenario: 'app-tools', engine: 'goose', sandbox: 'both' }), { prompts, log: (line) => lines.push(line) });
  const log = lines.join('\n');
  const [contained, developer] = results;
  assert.deepEqual([contained.sandbox, contained.got, contained.mcpCalls], ['contained', 'contained', 1], log);

  // Asking above the grant: refused before any engine starts, the field and Agneta's reason kept.
  assert.equal(developer.outcome, 'refused', log);
  assert.equal(developer.got, null);
  assert.equal(developer.session, null);
  assert.deepEqual(developer.refused.fields, ['sandbox']);
  assert.equal(developer.refused.code, -32602);
  assert.match(developer.refused.reason, /contained/);
  assert.match(log, /Agneta refused the session \(sandbox\): the user keeps this app's tasks contained/);
  assert.equal(developer.mcpCalls, 0);

  const modes = await checkModes(agneta, home);
  assert.deepEqual(modes.map(({ sandbox, got, verdict }) => [sandbox, got, verdict]), [['contained', 'contained', 'as declared'], ['developer', null, 'as declared']]);
  assert.equal(modes[1].expected.why, 'the user granted this app contained only');
  assert.equal(modes[1].refused.reason, developer.refused.reason);

  const paths = await writeReport(join(root, 'results'), { results, modes, meta: { agneta: `agnetad (port ${port})`, home, grant: agneta.grant } });
  const report = await readFile(paths.md, 'utf8');
  assert.match(report, /This app's grant is \*\*contained\*\*\. The session's folders only/);
  assert.match(report, /\| goose \| developer \| refused \| refused by Agneta \(sandbox\) \|/);
  assert.ok(report.includes(`- goose asked developer: ${developer.refused.reason}`), report);
  assert.ok(report.includes(`| developer | refused | yes | ${developer.refused.reason} |`), report);
  t.diagnostic(`refused with: ${developer.refused.reason}`);
});
