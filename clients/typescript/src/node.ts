/// <reference types="node" />
// Node and Electron-main helpers: token stores on disk (plain, or encrypted with Electron's safeStorage), finding and
// opening Agneta on this Mac (an environment for the client, for Node and for Electron), and finding which Agneta is
// running. Kept apart so the core needs nothing from Node.
import { execFile } from 'node:child_process';
import { chmod, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { createConnection } from 'node:net';
import { homedir, machine } from 'node:os';
import { dirname, join } from 'node:path';
import { lookUpAgneta, type AgnetaEnvironment, type AgnetaHandler, type Architecture } from './install.js';
import { builds, type Build } from './protocol.js';
import type { TokenStore } from './tokens.js';

/**
 * Keeps the token in a file only the user can read (mode 0600). Prefer `safeStorageTokenStore` in Electron, or the
 * Keychain: the file holds the token as it is. Keep one file per Agneta build.
 */
export function fileTokenStore(path: string): TokenStore {
  return {
    async load() {
      try {
        const text = (await readFile(path, 'utf8')).trim();
        return text || null;
      } catch {
        return null;
      }
    },
    async save(token) {
      await mkdir(dirname(path), { recursive: true, mode: 0o700 });
      // A new file, owner-only from its first byte, then renamed over the old one: never a half-written token, and
      // never one readable by others even if the old file's mode was looser.
      const temporary = `${path}.${process.pid}.tmp`;
      await writeFile(temporary, token, { mode: 0o600, flag: 'w' });
      await chmod(temporary, 0o600);
      await rename(temporary, path);
    },
    async clear() {
      await rm(path, { force: true });
    }
  };
}

/** What `safeStorageTokenStore` needs of Electron's `safeStorage`. */
export interface SafeStorageLike {
  isEncryptionAvailable(): boolean;
  encryptString(text: string): Buffer;
  decryptString(encrypted: Buffer): string;
}

/**
 * Keeps the token in a file encrypted with Electron's `safeStorage`, whose key is in the user's login Keychain. Pass
 * Electron's `safeStorage` (main process, after `app` is ready). Where encryption isn't available nothing is kept,
 * and the app pairs again next launch.
 */
export function safeStorageTokenStore(safeStorage: SafeStorageLike, path: string): TokenStore {
  return {
    async load() {
      try {
        return safeStorage.decryptString(await readFile(path)) || null;
      } catch {
        return null;
      }
    },
    async save(token) {
      if (!safeStorage.isEncryptionAvailable()) return;
      await mkdir(dirname(path), { recursive: true, mode: 0o700 });
      await writeFile(path, safeStorage.encryptString(token), { mode: 0o600 });
    },
    async clear() {
      await rm(path, { force: true });
    }
  };
}

/**
 * Opens Agneta with macOS's `open` (`agneta://open`, or `agneta-dev://open` for `dev`). Only after asking the user:
 * quitting Agneta is how they stop all of it. Resolves to whether macOS opened it (false when it isn't installed).
 */
export function openAgneta(build: Build | { openURL: string } = 'release'): Promise<boolean> {
  return nodeEnvironment().openURL(typeof build === 'string' ? builds[build].openURL : build.openURL);
}

// MARK: Finding Agneta

/**
 * Asks LaunchServices for the app that opens a URL, and that bundle's identifier and version, in one call: JavaScript
 * for Automation through `osascript`, using AppKit's `NSWorkspace` and `NSBundle`. It sends no Apple Events (so no
 * Automation prompt); measured at 110–160 ms. Prints JSON, or nothing when no app opens the URL.
 */
const lookupScript = `ObjC.import('AppKit');
function run(argv) {
  const url = $.NSURL.URLWithString(argv[0]);
  if (url.isNil()) return '';
  const app = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(url);
  if (app.isNil()) return '';
  const bundle = $.NSBundle.bundleWithURL(app);
  const info = bundle.isNil() ? null : bundle.infoDictionary;
  const value = (key) => { if (!info || info.isNil()) return null; const v = info.objectForKey(key); return v.isNil() ? null : ObjC.unwrap(v); };
  return JSON.stringify({ path: ObjC.unwrap(app.path), identifier: value('CFBundleIdentifier'), version: value('CFBundleShortVersionString') });
}`;

function run(file: string, args: string[], timeout = 5000): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(file, args, { timeout, maxBuffer: 1 << 20 }, (error, stdout) => resolve(error ? null : String(stdout)));
  });
}

/**
 * A known build's copy in `/Applications` or `~/Applications`, by its name. LaunchServices doesn't see a copy just
 * put in `~/Applications` until something opens it (measured: not within 70 s), and `osascript` may be missing.
 */
async function inApplications(url: string, home: string): Promise<AgnetaHandler | null> {
  const build = Object.values(builds).find((entry) => entry.openURL === url);
  if (!build) return null;
  for (const folder of ['/Applications', join(home, 'Applications')]) {
    const path = join(folder, `${build.name}.app`);
    if (await stat(path).then((found) => found.isDirectory(), () => false)) return { path };
  }
  return null;
}

/** The bundle's identifier and version, read with `plutil` (binary or XML plists); null when there's no bundle there. */
export async function readBundle(path: string): Promise<{ identifier: string | null; version: string | null } | null> {
  const plist = join(path, 'Contents', 'Info.plist');
  if (!await stat(plist).then((found) => found.isFile(), () => false)) return null;
  const read = async (key: string) => (await run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', plist]))?.trim() || null;
  const [identifier, version] = await Promise.all([read('CFBundleIdentifier'), read('CFBundleShortVersionString')]);
  return { identifier, version };
}

/**
 * The Mac's architecture: `arm64` on Apple silicon even when this process is an Intel build running under Rosetta
 * (`sysctl.proc_translated` is 1 there), else `x86_64`.
 */
export async function macArchitecture(): Promise<Architecture> {
  if (machine() === 'arm64') return 'arm64';
  return (await run('/usr/sbin/sysctl', ['-n', 'sysctl.proc_translated']))?.trim() === '1' ? 'arm64' : 'x86_64';
}

/** Opens a URL; when that fails for a known build's URL (not registered yet), opens its copy in Applications by path. */
async function openWith(url: string, home: string, open: (target: string) => Promise<boolean>, openPath: (path: string) => Promise<boolean>): Promise<boolean> {
  if (await open(url)) return true;
  const copy = await inApplications(url, home);
  return copy ? openPath(copy.path) : false;
}

/**
 * The client's environment in Node (and any process that may run `osascript`): LaunchServices through JavaScript for
 * Automation, then a look in the Applications folders; `plutil` for bundles; `/usr/bin/open` to open (an `https` URL
 * in the default browser). A lookup costs about a tenth of a second, so while the user installs it looks every 2 s.
 */
export function nodeEnvironment(options: { home?: string } = {}): AgnetaEnvironment {
  const home = options.home ?? homedir();
  const open = async (target: string) => (await run('/usr/bin/open', [target], 15_000)) !== null;
  return {
    home,
    lookupInterval: 2000,
    async findHandler(url) {
      const output = (await run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', lookupScript, url]))?.trim();
      if (output) {
        try {
          const found = JSON.parse(output) as AgnetaHandler;
          if (typeof found.path === 'string' && found.path) return found;
        } catch {}
      }
      return inApplications(url, home);
    },
    readBundle,
    openURL: (url) => openWith(url, home, open, open),
    architecture: macArchitecture
  };
}

/** What `electronEnvironment` needs of Electron's `app`. */
export interface ElectronAppLike {
  getApplicationInfoForProtocol(url: string): Promise<{ name: string; path: string }>;
}

/** What `electronEnvironment` needs of Electron's `shell`. */
export interface ElectronShellLike {
  openExternal(url: string): Promise<void>;
  /** Resolves to an error message, empty on success. */
  openPath(path: string): Promise<string>;
}

/**
 * The client's environment in Electron's main process: `app.getApplicationInfoForProtocol` (LaunchServices, about a
 * millisecond), then a look in the Applications folders; `plutil` for bundles; `shell.openExternal` to open. Pass
 * Electron's `app` and `shell`: the library never imports Electron.
 */
export function electronEnvironment({ app, shell }: { app: ElectronAppLike; shell: ElectronShellLike }, options: { home?: string } = {}): AgnetaEnvironment {
  const home = options.home ?? homedir();
  return {
    home,
    lookupInterval: 1000,
    async findHandler(url) {
      const info = await app.getApplicationInfoForProtocol(url).catch(() => null);
      return info?.path ? { path: info.path } : inApplications(url, home);
    },
    readBundle,
    openURL: (url) => openWith(url, home, (target) => shell.openExternal(target).then(() => true, () => false),
      (path) => shell.openPath(path).then((error) => !error, () => false)),
    architecture: macArchitecture
  };
}

/**
 * Whether this build of Agneta is installed (in Applications or elsewhere, not only on its disk image) or running.
 * Default environment: `nodeEnvironment()`.
 */
export async function isAgnetaInstalled(build: Build = 'release', environment: AgnetaEnvironment = nodeEnvironment()): Promise<boolean> {
  const entry = builds[build];
  if (await isListening(entry.port)) return true;
  return (await lookUpAgneta(environment, entry)).state === 'notRunning';
}

/** Whether something accepts TCP connections on the loopback port now. */
export function isListening(port: number, timeout = 500): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = createConnection({ host: '127.0.0.1', port });
    const done = (up: boolean) => { probe.destroy(); resolve(up); };
    probe.once('connect', () => done(true));
    probe.once('error', () => done(false));
    probe.setTimeout(timeout, () => done(false));
  });
}

/** Which builds of Agneta are running now: `release`, `dev`, both or neither. */
export async function runningBuilds(): Promise<Build[]> {
  const names = Object.keys(builds) as Build[];
  const up = await Promise.all(names.map((name) => isListening(builds[name].port)));
  return names.filter((_, index) => up[index]);
}

/** Waits until something listens on the port, up to `timeout` ms. */
export async function waitForPort(port: number, timeout = 20_000): Promise<boolean> {
  for (const started = Date.now(); Date.now() - started < timeout;) {
    if (await isListening(port)) return true;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return false;
}
