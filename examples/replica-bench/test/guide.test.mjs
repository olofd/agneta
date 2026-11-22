// Getting Agneta in Replica Bench's window: the panel asks each question and shows each step, with a scripted
// environment in place of LaunchServices; and the bench's connection, opened once the user says yes.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:net';
import test from 'node:test';
import { installPage } from '@agneta-ai/client';
import { Agneta } from '../agneta.mjs';
import { BenchApp } from '../app.mjs';
import { agnetaLike, standIn } from './stand-in.mjs';

const release = { openURL: 'agneta://open', installURL: installPage, bundleIdentifier: 'com.objectivecoder.agneta' };
const installed = { path: '/Applications/Agneta.app', identifier: 'com.objectivecoder.agneta', version: '0.5.0' };

async function freePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function environment({ handler = null, onOpen = () => true } = {}) {
  const env = {
    handler, opened: [], lookupInterval: 10,
    findHandler: async () => env.handler,
    openURL: async (url) => { env.opened.push(url); return url === 'agneta://open' ? onOpen() : true; },
    architecture: async () => 'arm64'
  };
  return env;
}

async function until(bench, condition) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (condition(bench.view)) return bench.view;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.fail(`never reached: ${JSON.stringify(bench.view.guide ?? bench.view.status)}`);
}

function benchFor(t, port, env) {
  const bench = new BenchApp(port, { home: '/tmp', environment: env, client: release });
  t.after(() => bench.disconnect());
  return bench;
}

test('not installed: the panel offers to get Agneta; no goes back to Connect, opening nothing', async (t) => {
  const env = environment();
  const bench = benchFor(t, await freePort(), env);
  bench.connect();
  const view = await until(bench, (view) => view.guide?.question);
  assert.equal(view.phase, 'guide');
  assert.equal(view.guide.question.kind, 'install');
  bench.answer('no');
  await until(bench, (view) => view.phase === 'disconnected');
  assert.equal(bench.view.status, 'Connect to start.');
  assert.deepEqual(env.opened, []);
});

test('getting it: the page opens for this Mac, the panel waits, and Cancel ends the wait', async (t) => {
  const env = environment();
  const bench = benchFor(t, await freePort(), env);
  bench.connect();
  await until(bench, (view) => view.guide?.question?.kind === 'install');
  bench.answer('yes');
  await until(bench, (view) => view.guide?.step === 'installing');
  assert.deepEqual(env.opened, [`${installPage}#arm64`]);
  await bench.openInstallPage();
  assert.equal(env.opened.length, 2);
  bench.disconnect();
  assert.equal(bench.view.phase, 'disconnected');
  assert.equal(bench.view.guide, null);
});

test('at launch, without kept access, nothing is asked', async (t) => {
  const env = environment({ handler: installed });
  const bench = benchFor(t, await freePort(), env);
  await bench.connect({ quiet: true });
  assert.equal(bench.view.phase, 'disconnected');
  assert.match(bench.view.status, /isn't running/);
  assert.deepEqual(env.opened, []);
});

test('installed, not running: once the user says open, the bench connects', async (t) => {
  const port = await freePort();
  const fake = agnetaLike();
  let server = null;
  t.after(async () => { await server?.close(); });
  const env = environment({ handler: installed, onOpen: () => { setTimeout(async () => { server = await standIn(fake.answer, { port }); }, 100); return true; } });
  const agneta = new Agneta(port, { home: '/tmp', environment: env, client: release });
  t.after(() => agneta.close());
  const asked = [];
  const access = await agneta.connect({ guide: (question) => { asked.push(question.kind); return true; } });
  assert.equal(access.scope.tools, 'workspace');
  assert.deepEqual(asked, ['open']);
  assert.deepEqual(env.opened, ['agneta://open']);
});
