/// <reference types="node" />
// Node and Electron-main helpers: token stores on disk (plain, or encrypted with Electron's safeStorage), opening
// Agneta with macOS's `open`, and finding which Agneta is running. Kept apart so the core needs nothing from Node.
import { execFile } from 'node:child_process';
import { chmod, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { createConnection } from 'node:net';
import { dirname } from 'node:path';
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
  const url = typeof build === 'string' ? builds[build].openURL : build.openURL;
  return new Promise((resolve) => {
    execFile('/usr/bin/open', [url], (error) => resolve(!error));
  });
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
