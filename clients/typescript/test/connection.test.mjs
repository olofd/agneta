import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { once } from 'node:events';
import test from 'node:test';
import { Connection, NotRunningError, ConnectionRefusedError, TimeoutError, ConnectionClosedError, AbortedError, InvalidParamsError } from '../dist/index.js';
import { standIn } from './stand-in.mjs';

async function freePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

test('requests resolve with results and reject with typed errors', async (t) => {
  const agneta = await standIn((message) => message.method === 'echo' ? { result: message.params }
    : { error: { code: -32602, message: 'Unknown session', data: { agneta: {} } } });
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  assert.deepEqual(await connection.request('echo', { a: 1 }), { a: 1 });
  await assert.rejects(connection.request('agneta/access', {}), (error) => error instanceof InvalidParamsError && error.method === 'agneta/access');
  assert.equal(agneta.received[0].jsonrpc, '2.0');
  assert.equal(typeof agneta.received[0].id, 'number');
});

test('a timeout rejects that call only; the connection stays open and a late answer is ignored', async (t) => {
  let late;
  const agneta = await standIn((message) => {
    if (message.method === 'slow') return new Promise((resolve) => { late = () => resolve({ result: 'late' }); });
    return { result: 'fast' };
  });
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url, requestTimeout: 50 });
  t.after(() => connection.close());
  await assert.rejects(connection.request('slow'), (error) => error instanceof TimeoutError && error.method === 'slow');
  late();
  assert.equal(await connection.request('fast'), 'fast');
  assert.ok(connection.isOpen);
  // No timeout for this one.
  const slow = connection.request('slow', undefined, { timeout: 0 });
  await new Promise((resolve) => setTimeout(resolve, 80));
  late();
  assert.equal(await slow, 'late');
});

test('an AbortSignal ends a call', async (t) => {
  const agneta = await standIn(() => new Promise(() => {}));
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  const controller = new AbortController();
  const call = connection.request('hang', undefined, { signal: controller.signal });
  controller.abort();
  await assert.rejects(call, AbortedError);
  await assert.rejects(connection.request('hang', undefined, { signal: AbortSignal.abort() }), AbortedError);
});

test('notifications reach listeners; the message tap sees both directions', async (t) => {
  const agneta = await standIn((message, peer) => {
    peer.notify('agneta/queued', { sessionId: 's', position: 2 });
    return { result: {} };
  });
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  const seen = [], typed = [];
  connection.on('message', (message, direction) => seen.push([direction, message.method ?? 'response']));
  connection.onNotification('agneta/queued', (params) => typed.push(params.position));
  const notified = connection.next('notification');
  await connection.request('agneta/access', {});
  assert.deepEqual((await notified), ['agneta/queued', { sessionId: 's', position: 2 }]);
  assert.deepEqual(typed, [2]);
  assert.deepEqual(seen, [['out', 'agneta/access'], ['in', 'agneta/queued'], ['in', 'response']]);
});

test('requests from Agneta are answered by handlers; unhandled ones get -32601', async (t) => {
  const agneta = await standIn();
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  await new Promise((resolve) => setTimeout(resolve, 20));
  const peer = agneta.peers[0];
  assert.equal((await peer.request('fs/read_text_file', {})).error.code, -32601);
  connection.handle('session/request_permission', (params) => ({ outcome: { outcome: 'selected', optionId: params.options[0].optionId } }));
  const answer = await peer.request('session/request_permission', { sessionId: 's', toolCall: { toolCallId: 't' }, options: [{ optionId: 'ok', kind: 'allow_once', name: 'Allow' }] });
  assert.deepEqual(answer.result, { outcome: { outcome: 'selected', optionId: 'ok' } });
  connection.handle('custom', () => { throw Object.assign(new Error('nope'), { code: -32050 }); });
  assert.deepEqual((await peer.request('custom', {})).error, { code: -32050, message: 'nope' });
});

test('nothing listening is NotRunningError; a refused upgrade is ConnectionRefusedError', async (t) => {
  const port = await freePort();
  await assert.rejects(Connection.open({ url: `ws://127.0.0.1:${port}/acp`, openURL: 'agneta://open' }),
    (error) => error instanceof NotRunningError && error.openURL === 'agneta://open' && error.url.endsWith(`${port}/acp`));
  const refusing = await standIn(undefined, { refuse: true });
  t.after(() => refusing.close());
  await assert.rejects(Connection.open({ url: refusing.url }), ConnectionRefusedError);
});

test('closing rejects pending calls with ConnectionClosedError and resolves closed', async (t) => {
  const agneta = await standIn(() => new Promise(() => {}));
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  const pending = connection.request('hang');
  agneta.drop();
  await assert.rejects(pending, ConnectionClosedError);
  assert.ok((await connection.closed) instanceof ConnectionClosedError);
  assert.equal(connection.isOpen, false);
  await assert.rejects(connection.request('after'), ConnectionClosedError);
  assert.throws(() => connection.notify('session/cancel', { sessionId: 's' }), ConnectionClosedError);
});

test('large messages travel both ways', async (t) => {
  const agneta = await standIn((message) => ({ result: { text: message.params.text + message.params.text } }));
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  const text = 'x'.repeat(200_000);
  assert.equal((await connection.request('double', { text })).text.length, 400_000);
});

test('an already aborted open never constructs a socket', async () => {
  let created = 0;
  class Socket { constructor() { created++; } }
  await assert.rejects(Connection.open({ url: 'ws://127.0.0.1:1/acp', WebSocket: Socket, signal: AbortSignal.abort() }), AbortedError);
  assert.equal(created, 0);
});

test('malformed responses fail the call as protocol errors and leave the connection usable', async (t) => {
  const agneta = await standIn((message, peer) => {
    if (message.method === 'good') return { result: null };
    const variants = [{}, { result: 1, error: { code: -32602, message: 'bad' } }, { error: null }, { error: { code: 'bad', message: 5 } }];
    peer.send({ id: message.id, ...variants[message.params] });
  });
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  for (let index = 0; index < 4; index++) {
    await assert.rejects(connection.request('bad', index), (error) => error.kind === 'protocol');
  }
  assert.equal(await connection.request('good'), null);
});

test('a message listener cannot mutate a result before it reaches the caller', async (t) => {
  const agneta = await standIn(() => ({ result: { nested: { value: 'original' } } }));
  t.after(() => agneta.close());
  const connection = await Connection.open({ url: agneta.url });
  t.after(() => connection.close());
  connection.on('message', (message, direction) => { if (direction === 'in') message.result.nested.value = 'changed'; });
  assert.deepEqual(await connection.request('echo'), { nested: { value: 'original' } });
});
