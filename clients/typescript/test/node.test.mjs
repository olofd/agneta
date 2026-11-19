// The Node environment on a real Mac: LaunchServices through osascript, bundles through plutil, the Mac's architecture.
// Skipped elsewhere (the package's Linux CI).
import assert from 'node:assert/strict';
import test from 'node:test';
import { macArchitecture, nodeEnvironment, readBundle } from '../dist/node.js';

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

test('a known build found by path when LaunchServices has nothing (a copy just put in ~/Applications)', { skip: !mac && 'macOS only' }, async (t) => {
  const { mkdtemp, mkdir, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const home = await mkdtemp(join(tmpdir(), 'agneta-client-home-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  // A scheme no app on this Mac handles, but a known build's: only a release or Dev openURL is looked for by path.
  const environment = nodeEnvironment({ home });
  const dev = await environment.findHandler('agneta-dev://open');
  // On a Mac with Agneta Dev registered, LaunchServices answers; otherwise the folder is looked in.
  if (dev === null || !dev.path.startsWith(home)) {
    await mkdir(join(home, 'Applications', 'Agneta Dev.app', 'Contents'), { recursive: true });
    const found = await nodeEnvironment({ home }).findHandler('agneta-dev://open');
    if (dev === null) assert.equal(found.path, join(home, 'Applications', 'Agneta Dev.app'));
  }
});
