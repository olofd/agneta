import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { expectation, judge, scenario, scenarios, secretProbes } from '../scenarios.mjs';

const evidence = (fields = {}) => ({
  started: 1000, ended: 2000, mcp: [], gateway: [], toolCalls: [], commands: [], permissions: [], appPermissions: 0,
  reply: '', files: [], candidateBuilt: false, brief: null, scores: [], turns: [], ...fields
});

test('every scenario has a prompt, checks and an expectation under both policies', () => {
  assert.deepEqual(scenarios.map(({ name }) => name), ['explore', 'app-tools', 'python-probe', 'rust-build', 'background-job', 'network', 'secrets', 'web-research', 'clone']);
  for (const entry of scenarios) {
    assert.ok(entry.prompt({ home: '/Users/someone' }).length > 40, entry.name);
    for (const sandbox of ['contained', 'developer']) assert.ok(['pass', 'fail'].includes(expectation(entry, 'goose', sandbox).outcome));
  }
});

test('expectations say what passes and why a gap fails, per engine', () => {
  // Claude Code's Bash and Codex's MCP shell run on the contained path now: probes are expected everywhere.
  for (const engine of ['goose', 'opencode', 'claude-code', 'codex']) {
    assert.deepEqual(expectation(scenario('python-probe'), engine, 'contained'), { outcome: 'pass', why: null, boundary: false });
  }
  // The contained path builds with the toolchain the bench supplies.
  assert.deepEqual(expectation(scenario('rust-build'), 'goose', 'contained'), { outcome: 'pass', why: null, boundary: false });
  // Background jobs live on until the session's engine ends, in both modes, on every engine.
  for (const engine of ['goose', 'opencode', 'claude-code', 'codex']) for (const sandbox of ['contained', 'developer']) {
    assert.deepEqual(expectation(scenario('background-job'), engine, sandbox), { outcome: 'pass', why: null, boundary: false });
  }
  assert.equal(expectation(scenario('network'), 'opencode', 'developer').outcome, 'pass');
  assert.equal(expectation(scenario('network'), 'codex', 'contained').boundary, true);
  assert.equal(expectation(scenario('secrets'), 'claude-code', 'developer').boundary, true);
  assert.equal(expectation(scenario('web-research'), 'codex', 'contained').boundary, false);
  assert.equal(expectation(scenario('network'), 'opencode', 'contained').boundary, true);
  assert.equal(expectation(scenario('secrets'), 'claude-code', 'developer').outcome, 'fail');
});

test('the verdict separates pass, expected failure, unexpected and not exercised', async () => {
  const tools = scenario('app-tools');
  const all = evidence({ mcp: ['describe_target', 'evaluate', 'plot_residual'].map((tool) => ({ tool, ok: true })) });
  assert.equal((await judge(tools, all, { engine: 'goose', sandbox: 'contained' })).outcome, 'pass');
  const some = evidence({ mcp: [{ tool: 'describe_target', ok: true }] });
  assert.equal((await judge(tools, some, { engine: 'goose', sandbox: 'contained' })).outcome, 'unexpected');
  assert.equal((await judge(tools, evidence(), { engine: 'goose', sandbox: 'contained' })).outcome, 'not exercised');

  const network = scenario('network');
  const tried = evidence({ toolCalls: [{ id: 'c1', title: 'curl -sI https://github.com', status: 'completed', started: 1500, output: 'curl: (6) Could not resolve host' }] });
  assert.equal((await judge(network, tried, { engine: 'goose', sandbox: 'contained' })).outcome, 'expected-fail');
  assert.equal((await judge(network, tried, { engine: 'goose', sandbox: 'developer' })).outcome, 'unexpected');
  const reached = evidence({ toolCalls: [{ ...tried.toolCalls[0], output: 'HTTP/2 200\ncontent-type: text/html' }] });
  const verdict = await judge(network, reached, { engine: 'goose', sandbox: 'developer' });
  assert.equal(verdict.outcome, 'pass');
  assert.equal(verdict.achieved, true);
});

test('background work counts only when the job outlived its command and was read later', async () => {
  const job = scenario('background-job');
  const hits = Array.from({ length: 70 }, (_, n) => ({ at: 10_000 + n * 1000, ok: true }));
  const calls = [
    { id: 'a', title: 'nohup python3 probes/sweep.py &', started: 9000, status: 'completed' },
    { id: 'b', title: 'cat candidate/src/lib.rs', started: 20_000, status: 'completed' },
    { id: 'c', title: 'wc -l probes/sweep.log', started: 85_000, status: 'completed' }
  ];
  assert.equal((await judge(job, evidence({ gateway: hits, toolCalls: calls }), { engine: 'goose', sandbox: 'developer' })).outcome, 'pass');
  // Killed when its shell exited (a second of gateway calls) is now a failure nobody expects.
  const killed = await judge(job, evidence({ gateway: hits.slice(0, 1), toolCalls: calls }), { engine: 'goose', sandbox: 'contained' });
  assert.deepEqual([killed.outcome, killed.achieved], ['unexpected', false]);
  // The agent ended its turn while the sweep ran, and read the log only in the follow-up turn: that counts.
  const followed = calls.slice(0, 2).concat({ id: 'd', title: 'cat probes/sweep.log', started: 95_000, status: 'completed' });
  assert.equal((await judge(job, evidence({ gateway: hits, toolCalls: followed }), { engine: 'codex', sandbox: 'contained' })).outcome, 'pass');
  assert.equal(job.followUp.when, 'background-quiet');
  assert.deepEqual(job.followUp.files, ['probes/sweep.log', 'probes/sweep.out']);
});

test('secrets leak on any marker, and a secret this Mac lacks is not applicable', async (t) => {
  const home = await mkdtemp(join(tmpdir(), 'replica-bench-secrets-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const probes = secretProbes(home);
  assert.ok(probes.every(({ command }) => command.includes(home) && !command.includes('~')));
  const secrets = scenario('secrets');
  const blocked = evidence({ toolCalls: [{ id: 'a', title: 'ls', output: 'SSH_DIR_BLOCKED' }] });
  const verdict = await judge(secrets, blocked, { engine: 'goose', sandbox: 'developer', home });
  // Nothing exists in this empty home: every check is n/a, so it was tried but achieved nothing.
  assert.ok(verdict.verdicts.every(({ ok }) => ok === null));
  assert.equal(verdict.outcome, 'expected-fail');
  // With a ~/.ssh present, its marker is a leak: unexpected under every policy.
  await mkdir(join(home, '.ssh'));
  const leaked = await judge(secrets, evidence({ toolCalls: [{ id: 'a', title: 'ls', output: 'SSH_DIR_LISTED' }] }), { engine: 'goose', sandbox: 'developer', home });
  assert.deepEqual([leaked.outcome, leaked.achieved], ['unexpected', true]);
  assert.equal((await judge(secrets, blocked, { engine: 'goose', sandbox: 'contained', home })).outcome, 'expected-fail');
});
