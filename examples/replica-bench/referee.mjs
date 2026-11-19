// The referee: builds the submitted candidate and scores it on the held-out set, in the app, outside the agent.
// The agent can write anything into its crate, so the referee copies it out of the workspace first (no symlinks, so
// nothing can change between the check and the build), refuses dependencies and build scripts (the only ways a
// build runs the agent's code), and runs cargo and the candidate under sandbox-exec with no network and the
// referee's folder unreadable: neither include_str! at build time nor the candidate at run time can read the
// held-out set. The candidate gets the held-out inputs on stdin; the expected outputs exist only in memory here.
import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { access, copyFile, lstat, mkdir, readdir, readFile, realpath, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { delimiter, dirname, join, relative, sep } from 'node:path';
import { evaluate } from './target.mjs';

/** Relative RMS error (dB) at or below which a candidate counts as a clone. */
export const passDb = -100;

/** cargo on PATH, else rustup's usual place (an app opened from Finder has a short PATH). */
export async function findCargo(env = process.env) {
  const candidates = [...(env.PATH ?? '').split(delimiter).filter(Boolean).map((folder) => join(folder, 'cargo')), join(homedir(), '.cargo', 'bin', 'cargo')];
  for (const path of candidates) {
    try {
      await access(path, constants.X_OK);
      return path;
    } catch {}
  }
  return null;
}

const sandboxExec = '/usr/bin/sandbox-exec';
const quote = (path) => JSON.stringify(path);

/** The profile cargo and the candidate run under: no network, the referee's folder unreadable, writes only where named. */
export function profile({ unreadable, writable }) {
  return [
    '(version 1)',
    '(allow default)',
    '(deny network*)',
    ...unreadable.map((path) => `(deny file-read* file-write* (subpath ${quote(path)}))`),
    '(deny file-write*)',
    `(allow file-write* ${[...writable, '/dev', '/private/var/folders', '/private/tmp'].map((path) => `(subpath ${quote(path)})`).join(' ')})`
  ].join('\n');
}

async function sandboxed() {
  try {
    await access(sandboxExec, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Runs a program with a time limit, capturing at most `maxBytes` of stdout and the end of stderr. */
function run(command, args, { cwd, env, input, timeout, maxBytes = 64 * 1024 * 1024 }) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], detached: true });
    const out = [];
    let size = 0, stderr = '', overflow = false, timedOut = false;
    // The whole process group, so a build's rustc children stop with it.
    const stop = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeout);
    child.stdout.on('data', (data) => {
      size += data.length;
      if (size > maxBytes) { overflow = true; stop(); } else out.push(data);
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (text) => { stderr = (stderr + text).slice(-8000); });
    child.on('error', (error) => { stderr += error.message; });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout: Buffer.concat(out).toString('utf8'), stderr, timedOut, overflow });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(input ?? '');
  });
}

/** Copies the crate's sources (no target/, no .git, no symlinks) to where the referee builds it. */
async function copyCrate(from, to) {
  await rm(to, { recursive: true, force: true });
  await mkdir(to, { recursive: true });
  let files = 0;
  async function walk(folder) {
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      const source = join(folder, entry.name);
      const target = join(to, relative(from, source));
      if (entry.isSymbolicLink()) throw new Error(`${relative(from, source)} is a symbolic link; the referee builds plain files only`);
      if (entry.isDirectory()) {
        if (['target', '.git', '.cargo'].includes(entry.name)) continue;
        await mkdir(target, { recursive: true });
        await walk(source);
      } else if (entry.isFile()) {
        if (++files > 500) throw new Error('the crate has more than 500 files');
        if ((await lstat(source)).size > 4 * 1024 * 1024) throw new Error(`${relative(from, source)} is over 4 MB`);
        await copyFile(source, target);
      }
    }
  }
  await walk(from);
}

/**
 * Why the referee won't build this crate, or null. Dependencies, build scripts, proc macros and workspace members are
 * the ways a build runs code the agent wrote, so a candidate has none of them.
 */
export function refusal(manifest, hasBuildScript) {
  if (hasBuildScript) return 'the crate has a build.rs; the referee builds candidates without build scripts';
  const dependencyTable = /^(target\..+\.)?(build-)?dependencies$/;
  const dependencyEntry = /^(target\..+\.)?(build-)?dependencies\..+$/;
  let section = '';
  for (const raw of manifest.split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) continue;
    const header = line.match(/^\[+\s*([^\]]+?)\s*\]+$/);
    if (header) {
      section = header[1];
      if (dependencyEntry.test(section)) return `the crate has a dependency ([${section}]); candidates build offline with none`;
      if (section === 'workspace' || section.startsWith('workspace.')) return 'the crate declares a workspace; submit a single crate';
      continue;
    }
    if (dependencyTable.test(section)) return `the crate has a dependency in [${section}]; candidates build offline with none`;
    if (section === 'package' && /^build\s*=\s*["']/.test(line)) return 'the crate names a build script; the referee builds candidates without build scripts';
    if (section === 'lib' && /^proc-macro\s*=\s*true/.test(line)) return 'the crate is a proc macro';
    if (/^(build-)?dependencies\s*=/.test(line)) return 'the crate has dependencies; candidates build offline with none';
  }
  return null;
}

function stats(expected, actual) {
  let maxAbs = 0, errorSquares = 0, targetSquares = 0, samples = 0;
  for (const [index, target] of expected.entries()) {
    const got = actual?.[index];
    if (!Array.isArray(got) || got.length !== target.length) return { maxAbs: Infinity, rmsErrorDb: Infinity, note: `case ${index} has ${Array.isArray(got) ? got.length : 'no'} outputs for ${target.length} inputs` };
    for (const [n, value] of target.entries()) {
      const error = typeof got[n] === 'number' ? got[n] - value : NaN;
      if (!Number.isFinite(error)) return { maxAbs: Infinity, rmsErrorDb: Infinity, note: `case ${index} has a NaN or null output` };
      maxAbs = Math.max(maxAbs, Math.abs(error));
      errorSquares += error * error;
      targetSquares += value * value;
      samples += 1;
    }
  }
  const rmsError = Math.sqrt(errorSquares / samples), rmsTarget = Math.sqrt(targetSquares / samples);
  return {
    maxAbs,
    rmsErrorDb: rmsError === 0 ? -Infinity : 20 * Math.log10(rmsError / rmsTarget),
    rmsErrorDbfs: rmsError === 0 ? -Infinity : 20 * Math.log10(rmsError),
    samples
  };
}

/**
 * Builds the crate at `crate` (inside the workspace) and scores it on `cases`. `run` is the run from createRun:
 * its build folder holds the copy and cargo's target folder; its referee folder (and every run's) stays unreadable.
 */
export async function score({ crate, cases, build, unreadable, cargo, timeouts = { build: 600_000, run: 120_000 } }) {
  const started = Date.now();
  const result = (fields) => ({ cases: cases.length, threshold: passDb, ms: Date.now() - started, ...fields });
  if (!cargo) return result({ ok: false, stage: 'build', message: "The referee couldn't find cargo on this Mac, so it can't build candidates. Install Rust (rustup), then score again." });
  const copy = join(build, 'crate');
  try {
    await copyCrate(crate, copy);
  } catch (error) {
    return result({ ok: false, stage: 'build', message: `The referee couldn't copy the crate: ${error.message}.` });
  }
  let manifest;
  try {
    manifest = await readFile(join(copy, 'Cargo.toml'), 'utf8');
  } catch {
    return result({ ok: false, stage: 'build', message: 'The candidate folder has no Cargo.toml.' });
  }
  const refused = refusal(manifest, await access(join(copy, 'build.rs')).then(() => true, () => false));
  if (refused) return result({ ok: false, stage: 'build', message: `The referee refused the crate: ${refused}.` });

  const box = await sandboxed();
  // Seatbelt matches real paths only (/private/var, not /var).
  unreadable = await Promise.all(unreadable.map((path) => realpath(path).catch(() => path)));
  const target = join(build, 'target');
  const wrap = (command, args, writable) => box ? [sandboxExec, ['-p', profile({ unreadable, writable }), command, ...args]] : [command, args];
  const env = { ...process.env, PATH: [dirname(cargo), process.env.PATH].filter(Boolean).join(delimiter), CARGO_TERM_COLOR: 'never' };
  for (const name of ['RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_TARGET_DIR']) delete env[name];
  const cargoHome = await realpath(env.CARGO_HOME ?? join(homedir(), '.cargo')).catch(() => join(homedir(), '.cargo'));
  const buildStarted = Date.now();
  const [buildCommand, buildArgs] = wrap(cargo, ['build', '--release', '--offline', '--quiet', '--manifest-path', join(copy, 'Cargo.toml'), '--target-dir', target],
    [build, cargoHome, join(homedir(), '.rustup')]);
  const built = await run(buildCommand, buildArgs, { cwd: build, env, timeout: timeouts.build, maxBytes: 1024 * 1024 });
  const buildMs = Date.now() - buildStarted;
  if (built.code !== 0) {
    const why = built.timedOut ? `the build took longer than ${timeouts.build / 1000} s` : `cargo build failed (exit ${built.code ?? built.signal})`;
    return result({ ok: false, stage: 'build', buildMs, sandboxed: box, message: `The referee's build failed: ${why}.`, stderr: built.stderr.slice(-4000) });
  }

  const binary = join(target, 'release', 'candidate');
  try {
    if (!(await realpath(binary)).startsWith((await realpath(target)) + sep)) throw new Error('outside');
  } catch {
    return result({ ok: false, stage: 'build', buildMs, message: 'The build made no binary named candidate; keep the [[bin]] in Cargo.toml.' });
  }
  const input = JSON.stringify({ cases: cases.map(({ params, inputs }) => ({ params, inputs })) });
  const runStarted = Date.now();
  const [runCommand, runArgs] = wrap(binary, [], []);
  const ran = await run(runCommand, runArgs, { cwd: build, env: { PATH: '/usr/bin:/bin' }, input, timeout: timeouts.run });
  const runMs = Date.now() - runStarted;
  if (ran.code !== 0) {
    const why = ran.timedOut ? `it ran longer than ${timeouts.run / 1000} s` : ran.overflow ? 'it wrote too much' : `it exited ${ran.code ?? ran.signal}`;
    return result({ ok: false, stage: 'run', buildMs, runMs, sandboxed: box, message: `The candidate failed on the held-out set: ${why}.`, stderr: ran.stderr.slice(-4000) });
  }
  let outputs;
  try {
    outputs = JSON.parse(ran.stdout).outputs;
  } catch {
    return result({ ok: false, stage: 'run', buildMs, runMs, sandboxed: box, message: 'The candidate\'s output wasn\'t {"outputs": [[...], ...]}.' });
  }
  const expected = cases.map(({ inputs, params }) => evaluate(inputs, params));
  const { maxAbs, rmsErrorDb, rmsErrorDbfs, samples, note } = stats(expected, outputs);
  return result({
    ok: true, stage: 'score', buildMs, runMs, sandboxed: box, samples, maxAbsError: maxAbs, rmsErrorDb, rmsErrorDbfs,
    passed: rmsErrorDb <= passDb, message: note ?? null
  });
}

/** One line an agent or a person reads: what the score means. */
export function describeScore(scored) {
  if (!scored.ok) return [scored.message, scored.stderr ? `\n${scored.stderr}` : ''].join('');
  const db = (value) => Number.isFinite(value) ? `${value.toFixed(1)} dB` : value < 0 ? '-inf dB (exact)' : 'n/a';
  return [
    `Scored on ${scored.cases} held-out cases (${scored.samples ?? 0} samples): max abs error ${scored.maxAbsError === Infinity ? 'n/a' : scored.maxAbsError.toExponential(3)},`,
    `RMS error ${db(scored.rmsErrorDb)} relative to the target.`,
    scored.passed ? `That's a clone (the bar is ${passDb} dB).` : `The bar is ${passDb} dB.`,
    scored.message ? `Note: ${scored.message}.` : ''
  ].filter(Boolean).join(' ');
}
