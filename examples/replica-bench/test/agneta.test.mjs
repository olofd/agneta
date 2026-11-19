// The bench's pairing and access reading against a stand-in Agneta: the sandbox scope it asks for, the grant's mode
// it reads back (and its changes), each engine's sandbox levels, and kept grants that no longer cover the bench folder.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';
import { Agneta, memoryTokens, pairingScope, providersOf, whatIsMissing } from '../agneta.mjs';
import { toolchainFolders } from '../toolchain.mjs';
import { agnetaLike, standIn } from './stand-in.mjs';

async function connected(t, options) {
  const fake = agnetaLike(options);
  const server = await standIn(fake.answer);
  const agneta = new Agneta(server.port, { home: '/tmp' });
  t.after(() => { agneta.close(); server.close(); });
  return { fake, server, agneta };
}

test('pairing asks for workspace tools in the bench folder and the developer sandbox, never developerAccess', async (t) => {
  const { fake, agneta } = await connected(t, {});
  await agneta.connect();
  const pairs = fake.calls.filter(({ method }) => method === 'agneta/pair');
  assert.equal(pairs.length, 1);
  const big = { providers: 'all', engines: 'all', sandbox: 'any' };
  assert.deepEqual(pairs[0].params, { name: 'Replica Bench', scope: { tools: 'workspace', folders: ['/tmp', ...toolchainFolders()], ...big } });
  assert.deepEqual(pairingScope('/x'), { tools: 'workspace', folders: ['/x', ...toolchainFolders()], ...big });
});

test('the grant\'s mode is what the user picked, read from the access report', async (t) => {
  // The user picked contained in the approval window, though the bench asked for developer.
  const { agneta } = await connected(t, { grant: 'contained' });
  assert.equal(agneta.grant, null);
  await agneta.connect();
  assert.equal(agneta.grant, 'contained');
  agneta.close();
  assert.equal(agneta.grant, null);
});

test('agneta/accessChanged moves the grant\'s mode, as when the user narrows it in Settings → Apps', async (t) => {
  const { agneta, server } = await connected(t, {});
  await agneta.connect();
  assert.equal(agneta.grant, 'developer');
  const changed = once(agneta, 'access');
  server.notify('agneta/accessChanged', { access: { ...agneta.access, scope: { ...agneta.access.scope, sandbox: 'contained' } } });
  const [access] = await changed;
  assert.equal(access.scope.sandbox, 'contained');
  assert.equal(agneta.grant, 'contained');
});

test('each engine says which modes it can provide, and whether Agneta can confine it at all', async (t) => {
  const { agneta } = await connected(t, {});
  await agneta.connect();
  assert.deepEqual(agneta.providers(), [{
    id: 'p1', label: 'Claude', paused: false, needsSignIn: false,
    engines: [
      { id: 'claude-code', name: 'Claude Code', state: 'ready', reason: undefined, levels: ['contained', 'developer'], uncontained: false },
      { id: 'goose', name: 'Goose', state: 'downloadable', reason: undefined, levels: ['developer'], uncontained: true }
    ]
  }]);
  // An access report without sandboxLevels says nothing about them, rather than a guess.
  assert.deepEqual(providersOf({ providers: [{ id: 'k', label: 'Key', engines: ['goose'] }], engines: [] })[0].engines,
    [{ id: 'goose', name: 'goose', state: 'unknown', reason: undefined, levels: null, uncontained: false }]);
  assert.deepEqual(providersOf(null), []);
});

test('a kept token is used while its grant covers the bench folder, and replaced when it doesn\'t', async (t) => {
  const tokens = memoryTokens();
  const fake = agnetaLike({});
  const server = await standIn(fake.answer);
  t.after(() => server.close());

  const first = new Agneta(server.port, { home: '/tmp', tokens });
  await first.connect();
  assert.equal(first.grant, 'developer');
  first.close();
  assert.ok(await tokens.load());

  const again = new Agneta(server.port, { home: '/tmp', tokens });
  await again.connect({ quiet: true });
  assert.equal(fake.calls.filter(({ method }) => method === 'agneta/pair').length, 1, 'connected with the kept token');
  assert.equal(again.grant, 'developer');
  again.close();

  // The bench folder moved: the kept grant doesn't cover it, so a quiet connect stops and a normal one pairs again.
  const moved = new Agneta(server.port, { home: '/private/var', tokens });
  assert.equal(await moved.connect({ quiet: true }), null);
  assert.equal(await tokens.load(), null);
  await moved.connect();
  const pairs = fake.calls.filter(({ method }) => method === 'agneta/pair');
  assert.equal(pairs.length, 2);
  assert.deepEqual(pairs[1].params.scope.folders, ['/private/var', ...toolchainFolders()]);
  moved.close();
});

test('the headless runner says what is missing, for either build, without opening anything', () => {
  const release = { agnetaName: 'Agneta', installURL: 'https://agneta.dahlbom.io/get/', homebrew: 'brew install olofd/tap/agneta' };
  const dev = { agnetaName: 'Agneta Dev', installURL: 'https://github.com/olofd/agneta#build-and-run', homebrew: null };
  const found = (releaseState, devState) => [{ agneta: release, presence: { state: releaseState } }, { agneta: dev, presence: { state: devState } }];
  assert.equal(whatIsMissing(found('notInstalled', 'notInstalled'), 'arm64'),
    'Agneta isn\'t installed. Get it from https://agneta.dahlbom.io/get/#arm64, or install it with: brew install olofd/tap/agneta. Then open it and run this again.');
  // Only Agneta Dev on this Mac: open it, rather than "not installed".
  assert.match(whatIsMissing(found('notInstalled', 'notRunning')), /^Agneta Dev isn't running\. Open it/);
  assert.match(whatIsMissing(found('notRunning', 'notRunning')), /^Agneta isn't running/);
  assert.match(whatIsMissing(found('onDiskImage', 'notInstalled')), /^Agneta is on its disk image: drag it into Applications/);
  assert.match(whatIsMissing(found('unknown', 'unknown')), /Neither Agneta/);
});
