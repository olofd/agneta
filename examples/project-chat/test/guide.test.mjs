// Getting Agneta in Project Chat's window: the panel asks each question and shows each step, with a scripted
// environment in place of LaunchServices and the client's stand-in Agneta coming up when "opened".
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:net';
import test from 'node:test';
import { installPage } from '@agneta/client';
import { agnetaLike, standIn } from '../../../clients/typescript/test/stand-in.mjs';
import { ProjectChat } from '../chat.mjs';

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
    architecture: async () => 'x86_64'
  };
  return env;
}

function chatFor(t, port, env) {
  const chat = new ProjectChat(port, {
    environment: env,
    client: { openURL: 'agneta://open', installURL: installPage, bundleIdentifier: 'com.objectivecoder.agneta' }
  });
  t.after(() => chat.disconnect());
  return chat;
}

async function until(chat, condition) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (condition(chat.view)) return chat.view;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.fail(`never reached: ${JSON.stringify(chat.view.guide ?? chat.view.status)}`);
}

test('not installed: the panel offers to get Agneta; declining opens nothing and goes back to Connect', async (t) => {
  const env = environment();
  const chat = chatFor(t, await freePort(), env);
  chat.connect();
  const view = await until(chat, (view) => view.guide?.question);
  assert.equal(view.phase, 'guide');
  assert.equal(view.guide.question.kind, 'install');
  assert.match(view.guide.question.confirm, /^Get /);
  chat.answer('no');
  await until(chat, (view) => view.phase === 'disconnected');
  assert.equal(chat.view.status, 'Connect to start chatting.');
  assert.equal(chat.view.guide, null);
  assert.deepEqual(env.opened, []);
});

test('getting it: the page opens, the panel waits with Open the page again, and Cancel ends the wait', async (t) => {
  const env = environment();
  const chat = chatFor(t, await freePort(), env);
  chat.connect();
  await until(chat, (view) => view.guide?.question?.kind === 'install');
  chat.answer('yes');
  const view = await until(chat, (view) => view.guide?.step === 'installing');
  assert.equal(view.guide.question, undefined);
  assert.deepEqual(env.opened, [`${installPage}#x86_64`]);
  await chat.openInstallPage();
  assert.equal(env.opened.length, 2);
  chat.disconnect();
  assert.equal(chat.view.phase, 'disconnected');
});

test('installed, not running: the panel asks to open Agneta, then the chat is ready', async (t) => {
  const port = await freePort();
  const behaviour = agnetaLike();
  let agneta = null;
  t.after(async () => { await agneta?.close(); });
  const env = environment({ handler: installed, onOpen: () => { setTimeout(async () => { agneta = await standIn(behaviour.answer, { port }); }, 100); return true; } });
  const chat = chatFor(t, port, env);
  chat.connect();
  const asking = await until(chat, (view) => view.guide?.question);
  assert.equal(asking.guide.question.kind, 'open');
  chat.answer('yes');
  await until(chat, (view) => view.phase === 'ready');
  assert.deepEqual(env.opened, ['agneta://open']);
  assert.equal(chat.view.guide, null);
});

test('at launch, without a kept token, nothing is asked', async (t) => {
  const env = environment({ handler: installed });
  const chat = chatFor(t, await freePort(), env);
  await chat.connect({ quiet: true });
  assert.equal(chat.view.phase, 'disconnected');
  assert.match(chat.view.status, /isn't running/);
  assert.deepEqual(env.opened, []);
});
