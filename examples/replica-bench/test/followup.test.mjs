// The background-quiet follow-up, on a fake clock: no follow-up when nothing is running at the turn's end; a wait
// until the work is quiet (or the bound), then exactly one more turn in the same session with the scenario's prompt.
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { BenchRun, backgroundQuiet } from '../run.mjs';
import { scenario } from '../scenarios.mjs';

/** A clock that only moves when the code under test sleeps. */
function fakeClock(start = 1_000_000) {
  let time = start;
  const slept = [];
  return { now: () => time, sleep: async (ms) => { slept.push(ms); time += ms; }, slept, advance: (ms) => { time += ms; } };
}

test('backgroundQuiet: not busy means no wait; busy waits until quiet, or until the bound', async () => {
  const clock = fakeClock();
  // Last active 30 s ago: quiet already.
  assert.deepEqual(await backgroundQuiet({ lastActivity: async () => clock.now() - 30_000, ...clock }), { busy: false, quiet: true, waitedMs: 0 });
  assert.deepEqual(await backgroundQuiet({ lastActivity: async () => NaN, ...clock }), { busy: false, quiet: true, waitedMs: 0 });
  assert.equal(clock.slept.length, 0);

  // Active until 20 s from now (a gateway call each second), then silent: quiet 10 s after that.
  const stops = clock.now() + 20_000;
  const working = async () => Math.min(clock.now(), stops);
  const done = await backgroundQuiet({ lastActivity: working, quietMs: 10_000, maxMs: 180_000, ...clock });
  assert.deepEqual(done, { busy: true, quiet: true, waitedMs: 30_000 });

  // Never quiet: bounded at maxMs.
  const forever = await backgroundQuiet({ lastActivity: async () => clock.now(), quietMs: 10_000, maxMs: 180_000, ...clock });
  assert.deepEqual(forever, { busy: true, quiet: false, waitedMs: 180_000 });
});

/** A run of the background-job scenario with a fake Agneta that answers each prompt and records it. */
async function fakeRun(t) {
  const workspace = await mkdtemp(join(tmpdir(), 'replica-bench-followup-'));
  t.after(() => rm(workspace, { recursive: true, force: true }));
  await mkdir(join(workspace, 'probes'));
  const prompts = [];
  const agneta = {
    request: async (method, params) => {
      assert.equal(method, 'session/prompt');
      prompts.push({ session: params.sessionId, text: params.prompt[0].text });
      return { stopReason: 'end_turn', _meta: { 'agneta/usage': { modelCalls: 1 } } };
    },
    notify() {}
  };
  const run = new BenchRun(agneta, workspace, scenario('background-job'), { account: 'a', engine: 'codex', sandbox: 'contained' });
  run.workspace = workspace;
  run.session = 's1';
  run.phase = 'ready';
  return { run, prompts, workspace };
}

test('a turn that ends while the sweep still calls the gateway gets one follow-up once it goes quiet', async (t) => {
  const { run, prompts } = await fakeRun(t);
  const clock = fakeClock(Date.now());
  const lines = [];
  run.on('log', (line) => lines.push(line));
  await run.prompt(scenario('background-job').prompt());
  // The sweep keeps calling the gateway for another 25 s after the turn ended.
  const stops = clock.now() + 25_000;
  const original = clock.sleep;
  clock.sleep = async (ms) => {
    await original(ms);
    if (clock.now() <= stops) run.evidence.gateway.push({ at: clock.now(), op: 'evaluate', ok: true });
  };
  run.evidence.gateway.push({ at: clock.now(), op: 'evaluate', ok: true });

  const result = await run.followUp(clock);
  assert.equal(result.quiet, true);
  assert.equal(result.waitedMs, 35_000);
  assert.deepEqual(prompts.map(({ session }) => session), ['s1', 's1']);
  assert.equal(prompts[1].text, 'Your background sweep has finished. Read its output now and report what it shows.');
  assert.equal(run.evidence.turns.length, 2);
  assert.equal(run.evidence.turns[1].followUp, true);
  assert.deepEqual(run.record().followUp, { waitedMs: 35_000, quiet: true });
  assert.match(lines.join('\n'), /background work still running after the turn[\s\S]*quiet after 35 s: sending the follow-up/);
  // Once only.
  assert.equal(await run.followUp(clock), null);
  assert.equal(prompts.length, 2);
});

test('a growing output file also counts as running work', async (t) => {
  const { run, prompts, workspace } = await fakeRun(t);
  const log = join(workspace, 'probes', 'sweep.log');
  await writeFile(log, '{"step": 1}\n');
  const clock = fakeClock(Date.now());
  // No gateway calls at all; the file was written just now, then never again.
  const result = await run.followUp(clock);
  assert.equal(result.quiet, true);
  assert.ok(result.waitedMs >= 10_000 && result.waitedMs <= 11_000, `${result.waitedMs}`);
  assert.equal(prompts.length, 1);
});

test('no follow-up when the work finished within the turn, or for scenarios without one', async (t) => {
  const { run, prompts } = await fakeRun(t);
  const clock = fakeClock(Date.now());
  run.evidence.gateway.push({ at: clock.now() - 60_000, op: 'evaluate', ok: true });
  assert.equal(await run.followUp(clock), null);
  assert.equal(clock.slept.length, 0);
  run.scenario = scenario('python-probe');
  run.evidence.gateway.push({ at: clock.now(), op: 'evaluate', ok: true });
  assert.equal(await run.followUp(clock), null);
  assert.equal(prompts.length, 0);
  assert.equal(run.record().followUp, null);
});

test('a session that is gone gets no follow-up', async (t) => {
  const { run, prompts } = await fakeRun(t);
  const clock = fakeClock(Date.now());
  run.evidence.gateway.push({ at: clock.now(), op: 'evaluate', ok: true });
  run.phase = 'ended';
  assert.equal(await run.followUp(clock), null);
  assert.equal(prompts.length, 0);
});
