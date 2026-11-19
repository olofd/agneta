import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { evaluate } from '../target.mjs';
import { startTools } from '../tools.mjs';

async function post(tools, message, headers) {
  return fetch(tools.registration.url, {
    method: 'POST',
    headers: headers ?? Object.fromEntries(tools.registration.headers.map(({ name, value }) => [name, value])),
    body: JSON.stringify({ jsonrpc: '2.0', ...message })
  });
}

async function setUp(t, score = async () => ({ ok: true, rmsErrorDb: -120, maxAbsError: 1e-7, cases: 24, samples: 49152, passed: true, threshold: -100 })) {
  const workspace = await mkdtemp(join(tmpdir(), 'replica-bench-tools-'));
  await mkdir(join(workspace, 'candidate'));
  await writeFile(join(workspace, 'candidate', 'Cargo.toml'), '[package]\nname = "candidate"\n');
  const calls = [];
  const scored = [];
  const tools = await startTools({ workspace, score: async (folder) => { scored.push(folder); return score(folder); }, called: (call) => calls.push(call) });
  t.after(async () => { tools.close(); await rm(workspace, { recursive: true, force: true }); });
  const call = async (name, args = {}) => (await (await post(tools, { id: 1, method: 'tools/call', params: { name, arguments: args } })).json()).result;
  return { workspace, tools, calls, scored, call };
}

test('each tool server takes only its own bearer and refuses browser origins', async (t) => {
  const first = await setUp(t);
  const second = await setUp(t);
  const list = { id: 1, method: 'tools/list' };
  assert.equal((await post(first.tools, list, {})).status, 401);
  const bearer = first.tools.registration.headers[0].value;
  assert.equal((await post(second.tools, list, { Authorization: bearer })).status, 401);
  assert.equal((await post(first.tools, list, { Authorization: `${bearer}x` })).status, 401);
  assert.equal((await post(first.tools, list, { Authorization: bearer, Origin: 'https://example.org' })).status, 403);
  const { result } = await (await post(first.tools, list)).json();
  assert.deepEqual(result.tools.map(({ name }) => name), ['describe_target', 'evaluate', 'evaluate_batch', 'plot_residual', 'submit_candidate', 'score_candidate']);
  assert.equal(first.tools.registration.name, 'bench');
});

test('the tools evaluate the target, plot as PNG and record every call', async (t) => {
  const { call, calls } = await setUp(t);
  assert.match((await call('describe_target')).content[0].text, /"threshold"/);
  const inputs = [0, 0, 1, 1, 1, 1];
  assert.deepEqual(JSON.parse((await call('evaluate', { inputs, params: { time: 2 } })).content[0].text).outputs, evaluate(inputs, { time: 2 }));
  assert.equal(JSON.parse((await call('evaluate_batch', { cases: [{ inputs }, { inputs, params: { drive: 4 } }] })).content[0].text).outputs.length, 2);
  const refused = await call('evaluate', { inputs, params: { time: 0 } });
  assert.equal(refused.isError, true);
  assert.match(refused.content[0].text, /time must be/);

  const plot = await call('plot_residual', { inputs, outputs: new Array(inputs.length).fill(0) });
  assert.equal(plot.content[0].type, 'image');
  assert.equal(plot.content[0].mimeType, 'image/png');
  assert.deepEqual([...Buffer.from(plot.content[0].data, 'base64').subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.match(plot.content[1].text, /max abs error/);
  assert.equal((await call('plot_residual', { inputs, outputs: [1] })).isError, true);
  assert.deepEqual(calls.map(({ tool, ok }) => [tool, ok]), [
    ['describe_target', true], ['evaluate', true], ['evaluate_batch', true], ['evaluate', false], ['plot_residual', true], ['plot_residual', false]
  ]);
});

test('a candidate is submitted from inside the workspace and scored by the app', async (t) => {
  const { call, scored, workspace } = await setUp(t);
  assert.match((await call('score_candidate')).content[0].text, /submit a candidate first/);
  assert.equal((await call('submit_candidate', { path: '../' })).isError, true);
  assert.equal((await call('submit_candidate', { path: '/etc' })).isError, true);
  assert.match((await call('submit_candidate', { path: 'nowhere' })).content[0].text, /no folder/);
  await mkdir(join(workspace, 'empty'));
  assert.match((await call('submit_candidate', { path: 'empty' })).content[0].text, /no Cargo.toml/);
  assert.match((await call('submit_candidate', { path: 'candidate' })).content[0].text, /Recorded the candidate at candidate/);
  const result = await call('score_candidate');
  assert.match(result.content[0].text, /-120\.0 dB relative to the target\. That's a clone/);
  assert.equal(scored.length, 1);
  assert.ok(scored[0].endsWith('/candidate'));
});

test('a failed referee build is an error result with the reason', async (t) => {
  const { call } = await setUp(t, async () => ({ ok: false, stage: 'build', message: 'The referee\'s build failed: cargo build failed (exit 101).', stderr: 'error[E0425]' }));
  await call('submit_candidate', { path: 'candidate' });
  const result = await call('score_candidate');
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /exit 101[\s\S]*E0425/);
});
