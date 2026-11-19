import assert from 'node:assert/strict';
import { access, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { policyFor } from '../run.mjs';
import { toolchainEnvironment, toolchainFolders } from '../toolchain.mjs';
import { benchHome, createRun, listFiles, otherRuns } from '../workspace.mjs';

test('a run gets the scaffold, the gateway address, git, and a held-out set outside its workspace', async (t) => {
  const home = await mkdtemp(join(tmpdir(), 'replica-bench-home-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const run = await createRun(home, { label: 'explore goose/contained', gateway: { host: '127.0.0.1', port: 47999, token: 'secret' } });
  assert.match(run.id, /^\d{8}-\d{6}-explore-goose-contained-[0-9a-f]{4}$/);
  for (const path of ['README.md', 'candidate/Cargo.toml', 'candidate/src/lib.rs', 'candidate/src/main.rs', 'candidate/src/json.rs', 'kit/rb.py']) {
    await access(join(run.workspace, path));
  }
  assert.deepEqual(JSON.parse(await readFile(join(run.workspace, 'kit/gateway.json'), 'utf8')), { host: '127.0.0.1', port: 47999, token: 'secret' });
  assert.equal((await readFile(join(run.workspace, 'candidate/Cargo.toml'), 'utf8')).match(/^\[dependencies\]\n(\S)/m), null, 'no dependencies');
  if (run.repository) assert.ok((await stat(join(run.workspace, '.git'))).isDirectory());

  const held = JSON.parse(await readFile(join(run.referee, 'heldout.json'), 'utf8'));
  assert.equal(held.cases.length, 24);
  assert.ok(held.cases.every((entry) => !('outputs' in entry)), 'expected outputs are never written down');
  assert.equal((await stat(join(run.referee, 'heldout.json'))).mode & 0o777, 0o600);
  for (const folder of run.denied) assert.ok(!folder.startsWith(run.workspace), `${folder} lies outside the workspace`);
  assert.ok(run.referee.startsWith(run.denied[0]) && run.build.startsWith(run.denied[1]));

  const policy = policyFor(run, { sandbox: 'contained', gatewayPort: 47999 });
  const environment = toolchainEnvironment(run.workspace);
  assert.deepEqual(policy, {
    tools: 'workspace', network: 'none', approval: 'never-ask', readable: [], writable: [],
    readOnly: [join(run.workspace, 'kit'), join(run.workspace, '.git'), ...(environment ? toolchainFolders() : [])], denied: run.denied,
    toolPorts: [47999], sandbox: 'contained', limits: { maxTurns: 400, maxSeconds: 5400 }, ...(environment ? { toolEnvironment: environment } : {})
  });
  // The mode is always sent; developer sessions find the user's toolchains themselves; no gateway means no toolPorts.
  const asked = policyFor(run, { sandbox: 'developer', gatewayPort: 1 });
  assert.equal(asked.sandbox, 'developer');
  assert.equal(asked.toolEnvironment, undefined);
  assert.ok(!('access' in asked) && !('access' in policy));
  assert.deepEqual(policyFor(run, { sandbox: 'contained' }).toolPorts, []);

  // A developer session also denies every other run's workspace, never its own.
  const other = await createRun(home, { label: 'other' });
  assert.deepEqual(await otherRuns(home, run.workspace), [other.workspace]);
  const developer = policyFor(run, { sandbox: 'developer', gatewayPort: 1, others: await otherRuns(home, run.workspace) });
  assert.deepEqual(developer.denied, [...run.denied, other.workspace]);
  assert.deepEqual(policyFor(run, { sandbox: 'contained', gatewayPort: 1, others: [other.workspace] }).denied, run.denied);

  const files = (await listFiles(run.workspace)).map(({ path }) => path).sort();
  assert.ok(files.includes('kit/rb.py') && files.includes('candidate/src/lib.rs'));
  assert.ok(!files.some((path) => path.startsWith('.git/')));
});

test('the bench folder is never the home folder or inside ~/Library', async () => {
  await assert.rejects(benchHome({ REPLICA_BENCH_HOME: 'relative/path' }), /absolute/);
  await assert.rejects(benchHome({ REPLICA_BENCH_HOME: join(homedir(), 'Library', 'Replica Bench Test Never Made') }), /inside ~\/Library/);
  await assert.rejects(benchHome({ REPLICA_BENCH_HOME: homedir() }), /whole home folder/);
});
