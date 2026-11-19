import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { createConnection } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { startGateway } from '../gateway.mjs';
import { evaluate } from '../target.mjs';
import { createRun } from '../workspace.mjs';

/** Sends lines on one connection and resolves to the parsed replies. */
function exchange(gateway, requests) {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: '127.0.0.1', port: gateway.port });
    const replies = [];
    let buffered = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(requests.map((request) => (typeof request === 'string' ? request : JSON.stringify(request)) + '\n').join('')));
    socket.on('data', (text) => {
      buffered += text;
      for (let newline; (newline = buffered.indexOf('\n')) >= 0; buffered = buffered.slice(newline + 1)) replies.push(JSON.parse(buffered.slice(0, newline)));
      if (replies.length === requests.length) { socket.end(); resolve(replies); }
    });
    socket.on('error', reject);
  });
}

test('the gateway answers only its own token, line by line, and records every request', async (t) => {
  const hits = [];
  const gateway = await startGateway({ hit: (hit) => hits.push(hit) });
  const other = await startGateway();
  t.after(() => { gateway.close(); other.close(); });

  const [wrong, missing, evaluated, batch, broken, unknown] = await exchange(gateway, [
    { token: other.token, op: 'evaluate', inputs: [1] },
    { op: 'evaluate', inputs: [1] },
    { token: gateway.token, op: 'evaluate', inputs: [0, 1, 1], params: { time: 2 } },
    { token: gateway.token, op: 'evaluate_batch', cases: [{ inputs: [1] }, { inputs: [1, 1] }] },
    'not json',
    { token: gateway.token, op: 'delete' }
  ]);
  assert.deepEqual(wrong, { ok: false, error: 'wrong or missing token' });
  assert.equal(missing.ok, false);
  assert.deepEqual(evaluated, { ok: true, outputs: evaluate([0, 1, 1], { time: 2 }) });
  assert.equal(batch.outputs.length, 2);
  assert.equal(broken.ok, false);
  assert.match(unknown.error, /op must be/);
  assert.deepEqual(hits.map(({ op, ok, samples }) => [op, ok, samples]), [
    ['evaluate', false, 1], ['evaluate', false, 1], ['evaluate', true, 3], ['evaluate_batch', true, 3], ['unknown', false, 0], ['delete', false, 0]
  ]);
});

test('the kit reaches the gateway from Python through gateway.json', { skip: process.platform !== 'darwin' && 'macOS' }, async (t) => {
  const python = await new Promise((resolve) => execFile('python3', ['--version'], (error) => resolve(!error)));
  if (!python) return t.skip('python3 is not installed');
  const home = await mkdtemp(join(tmpdir(), 'replica-bench-kit-'));
  const hits = [];
  const gateway = await startGateway({ hit: (hit) => hits.push(hit) });
  t.after(async () => { gateway.close(); await rm(home, { recursive: true, force: true }); });
  const run = await createRun(home, { label: 'kit', gateway });
  const script = 'import sys, json; sys.path.insert(0, "kit"); import rb; print(json.dumps([rb.describe()["parameters"][0]["name"], rb.evaluate([0, 1, 1], {"time": 2}), rb.compare([1.0, 2.0], [1.0, 2.5])]))';
  const output = await new Promise((resolve, reject) => execFile('python3', ['-I', '-c', script], { cwd: run.workspace, timeout: 20_000 }, (error, stdout, stderr) => error ? reject(new Error(stderr)) : resolve(stdout)));
  const [name, outputs, compared] = JSON.parse(output);
  assert.equal(name, 'time');
  assert.deepEqual(outputs, evaluate([0, 1, 1], { time: 2 }));
  assert.equal(compared.max_abs_error, 0.5);
  assert.equal(hits.filter(({ ok }) => ok).length, 2);
});
