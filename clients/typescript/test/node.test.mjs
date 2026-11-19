// The Node environment on a real Mac: LaunchServices through osascript, bundles through plutil, the Mac's architecture.
// Skipped elsewhere (the package's Linux CI).
import assert from 'node:assert/strict';
import test from 'node:test';
import { AgnetaClient } from '../dist/index.js';
import { electronEnvironment, findInFolders, isReadOnly, macArchitecture, nodeEnvironment, readBundle } from '../dist/node.js';

const mac = process.platform === 'darwin';

test('nodeEnvironment finds the app for a scheme, with its bundle, and nothing for an unknown one, each within a second', { skip: !mac && 'macOS only' }, async () => {
  const environment = nodeEnvironment();
  let started = performance.now();
  const mail = await environment.findHandler('mailto:someone@example.com');
  assert.ok(performance.now() - started < 1000, 'a lookup takes well under a second');
  assert.match(mail.path, /\.app$/);
  assert.equal(typeof mail.identifier, 'string');
  started = performance.now();
  assert.equal(await environment.findHandler('agneta-test-no-such-scheme-7f3a://open'), null);
  assert.ok(performance.now() - started < 1000);
  const bundle = await readBundle(mail.path);
  assert.equal(bundle.identifier, mail.identifier);
  assert.equal(await readBundle('/nonexistent/Nothing.app'), null);
  assert.ok(['arm64', 'x86_64'].includes(await macArchitecture()));
});

test('a known build is found by its name in the Applications folders given, read-only or not', { skip: !mac && 'macOS only' }, async (t) => {
  const { mkdtemp, mkdir, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const folder = await mkdtemp(join(tmpdir(), 'agneta-client-apps-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  assert.equal(await findInFolders('agneta-dev://open', [folder]), null);
  await mkdir(join(folder, 'Agneta Dev.app', 'Contents'), { recursive: true });
  assert.deepEqual(await findInFolders('agneta-dev://open', [folder]), { path: join(folder, 'Agneta Dev.app'), readOnly: false });
  // Only the builds' own URLs are looked for by name.
  assert.equal(await findInFolders('mailto:someone@example.com', [folder]), null);
  assert.equal(await isReadOnly(folder), false);
  // The sealed system volume is read-only, as a disk image is.
  assert.equal(await isReadOnly('/System/Applications/Mail.app'), true);
});

test('off macOS the environments know nothing and open nothing', async (t) => {
  const real = Object.getOwnPropertyDescriptor(process, 'platform');
  Object.defineProperty(process, 'platform', { value: 'linux' });
  t.after(() => Object.defineProperty(process, 'platform', real));
  const shell = { openExternal: async () => { throw new Error('opened'); }, openPath: async () => { throw new Error('opened'); } };
  const app = { getApplicationInfoForProtocol: async () => { throw new Error('asked'); } };
  for (const environment of [nodeEnvironment(), electronEnvironment({ app, shell })]) {
    await assert.rejects(environment.findHandler('agneta://open'));
    assert.equal(await environment.openURL('agneta://open'), false);
    assert.equal(await environment.openURL('https://agneta.dahlbom.io/get/'), false);
    assert.equal(await environment.architecture(), null);
  }
  const { createServer } = await import('node:net');
  const server = createServer().listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  const client = new AgnetaClient({ name: 'Example', port, openURL: 'agneta://open', environment: nodeEnvironment() });
  assert.deepEqual(await client.presence(), { state: 'unknown' });
});
