// Getting Agneta (docs/APP_PROTOCOL.md): telling not installed, on its disk image, installed and running apart, the
// guided connect's questions and progress, the waits, the version check and the install URL. A scripted environment
// stands in for LaunchServices; the stand-in Agneta comes up on its port when the test says so.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:net';
import test from 'node:test';
import {
  AbortedError, AgnetaClient, Connection, DeclinedError, NetworkBlockedError, NotInstalledError, NotRunningError, OutdatedError,
  compareVersions, installPage, installPageURL, memoryTokenStore, placement, probeAgneta
} from '../dist/index.js';
import { agnetaLike, catalogReport, standIn } from './stand-in.mjs';

const agnetaID = 'com.objectivecoder.agneta';
const installed = { path: '/Applications/Agneta.app', identifier: agnetaID, version: '0.5.0' };

async function freePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

/** LaunchServices, scripted: `handler` is what it finds now; opening `agneta://open` runs `onOpen`. */
function environment({ handler = null, onOpen = () => true, readBundle } = {}) {
  const env = {
    home: '/Users/someone',
    lookupInterval: 10,
    handler,
    lookups: 0,
    opened: [],
    async findHandler(url) {
      env.lookups++;
      assert.equal(url, 'agneta://open');
      return env.handler;
    },
    async openURL(url) {
      env.opened.push(url);
      return url === 'agneta://open' ? onOpen(url) : true;
    },
    async architecture() { return 'arm64'; }
  };
  if (readBundle) env.readBundle = readBundle;
  return env;
}

/** A client for Agneta on `port`, as the release build (its open URL, install page and bundle ID), with quick waits. */
function client(t, port, env, options = {}) {
  const made = new AgnetaClient({
    name: 'Example', port, openURL: 'agneta://open', installURL: installPage, bundleIdentifier: agnetaID, environment: env,
    timeouts: { slow: 150, keepWaiting: 400, open: 5000 }, ...options
  });
  t.after(() => made.close());
  return made;
}

/** Answers every question yes, and keeps them. */
function yes(asked) {
  return (question) => { asked.push(question); return true; };
}

test('not installed: asked once, the install page opens, Agneta is opened once installed, then pairs', async (t) => {
  const port = await freePort();
  const behaviour = agnetaLike();
  let agneta = null;
  t.after(async () => { await agneta?.close(); });
  const env = environment({ onOpen: () => { setTimeout(async () => { agneta = await standIn(behaviour.answer, { port }); }, 100); return true; } });
  const asked = [];
  const steps = [];
  const app = client(t, port, env);
  app.on('progress', (progress) => steps.push(progress));
  // The user installs Agneta a moment after the page opened: it appears in Applications.
  setTimeout(() => { env.handler = installed; }, 300);
  const access = await app.connect({ guide: yes(asked), onProgress: () => {} });
  assert.ok(access.providers.length);
  assert.deepEqual(asked.map(({ kind }) => kind), ['install']);
  assert.equal(asked[0].installURL, installPage);
  assert.equal(asked[0].onDiskImage, false);
  assert.match(asked[0].detail, /opens it once it's installed/);
  assert.deepEqual(env.opened, [`${installPage}#arm64`, 'agneta://open']);
  const order = steps.map(({ step }) => step).filter((step, index, all) => step !== all[index - 1]);
  assert.deepEqual(order, ['looking', 'notInstalled', 'installing', 'installed', 'opening', 'connecting', 'pairing', 'connected']);
  assert.ok(steps.every(({ title }) => typeof title === 'string' && title.length > 0));
  assert.equal(steps.find(({ step, code }) => step === 'pairing' && code)?.code, '123456');
  assert.equal(app.state, 'connected');
});

test('declining a question rejects with DeclinedError and opens nothing', async (t) => {
  const port = await freePort();
  const env = environment();
  const app = client(t, port, env);
  await assert.rejects(app.connect({ guide: () => false }), (error) => error instanceof DeclinedError && error.kind === 'declined' && error.question === 'install');
  assert.deepEqual(env.opened, []);
  assert.equal(app.state, 'disconnected');
  env.handler = installed;
  await assert.rejects(app.connect({ guide: () => false }), (error) => error instanceof DeclinedError && error.question === 'open');
  assert.deepEqual(env.opened, []);
});

test('without a guide, connect says which case it is', async (t) => {
  const port = await freePort();
  const env = environment();
  const app = client(t, port, env);
  await assert.rejects(app.connect(), (error) => error instanceof NotInstalledError && error.installURL === installPage && !error.onDiskImage);
  env.handler = { path: '/Volumes/Agneta/Agneta.app', identifier: agnetaID, version: '0.5.0' };
  await assert.rejects(app.connect(), (error) => error instanceof NotInstalledError && error.onDiskImage);
  env.handler = installed;
  await assert.rejects(app.connect(), NotRunningError);
  // Another app that claimed agneta:// isn't Agneta.
  env.handler = { path: '/Applications/Other.app', identifier: 'com.example.other', version: '1.0' };
  await assert.rejects(app.connect(), NotInstalledError);
  assert.deepEqual(env.opened, []);
});

test('presence: running, blocked, installed (and where), on a disk image, translocated, an impostor, a missing bundle, unknown', async (t) => {
  const behaviour = agnetaLike();
  const agneta = await standIn(behaviour.answer);
  t.after(() => agneta.close());
  assert.deepEqual(await client(t, agneta.port, environment()).presence(), { state: 'running' });
  const port = await freePort();
  assert.deepEqual((await client(t, port, environment(), { probe: async () => 'blocked' }).presence()).state, 'blocked');
  const look = async (handler, readBundle) => client(t, port, environment({ handler, readBundle })).presence();
  assert.deepEqual(await look(installed), { state: 'notRunning', location: 'applications', version: '0.5.0' });
  assert.deepEqual(await look({ ...installed, path: '/Users/someone/Applications/Agneta.app' }), { state: 'notRunning', location: 'applications', version: '0.5.0' });
  assert.deepEqual(await look({ ...installed, path: '/Users/someone/src/agneta/build/Agneta.app' }), { state: 'notRunning', location: 'elsewhere', version: '0.5.0' });
  assert.deepEqual(await look({ ...installed, path: '/Volumes/Agneta 1/Agneta.app' }), { state: 'onDiskImage' });
  assert.deepEqual(await look({ ...installed, path: '/Volumes/Agneta 1/Agneta.app', readOnly: true }), { state: 'onDiskImage' });
  // A writable volume under /Volumes (an external drive someone keeps apps on) isn't a disk image, as Agneta decides.
  assert.deepEqual(await look({ ...installed, path: '/Volumes/External/Apps/Agneta.app', readOnly: false }), { state: 'notRunning', location: 'elsewhere', version: '0.5.0' });
  assert.deepEqual(await look({ ...installed, path: '/private/var/folders/x/T/AppTranslocation/AB12/d/Agneta.app' }), { state: 'onDiskImage' });
  assert.deepEqual(await look({ ...installed, identifier: 'com.example.impostor' }), { state: 'notInstalled' });
  assert.deepEqual(await look(null), { state: 'notInstalled' });
  // Found by path only (not registered yet): the bundle says what it is; gone since, it's not installed.
  assert.deepEqual(await look({ path: '/Applications/Agneta.app' }, async () => ({ identifier: agnetaID, version: '0.4.0' })),
    { state: 'notRunning', location: 'applications', version: '0.4.0' });
  assert.deepEqual(await look({ path: '/Applications/Agneta.app' }, async () => null), { state: 'notInstalled' });
  // Nothing to look with.
  const bare = new AgnetaClient({ name: 'Example', port });
  assert.deepEqual(await bare.presence(), { state: 'unknown' });
});

test('installed, not running: asked to open; slow at the thresholds; pair never asks only someone with a kept token', async (t) => {
  const port = await freePort();
  const behaviour = agnetaLike();
  let agneta = null;
  t.after(async () => { await agneta?.close(); });
  const env = environment({ handler: installed, onOpen: () => { setTimeout(async () => { agneta = await standIn(behaviour.answer, { port }); }, 650); return true; } });
  const tokens = memoryTokenStore();
  const app = client(t, port, env, { tokens });
  // At launch, without a kept token: nothing is asked.
  const asked = [];
  await assert.rejects(app.connect({ pair: 'never', guide: yes(asked) }), NotRunningError);
  assert.deepEqual(asked, []);
  // With one (someone who has used the app): offered to open it.
  await tokens.save('kept-token');
  const steps = [];
  await app.connect({ pair: 'never', guide: yes(asked), onProgress: (progress) => steps.push(progress) });
  assert.deepEqual(asked.map(({ kind, confirm }) => [kind, confirm]), [['open', `Open ${app.agnetaName}`]]);
  const slow = steps.filter(({ step }) => step === 'slow');
  assert.deepEqual(slow.map(({ keepWaiting }) => keepWaiting), [false, true]);
  assert.ok(slow[0].detail.includes(`If macOS asks whether to open ${app.agnetaName}, choose Open`));
  assert.equal(app.state, 'connected');
});

test('a quiet connect at launch never offers to install', async (t) => {
  const port = await freePort();
  const tokens = memoryTokenStore();
  await tokens.save('kept-token');
  const asked = [];
  const env = environment();
  await assert.rejects(client(t, port, env, { tokens }).connect({ pair: 'never', guide: yes(asked) }), NotInstalledError);
  assert.deepEqual(asked, []);
  assert.deepEqual(env.opened, []);
});

test('outdated: from the bundle before opening, from the catalog\'s version, and from an Agneta without agneta/catalog', async (t) => {
  const port = await freePort();
  const env = environment({ handler: { ...installed, version: '0.4.0' } });
  await assert.rejects(client(t, port, env, { minimumVersion: '0.5.0' }).connect(),
    (error) => error instanceof OutdatedError && error.kind === 'outdated' && error.version === '0.4.0' && error.needed === '0.5.0');
  // A development build (0.0.0) is never too old.
  env.handler = { ...installed, version: '0.0.0' };
  await assert.rejects(client(t, port, env, { minimumVersion: '0.5.0' }).connect(), NotRunningError);

  const versions = { current: '0.4.9' };
  const behaviour = agnetaLike({ handlers: { 'agneta/catalog': () => versions.current === null
    ? { error: { code: -32601, message: 'Agneta doesn\'t offer agneta/catalog' } }
    : { result: { ...catalogReport(), version: versions.current } } } });
  const agneta = await standIn(behaviour.answer);
  t.after(() => agneta.close());
  const running = () => client(t, agneta.port, environment({ handler: installed }), { minimumVersion: '0.5.0' });
  await assert.rejects(running().connect(), (error) => error instanceof OutdatedError && error.version === '0.4.9');
  versions.current = null;
  await assert.rejects(running().connect(), (error) => error instanceof OutdatedError && error.version === null);
  // Without agneta/catalog it's 0.4.0 or earlier: too old for 0.5.0, not for 0.3.0.
  assert.ok((await client(t, agneta.port, environment({ handler: installed }), { minimumVersion: '0.3.0' }).connect()).providers.length);
  versions.current = '0.5.1';
  assert.ok((await running().connect()).providers.length);
});

test('outdated and running: asked once, then waits while Agneta updates and relaunches, and connects', async (t) => {
  const port = await freePort();
  const versions = { current: '0.4.9' };
  const behaviour = agnetaLike({ handlers: { 'agneta/catalog': () => ({ result: { ...catalogReport(), version: versions.current } }) } });
  let agneta = await standIn(behaviour.answer, { port });
  t.after(async () => { await agneta.close(); });
  const asked = [];
  const app = client(t, port, environment({ handler: installed }), { minimumVersion: '0.5.0' });
  const steps = [];
  const connecting = app.connect({ guide: yes(asked), onProgress: ({ step }) => steps.push(step) });
  // The user chooses Check for Updates…: Agneta quits, and the new version comes up.
  while (!steps.includes('outdated')) await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
  await agneta.close();
  versions.current = '0.5.0';
  agneta = await standIn(behaviour.answer, { port });
  assert.ok((await connecting).providers.length);
  assert.deepEqual(asked.map(({ kind, running, confirm }) => [kind, running, confirm]), [['update', true, 'Continue']]);
});

test('cancel through the signal; no timeout while the user installs', async (t) => {
  const port = await freePort();
  const app = client(t, port, environment(), { timeouts: { open: 50 } });
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 1300);
  const started = Date.now();
  await assert.rejects(app.connect({ guide: () => true, signal: controller.signal }), AbortedError);
  assert.ok(Date.now() - started >= 1200, 'installing waited past the open timeout');
  assert.equal(app.state, 'disconnected');
  // After an open, the open timeout ends the wait.
  await assert.rejects(app.waitForAgneta({ opened: true }), NotRunningError);
});

test('setup: asked, Agneta\'s window shown; a connection closed meanwhile is reopened quietly and the wait goes on', async (t) => {
  const state = { connected: false, setups: 0 };
  const behaviour = agnetaLike({ handlers: {
    'agneta/catalog': () => ({ result: catalogReport(state.connected) }),
    'agneta/setup': (message, peer) => {
      state.setups++;
      // Agneta closes the unpaired connection (its 10 minutes ran out) while the user signs in; then a provider arrives.
      setTimeout(() => peer.close(1008), 30);
      setTimeout(() => { state.connected = true; agneta.notify('agneta/catalogChanged', { catalog: catalogReport(true) }); }, 300);
      return { result: { shown: true } };
    }
  } });
  const agneta = await standIn(behaviour.answer);
  t.after(() => agneta.close());
  const asked = [];
  const app = client(t, agneta.port, environment({ handler: installed }));
  const steps = [];
  await app.connect({ setup: 'claude', guide: yes(asked), onProgress: ({ step }) => steps.push(step) });
  assert.deepEqual(asked.map(({ kind, kinds }) => [kind, kinds]), [['setup', ['claude']]]);
  assert.equal(state.setups, 1);
  assert.ok(steps.indexOf('needsProvider') < steps.indexOf('settingUp') && steps.indexOf('settingUp') < steps.indexOf('pairing'));
  assert.equal(app.state, 'connected');

  state.connected = false;
  const declining = client(t, agneta.port, environment({ handler: installed }));
  await assert.rejects(declining.connect({ setup: true, guide: () => false }), (error) => error instanceof DeclinedError && error.question === 'setup');
  assert.equal(state.setups, 1, 'nothing shown');
});

test('the install URL is exactly the page, with at most the architecture as its fragment', async (t) => {
  for (const architecture of ['arm64', 'x86_64', undefined, null, '', 'ppc', 'arm64?x=1', '#x', 'x86_64&app=Example']) {
    const url = new URL(installPageURL(installPage, architecture));
    assert.equal(`${url.origin}${url.pathname}`, 'https://agneta.dahlbom.io/get/');
    assert.equal(url.search, '');
    assert.ok(['', '#arm64', '#x86_64'].includes(url.hash), url.href);
  }
  assert.equal(installPageURL(installPage, 'x86_64'), 'https://agneta.dahlbom.io/get/#x86_64');
  // Agneta Dev's page is the README's Build and run, as it is.
  assert.equal(installPageURL('https://github.com/olofd/agneta#build-and-run', 'arm64'), 'https://github.com/olofd/agneta#build-and-run');
  const env = environment();
  const app = client(t, await freePort(), env);
  assert.equal(await app.openInstallPage({ architecture: 'x86_64' }), true);
  assert.equal(await app.openInstallPage(), true);
  assert.deepEqual(env.opened, [`${installPage}#x86_64`, `${installPage}#arm64`]);
  assert.equal(new AgnetaClient({ name: 'Example', build: 'dev' }).installURL, 'https://github.com/olofd/agneta#build-and-run');
  assert.equal(new AgnetaClient({ name: 'Example' }).homebrew, 'brew install olofd/tap/agneta');
});

test('the probe: EPERM is blocked, refused is nothing listening, any answer is listening', async () => {
  const failing = (code) => async () => { throw Object.assign(new TypeError('fetch failed'), { cause: { code } }); };
  assert.equal(await probeAgneta('ws://127.0.0.1:47321/acp', failing('EPERM')), 'blocked');
  assert.equal(await probeAgneta('ws://127.0.0.1:47321/acp', failing('ECONNREFUSED')), 'notListening');
  assert.equal(await probeAgneta('ws://127.0.0.1:47321/acp', failing('ECONNRESET')), 'listening');
  assert.equal(await probeAgneta('ws://127.0.0.1:47321/acp', async () => new Response(null, { status: 426 })), 'listening');
  const port = await freePort();
  await assert.rejects(Connection.open({ url: `ws://127.0.0.1:${port}/acp`, probe: async () => 'blocked' }),
    (error) => error instanceof NetworkBlockedError && error.kind === 'blocked' && /network\.client/.test(error.advice));
});

test('versions and places', () => {
  assert.equal(compareVersions('0.4.0', '0.5.0') < 0, true);
  assert.equal(compareVersions('0.10.0', '0.9.3') > 0, true);
  assert.equal(compareVersions('1.2', '1.2.0'), 0);
  assert.equal(compareVersions('0.0.0', '0.5.0'), null);
  assert.equal(compareVersions('dev', '0.5.0'), null);
  assert.equal(placement('/Applications/Agneta.app', '/Users/someone'), 'applications');
  assert.equal(placement('/Users/someone/Applications/Agneta.app', '/Users/someone/'), 'applications');
  assert.equal(placement('/Applications/Utilities/Agneta.app', '/Users/someone'), 'elsewhere');
  assert.equal(placement('/Volumes/Agneta/Agneta.app'), 'diskImage');
});

test('cancelling stops everything: a guide still asking, a late yes, a lookup under way; nothing is opened after', async (t) => {
  const port = await freePort();
  // A guide that never answers: Cancel ends the connect at once.
  let env = environment();
  const controller = new AbortController();
  const hanging = client(t, port, env).connect({ guide: () => new Promise(() => {}), signal: controller.signal });
  setTimeout(() => controller.abort(), 50);
  await assert.rejects(hanging, AbortedError);
  assert.deepEqual(env.opened, []);
  // A yes that comes after Cancel counts for nothing: the install page isn't opened.
  env = environment();
  const late = new AbortController();
  const answer = client(t, port, env).connect({ signal: late.signal, guide: () => new Promise((resolve) => { late.abort(); setTimeout(() => resolve(true), 20); }) });
  await assert.rejects(answer, AbortedError);
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.deepEqual(env.opened, []);
  // Cancel while the install wait looks: Agneta, found installed, isn't opened.
  env = environment();
  const looking = new AbortController();
  let looks = 0;
  env.findHandler = async () => {
    if (++looks === 1) return null;
    looking.abort();
    return installed;
  };
  await assert.rejects(client(t, port, env).connect({ guide: () => true, signal: looking.signal }), AbortedError);
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.deepEqual(env.opened, [`${installPage}#arm64`], 'only the page the user asked for');
});

test('opening Agneta once installed is tried again when it fails', async (t) => {
  const port = await freePort();
  const behaviour = agnetaLike();
  let agneta = null;
  t.after(async () => { await agneta?.close(); });
  let tries = 0;
  const env = environment({ handler: installed, onOpen: () => {
    if (++tries === 1) return false;
    setTimeout(async () => { agneta = await standIn(behaviour.answer, { port }); }, 50);
    return true;
  } });
  const app = client(t, port, env);
  const connection = await app.waitForAgneta({ installing: true, openWhenInstalled: true, timeout: 8000 });
  assert.ok(connection.isOpen);
  assert.equal(tries, 2);
});

test('minimumVersion must be a version', () => {
  for (const bad of ['', 'latest', '0.5.0-beta', '1.2.3.4', 'v1']) {
    assert.throws(() => new AgnetaClient({ name: 'Example', minimumVersion: bad }), TypeError, bad);
  }
  assert.equal(new AgnetaClient({ name: 'Example', minimumVersion: '1' }).options.minimumVersion, '1');
  // Found versions compare by their numbers only.
  assert.equal(compareVersions('0.5.0-beta', '0.5.0'), 0);
});

test('waiting for Agneta while something else opens the connection leaves one socket', async (t) => {
  const behaviour = agnetaLike();
  const agneta = await standIn(behaviour.answer);
  t.after(() => agneta.close());
  const app = client(t, agneta.port, environment({ handler: installed }));
  const [opened, waited] = await Promise.all([app.open(), app.waitForAgneta()]);
  assert.equal(opened, waited);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(agneta.peers.length, 1);
});
