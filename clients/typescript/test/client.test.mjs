import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { once } from 'node:events';
import test from 'node:test';
import {
  AgnetaClient, connect, memoryTokenStore, NeedsPairingError, NotAllowedError, NotRunningError, ProtocolError,
  UnsupportedEnvironmentError, builds
} from '../dist/index.js';
import { agnetaLike, accessReport, catalogReport, standIn } from './stand-in.mjs';

async function freePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function setUp(t, options = {}) {
  const behaviour = agnetaLike(options);
  const agneta = await standIn(behaviour.answer);
  t.after(() => agneta.close());
  return { agneta, state: behaviour.state };
}

test('the defaults: the release port, its open URL, memory tokens', () => {
  const client = new AgnetaClient({ name: 'Example' });
  assert.equal(client.url, 'ws://127.0.0.1:47321/acp');
  assert.equal(client.openURL, 'agneta://open');
  assert.equal(client.agnetaName, 'Agneta');
  const dev = new AgnetaClient({ name: 'Example', build: 'dev' });
  assert.equal(dev.url, `ws://127.0.0.1:${builds.dev.port}/acp`);
  assert.equal(dev.openURL, 'agneta-dev://open');
  assert.equal(dev.agnetaName, 'Agneta Dev');
  const other = new AgnetaClient({ name: 'Example', port: 47341 });
  assert.equal(other.openURL, null);
  assert.equal(other.agnetaName, 'Agneta on port 47341');
  assert.equal(client.timeouts.pair, 310_000);
  assert.equal(client.state, 'disconnected');
  assert.throws(() => new AgnetaClient({}), TypeError);
});

test('first connect pairs with the scope, shows the code, keeps a remembered token and initializes', async (t) => {
  const { agneta } = await setUp(t);
  const tokens = memoryTokenStore();
  const client = new AgnetaClient({ name: 'Example', port: agneta.port, tokens, scope: { tools: 'workspace', providers: ['claude'], sandbox: 'contained' } });
  t.after(() => client.close());
  const codes = [], states = [], paired = [];
  client.on('pairingCode', (code) => codes.push(code));
  client.on('state', (state) => states.push(state));
  client.on('paired', (result) => paired.push(result.remembered));
  const access = await client.connect();
  assert.equal(access.workspace, '/tmp/agneta-stand-in/workspace');
  assert.equal(client.workspace, access.workspace);
  assert.deepEqual(codes, ['123456']);
  assert.deepEqual(states, ['connecting', 'pairing', 'connected']);
  assert.deepEqual(paired, [true]);
  assert.equal(client.remembered, true);
  assert.equal(client.pairingCode, null, 'cleared once pairing ends');
  assert.match(await tokens.load(), /^token-/);
  const [pair] = agneta.calls('agneta/pair');
  assert.deepEqual(pair.params, { name: 'Example', scope: { tools: 'workspace', providers: ['claude'], sandbox: 'contained' } });
  const [init] = agneta.calls('initialize');
  assert.equal(init.params.protocolVersion, 1);
  assert.equal(init.params._meta.agneta.token, await tokens.load());
  assert.deepEqual(init.params.clientCapabilities, {});
  assert.equal(init.params.clientInfo.name, 'Example');
  assert.deepEqual(client.extensions, ['agneta/policy', 'agneta/access']);
  // Connecting again while connected is a no-op.
  assert.equal(await client.connect(), access);
  assert.equal(agneta.calls('agneta/pair').length, 1);
});

test('Allow Once keeps nothing', async (t) => {
  const { agneta } = await setUp(t, { remembered: false });
  const tokens = memoryTokenStore();
  const client = await connect({ name: 'Example', port: agneta.port, tokens });
  t.after(() => client.close());
  assert.equal(client.remembered, false);
  assert.equal(await tokens.load(), null);
});

test('a kept token connects without pairing; one Agneta no longer accepts is forgotten', async (t) => {
  const { agneta } = await setUp(t);
  const tokens = memoryTokenStore('kept-token');
  const client = new AgnetaClient({ name: 'Example', port: agneta.port, tokens });
  await client.connect({ pair: 'never' });
  assert.equal(agneta.calls('agneta/pair').length, 0);
  assert.equal(client.remembered, true);
  client.close();

  await tokens.save('removed-token');
  const removed = [];
  client.on('accessRemoved', (error) => removed.push(error.kind));
  await assert.rejects(client.connect({ pair: 'never' }), NeedsPairingError);
  assert.deepEqual(removed, ['needsPairing']);
  assert.equal(await tokens.load(), null);
  assert.equal(client.state, 'disconnected');
  assert.equal(agneta.calls('agneta/pair').length, 0, 'a quiet connect never opens the approval window');

  // No token at all: a quiet connect stops too.
  await assert.rejects(client.connect({ pair: 'never' }), NeedsPairingError);

  // The default pairs instead.
  await tokens.save('removed-token');
  await client.connect();
  assert.equal(agneta.calls('agneta/pair').length, 1);
  client.close();
});

test('pair: "always" pairs even with a usable token (a wider scope)', async (t) => {
  const { agneta } = await setUp(t);
  const client = new AgnetaClient({ name: 'Example', port: agneta.port, tokens: memoryTokenStore('kept-token') });
  t.after(() => client.close());
  await client.connect({ pair: 'always', scope: { tools: 'read' } });
  assert.deepEqual(agneta.calls('agneta/pair')[0].params.scope, { tools: 'read' });
  assert.equal(agneta.calls('initialize').length, 1);
});

test('Don\'t Allow is NotAllowedError and leaves the client disconnected', async (t) => {
  const { agneta } = await setUp(t, { handlers: { 'agneta/pair': () => ({ error: { code: -32002, message: 'Example wasn\'t allowed to use Agneta' } }) } });
  const client = new AgnetaClient({ name: 'Example', port: agneta.port });
  await assert.rejects(client.connect(), NotAllowedError);
  assert.equal(client.state, 'disconnected');
  assert.equal(client.connection, null);
});

test('before pairing: the catalog, setup, and waiting for a provider', async (t) => {
  let connected = false;
  const { agneta } = await setUp(t, {
    handlers: {
      'agneta/catalog': () => ({ result: catalogReport(connected) }),
      'agneta/setup': (message, peer) => {
        setTimeout(() => { connected = true; peer.notify('agneta/catalogChanged', { catalog: catalogReport(true) }); }, 30);
        return { result: { shown: true } };
      }
    }
  });
  const client = new AgnetaClient({ name: 'Example', port: agneta.port });
  t.after(() => client.close());
  const catalog = await client.catalog();
  assert.equal(catalog.connected, false);
  assert.equal(client.access, null, 'not paired yet');
  const changes = [];
  client.on('catalogChanged', (value) => changes.push(value.connected));
  await client.connect({ setup: 'claude' });
  const [setup] = agneta.calls('agneta/setup');
  assert.deepEqual(setup.params, { name: 'Example', kind: 'claude' });
  assert.deepEqual(changes, [true]);
  assert.equal(agneta.calls('agneta/pair').length, 1);
  assert.equal(client.state, 'connected');
});

test('setup is skipped when a provider is connected', async (t) => {
  const { agneta } = await setUp(t);
  const client = await connect({ name: 'Example', port: agneta.port, setup: true });
  t.after(() => client.close());
  assert.equal(agneta.calls('agneta/setup').length, 0);
  assert.equal(agneta.calls('agneta/catalog').length, 1);
});

test('accessChanged keeps the access report current', async (t) => {
  const { agneta } = await setUp(t);
  const client = await connect({ name: 'Example', port: agneta.port });
  t.after(() => client.close());
  const next = accessReport({ providers: [{ ...accessReport().providers[0], paused: true }] });
  const changed = client.next('accessChanged');
  agneta.notify('agneta/accessChanged', { access: next });
  const [access] = await changed;
  assert.equal(access.providers[0].paused, true);
  assert.equal(client.access.providers[0].paused, true);
  assert.equal((await client.refreshAccess()).providers[0].paused, false, 'agneta/access reads it again');
});

test('when Agneta isn\'t running: NotRunningError without launch; with launch the client waits and connects', async (t) => {
  const port = await freePort();
  const declined = new AgnetaClient({ name: 'Example', port, launch: () => false });
  await assert.rejects(declined.connect(), (error) => error instanceof NotRunningError && error.openURL === null);
  assert.equal(declined.state, 'disconnected');

  const plain = new AgnetaClient({ name: 'Example', port });
  await assert.rejects(plain.connect(), NotRunningError);

  const behaviour = agnetaLike();
  let started = null;
  const asked = [];
  const client = new AgnetaClient({
    name: 'Example', port, openURL: 'agneta-dev://open',
    launch: async (info) => {
      asked.push(info);
      // "Opening Agneta": it comes up a moment later on the port.
      setTimeout(async () => { started = await standIn(behaviour.answer, { port }); }, 200);
      return true;
    }
  });
  t.after(async () => { client.close(); await started?.close(); });
  const access = await client.connect();
  assert.ok(access.providers.length);
  assert.deepEqual(asked, [{ name: `Agneta on port ${port}`, url: `ws://127.0.0.1:${port}/acp`, openURL: 'agneta-dev://open' }]);
});

test('a dropped connection ends its sessions; with reconnect, it comes back quietly', async (t) => {
  const { agneta } = await setUp(t);
  const tokens = memoryTokenStore();
  const client = await connect({ name: 'Example', port: agneta.port, tokens, reconnect: { delay: 20 } });
  t.after(() => client.close());
  const session = await client.newSession();
  const ended = session.next('ended');
  const events = [];
  client.on('disconnected', (error) => events.push(`disconnected ${error.kind}`));
  client.on('reconnecting', (attempt) => events.push(`reconnecting ${attempt}`));
  const reconnected = client.next('reconnected');
  agneta.drop();
  const [end] = await ended;
  assert.equal(end.reason, 'disconnected');
  assert.equal(end.error.kind, 'connectionClosed');
  await reconnected;
  assert.deepEqual(events, ['disconnected connectionClosed', 'reconnecting 1']);
  assert.equal(client.state, 'connected');
  assert.equal(agneta.calls('agneta/pair').length, 1, 'reconnecting never pairs');
  assert.equal(client.sessions.length, 0);
});

test('reconnect stops, with accessRemoved, when Agneta no longer accepts the token', async (t) => {
  const { agneta, state } = await setUp(t);
  const tokens = memoryTokenStore();
  const client = await connect({ name: 'Example', port: agneta.port, tokens, reconnect: { delay: 20 } });
  t.after(() => client.close());
  state.tokens.clear(); // the user removed the app in Agneta, which closes its connections
  const removed = client.next('accessRemoved');
  agneta.drop();
  await removed;
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(client.state, 'disconnected');
  assert.equal(await tokens.load(), null);
});

test('no reconnect after Allow Once, or after close()', async (t) => {
  const { agneta } = await setUp(t, { remembered: false });
  const client = await connect({ name: 'Example', port: agneta.port, reconnect: { delay: 10 } });
  const reconnecting = [];
  client.on('reconnecting', () => reconnecting.push(1));
  agneta.drop();
  await client.next('disconnected');
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual(reconnecting, []);
  client.close();
});

test('an Agneta that tells apps nothing of their access is a ProtocolError', async (t) => {
  const { agneta } = await setUp(t, { handlers: { initialize: () => ({ result: { protocolVersion: 1, _meta: {} } }) } });
  await assert.rejects(connect({ name: 'Example', port: agneta.port, tokens: memoryTokenStore('kept-token') }), ProtocolError);
});

test('in a web page it refuses at once, rather than failing as not running', async () => {
  globalThis.document = {};
  try {
    await assert.rejects(new AgnetaClient({ name: 'Example', port: 1 }).connect(), UnsupportedEnvironmentError);
  } finally {
    delete globalThis.document;
  }
});

test('the raw layer: any request, notification listeners and the message tap', async (t) => {
  const { agneta } = await setUp(t);
  const client = await connect({ name: 'Example', port: agneta.port });
  t.after(() => client.close());
  const seen = [];
  client.connection.on('message', (message, direction) => seen.push(`${direction} ${message.method ?? 'result'}`));
  await assert.rejects(client.request('engine/own', {}), (error) => error.kind === 'methodNotFound');
  assert.deepEqual(await client.request('agneta/access', {}), client.access);
  const queued = [];
  client.onNotification('agneta/queued', (params) => queued.push(params.position));
  agneta.notify('agneta/queued', { sessionId: 'nobody', position: 4 });
  await client.next('queued');
  assert.deepEqual(queued, [4]);
  assert.deepEqual(seen.slice(0, 4), ['out engine/own', 'in result', 'out agneta/access', 'in result']);
});

test('pair: "always" pairs again on a client that is already connected', async (t) => {
  const { agneta } = await setUp(t);
  const client = await connect({ name: 'Example', port: agneta.port, tokens: memoryTokenStore('kept-token') });
  t.after(() => client.close());
  assert.equal(agneta.calls('agneta/pair').length, 0);
  await client.connect({ pair: 'always', scope: { tools: 'workspace' } });
  assert.equal(agneta.calls('agneta/pair').length, 1);
  assert.equal(client.state, 'connected');
});

test('Don\'t Allow on pairing again keeps the connection that works, and its sessions', async (t) => {
  const { agneta } = await setUp(t, { handlers: { 'agneta/pair': () => ({ error: { code: -32002, message: 'Example wasn\'t allowed to use Agneta' } }) } });
  const client = await connect({ name: 'Example', port: agneta.port, tokens: memoryTokenStore('kept-token') });
  t.after(() => client.close());
  const connection = client.connection;
  await assert.rejects(client.connect({ pair: 'always', scope: { tools: 'workspace' } }), NotAllowedError);
  assert.equal(client.state, 'connected');
  assert.equal(client.connection, connection);
});

test('the message tap never shows the token: initialize\'s nor the pairing result\'s', async (t) => {
  const { agneta } = await setUp(t);
  const client = new AgnetaClient({ name: 'Example', port: agneta.port, tokens: memoryTokenStore() });
  t.after(() => client.close());
  const seen = [];
  client.on('state', () => { client.connection?.on('message', (message) => seen.push(JSON.stringify(message))); });
  await client.connect();
  const token = await client.tokens.load();
  assert.ok(seen.some((line) => line.includes('[redacted]')), 'the tap saw the pairing and initialize');
  assert.ok(token === null || !seen.some((line) => line.includes(token)), 'no token in what the tap saw');
});

test('two connects at once share one connection and one pairing', async (t) => {
  const { agneta } = await setUp(t);
  const client = new AgnetaClient({ name: 'Example', port: agneta.port });
  t.after(() => client.close());
  const [first, second] = await Promise.all([client.connect(), client.connect()]);
  assert.equal(first, second);
  assert.equal(agneta.calls('agneta/pair').length, 1);
  assert.equal(agneta.peers.length, 1);
});

test('pair() and initialize() on their own leave the state right', async (t) => {
  let refuse = true;
  const { agneta } = await setUp(t, { handlers: { 'agneta/pair': () => (refuse ? { error: { code: -32002, message: 'no' } } : undefined) } });
  const client = new AgnetaClient({ name: 'Example', port: agneta.port });
  t.after(() => client.close());
  await client.catalog();
  assert.equal(client.state, 'connecting', 'open, not paired');
  await assert.rejects(client.pair(), NotAllowedError);
  assert.equal(client.state, 'connecting', 'still open: the app may ask again');
  refuse = false;
  await client.pair();
  assert.equal(client.state, 'connected');
});

test('waitForProvider: a timeout ends the wait', async (t) => {
  const { agneta } = await setUp(t, { handlers: { 'agneta/catalog': () => ({ result: catalogReport(false) }) } });
  const client = new AgnetaClient({ name: 'Example', port: agneta.port });
  t.after(() => client.close());
  await assert.rejects(client.waitForProvider('claude', { timeout: 30 }), (error) => error.kind === 'aborted');
});
