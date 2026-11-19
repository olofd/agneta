// Where runs live, and what each run's workspace starts with. A run gets a fresh folder shaped like a demanding app's project
// (a Rust crate, a probe kit, a guide, a git repository), inside the bench's data folder, which the pairing scope
// grants. The referee's held-out set and its build folder sit beside the runs, in folders every session's policy
// lists as denied: the agent never reads what it is scored on.
import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { cp, lstat, mkdir, readdir, realpath, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { heldOut } from './target.mjs';

const scaffold = fileURLToPath(new URL('./scaffold/', import.meta.url));

/**
 * The bench's data folder: REPLICA_BENCH_HOME, else ~/Documents/Replica Bench. Never inside ~/Library, which Agneta
 * keeps out of every session (Application Support, containers, Keychains), and never the home folder itself.
 */
export async function benchHome(env = process.env) {
  const chosen = env.REPLICA_BENCH_HOME || join(homedir(), 'Documents', 'Replica Bench');
  if (!isAbsolute(chosen)) throw new Error('REPLICA_BENCH_HOME must be an absolute path.');
  const user = await realpath(homedir());
  const check = (path) => {
    const library = join(user, 'Library');
    if (path === user || user.startsWith(path + sep)) throw new Error(`${path} contains your whole home folder; choose a folder of its own.`);
    if (path === library || path.startsWith(library + sep)) throw new Error(`${path} is inside ~/Library, which Agneta keeps out of every task; choose another folder.`);
  };
  // As given before anything is made, and as resolved (through symlinks) after.
  check(resolve(chosen).replace(homedir(), user));
  await mkdir(chosen, { recursive: true });
  const home = await realpath(chosen);
  check(home);
  return home;
}

/** The folders of one bench home: runs (workspaces), and the referee's held-out sets and builds, which are denied. */
export function layout(home) {
  return { runs: join(home, 'runs'), referee: join(home, 'referee'), builds: join(home, 'builds') };
}

function stamp(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

function git(args, cwd) {
  return new Promise((resolve) => {
    execFile('git', args, { cwd, timeout: 15_000 }, (error) => resolve(!error));
  });
}

/**
 * Makes a run: its workspace from the scaffold, the gateway's address for the kit, a git repository, and the held-out
 * set in the referee's folder. `label` names the run's folder (scenario, engine, access).
 */
export async function createRun(home, { label = 'run', gateway, seed = randomBytes(4).readUInt32BE(0) } = {}) {
  const folders = layout(home);
  const id = `${stamp()}-${label.replace(/[^a-z0-9-]+/gi, '-').slice(0, 60)}-${randomBytes(2).toString('hex')}`;
  const workspace = join(folders.runs, id);
  const referee = join(folders.referee, id);
  const build = join(folders.builds, id);
  await mkdir(folders.runs, { recursive: true });
  await cp(scaffold, workspace, { recursive: true, errorOnExist: true, force: false });
  await mkdir(referee, { recursive: true, mode: 0o700 });
  await mkdir(build, { recursive: true, mode: 0o700 });
  if (gateway) {
    await writeFile(join(workspace, 'kit', 'gateway.json'), JSON.stringify({ host: gateway.host, port: gateway.port, token: gateway.token }, null, 2) + '\n');
  }
  const cases = heldOut(seed);
  await writeFile(join(referee, 'heldout.json'), JSON.stringify({ seed, cases }), { mode: 0o600 });
  // An initial commit makes it look like a project the agent was handed; without git the run goes on.
  const repository = await git(['-c', 'init.defaultBranch=main', 'init', '-q'], workspace)
    && await git(['add', '-A'], workspace)
    && await git(['-c', 'user.name=Replica Bench', '-c', 'user.email=bench@example.invalid', '-c', 'core.hooksPath=/dev/null',
      'commit', '-q', '-m', 'Start of the run'], workspace);
  return {
    id,
    workspace: await realpath(workspace),
    referee: await realpath(referee),
    build: await realpath(build),
    heldOut: cases,
    repository,
    denied: [await realpath(folders.referee), await realpath(folders.builds)],
    readOnly: [join(await realpath(workspace), 'kit'), join(await realpath(workspace), '.git')]
  };
}

/**
 * The other runs' workspaces in this bench folder, for a developer session's `denied` list: developer access reads
 * the home folder, and the bench folder can't be denied as a whole (it holds the session's own workspace), so each
 * other run is named. Runs made later aren't covered; the runner makes them one at a time.
 */
export async function otherRuns(home, own) {
  const runs = layout(home).runs;
  const entries = await readdir(runs, { withFileTypes: true }).catch(() => []);
  const folders = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const folder = await realpath(join(runs, entry.name)).catch(() => null);
    if (folder && folder !== own) folders.push(folder);
  }
  return folders.sort();
}

/**
 * What the workspace holds now: each file's path, size and modification time, so checks can see what the agent made.
 * Build output (target/), git's own files and Python's caches are left out; at most `limit` entries.
 */
export async function listFiles(workspace, { limit = 4000 } = {}) {
  const files = [];
  async function walk(folder) {
    let entries;
    try { entries = await readdir(folder, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (files.length >= limit) return;
      const path = join(folder, entry.name);
      if (entry.isDirectory()) {
        if (['.git', 'target', '__pycache__', 'node_modules'].includes(entry.name)) continue;
        await walk(path);
      } else {
        try {
          const info = await lstat(path);
          files.push({ path: relative(workspace, path), size: info.size, modified: info.mtimeMs });
        } catch {}
      }
    }
  }
  await walk(workspace);
  return files;
}
