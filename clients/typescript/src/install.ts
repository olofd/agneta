// Finding Agneta on this Mac before connecting (docs/APP_PROTOCOL.md, Getting Agneta): whether it's installed, where,
// and its version, through an environment the app provides (`@agneta-ai/client/node` has one for Node and one for
// Electron's main process), so the core needs nothing from Node. Also the guided connect's questions and progress.
import type { ProviderKind } from './protocol.js';

/** The app that handles a URL scheme, as LaunchServices (or a look in the Applications folders) found it. */
export interface AgnetaHandler {
  /** The bundle's path. Kept inside the library: it may hold the user's home folder name. */
  path: string;
  /** Its `CFBundleIdentifier`: null when it has none (no bundle there), absent when the environment didn't read it. */
  identifier?: string | null;
  /** Its `CFBundleShortVersionString`, when read. */
  version?: string | null;
  /** Whether it's on a read-only volume (a disk image), when the environment can tell. */
  readOnly?: boolean;
}

/** What the client needs from the platform to find and open Agneta. `@agneta-ai/client/node` provides two; write your own for anything else. */
export interface AgnetaEnvironment {
  /** The app that opens this URL (`agneta://open`), or null when none does. */
  findHandler(url: string): Promise<AgnetaHandler | null>;
  /** The bundle's identifier and version, from its `Info.plist`; null when there's no bundle there. */
  readBundle?(path: string): Promise<{ identifier: string | null; version: string | null } | null>;
  /** Opens a URL with its default handler (a browser for `https`). Resolves to whether it opened. */
  openURL(url: string): Promise<boolean>;
  /** The Mac's architecture (not this process's, which may run under Rosetta), for the install page. */
  architecture?(): Promise<Architecture | null>;
  /** The user's home folder, to tell `~/Applications` apart. */
  home?: string;
  /** How often to look while the user installs Agneta, in ms. Default 1000; a slow lookup (osascript) asks for more. */
  lookupInterval?: number;
}

export type Architecture = 'arm64' | 'x86_64';

/** Where Agneta is, as far as an app can tell before connecting. It never says the path. */
export type AgnetaPresence =
  | { state: 'running' }
  /** Installed: in `/Applications` or `~/Applications`, or `elsewhere` (a developer's build folder). */
  | { state: 'notRunning'; location: 'applications' | 'elsewhere'; version: string | null }
  /** Only a copy on a mounted disk image, or translocated: it needs dragging into Applications. */
  | { state: 'onDiskImage' }
  | { state: 'notInstalled' }
  /** This app may not connect to loopback: a sandbox without `com.apple.security.network.client`. */
  | { state: 'blocked'; reason: string }
  /** No environment to look with, or no URL to look for (an instance on another port). */
  | { state: 'unknown' };

/** Release Agneta's install page: an address that stays (docs/APP_PROTOCOL.md). */
export const installPage = 'https://agneta.dahlbom.io/get/';

/**
 * The install page's address for this Mac: the page, plus the architecture as the fragment (which the browser never
 * sends) when it's one of the two Agneta is built for. Nothing else: no query, nothing about the app or the user.
 * Another build's page (Agneta Dev's README section) is returned as it is.
 */
export function installPageURL(page: string, architecture?: string | null): string {
  if (page !== installPage) return page;
  return architecture === 'arm64' || architecture === 'x86_64' ? `${installPage}#${architecture}` : installPage;
}

/**
 * Where a bundle path is: in an Applications folder; on a disk image (a read-only volume under `/Volumes`, as Agneta
 * itself decides, or anywhere under `/Volumes` when `readOnly` isn't known) or translocated; or elsewhere.
 */
export function placement(path: string, home?: string, readOnly?: boolean): 'applications' | 'diskImage' | 'elsewhere' {
  if (path.includes('/AppTranslocation/') || (path.startsWith('/Volumes/') && readOnly !== false)) return 'diskImage';
  const parent = path.replace(/\/+$/, '').replace(/\/[^/]*$/, '');
  const user = home?.replace(/\/+$/, '');
  if (parent === '/Applications' || (user && parent === `${user}/Applications`)) return 'applications';
  return 'elsewhere';
}

/**
 * Compares two versions (`0.5.0`, `1.2`) by their numbers, ignoring anything after them (`0.5.0-beta` is `0.5.0`):
 * negative when `a` is older. Null when either can't be read (`dev`, Agneta without a bundle), or is a development
 * build's `0.0.0`: those are built from source and never too old.
 */
export function compareVersions(a: string | null | undefined, b: string | null | undefined): number | null {
  const parse = (version: string | null | undefined) => {
    const match = /^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/.exec(version ?? '');
    if (!match) return null;
    const parts = [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)];
    return parts.every((part) => part === 0) ? null : parts;
  };
  const left = parse(a), right = parse(b);
  if (!left || !right) return null;
  for (let index = 0; index < 3; index++) if (left[index] !== right[index]) return left[index]! - right[index]!;
  return 0;
}

/**
 * Whether, and where, an Agneta that isn't answering is installed: the app that handles `openURL`, whose bundle must
 * be `bundleIdentifier`'s (another app may claim the scheme; it counts as not installed). Never `running` or `blocked`:
 * that's the port's to say.
 */
export async function lookUpAgneta(environment: AgnetaEnvironment | undefined,
                                   agneta: { openURL: string | null; bundleIdentifier: string | null }): Promise<AgnetaPresence> {
  if (!environment || !agneta.openURL) return { state: 'unknown' };
  let handler: AgnetaHandler | null;
  try {
    handler = await environment.findHandler(agneta.openURL);
  } catch {
    return { state: 'unknown' };
  }
  if (!handler?.path) return { state: 'notInstalled' };
  let bundle: { identifier?: string | null; version?: string | null } | null = handler;
  if (handler.identifier === undefined && environment.readBundle) bundle = await environment.readBundle(handler.path).catch(() => null);
  // A bundle that isn't there (gone since LaunchServices saw it), or another app's: not installed. An environment that
  // can't read bundles at all can't tell, and is believed.
  if (bundle === null || bundle.identifier === null) return { state: 'notInstalled' };
  if (agneta.bundleIdentifier && bundle.identifier !== undefined && bundle.identifier !== agneta.bundleIdentifier) return { state: 'notInstalled' };
  const where = placement(handler.path, environment.home, handler.readOnly);
  if (where === 'diskImage') return { state: 'onDiskImage' };
  return { state: 'notRunning', location: where, version: bundle.version ?? null };
}

// MARK: The guided connect

/** A question only the user may answer (docs/APP_PROTOCOL.md, Getting Agneta). `guide` resolves to their answer. */
export type GuideQuestion = GuideText & (
  /** Get Agneta: the client opens `installURL` (unless it's only on its disk image), waits, and opens it once installed. */
  | { kind: 'install'; agnetaName: string; installURL: string; homebrew: string | null; onDiskImage: boolean }
  /** Open Agneta, installed and not running. */
  | { kind: 'open'; agnetaName: string }
  /** Update Agneta: opened if it isn't running; the user chooses Check for Updates… in it. */
  | { kind: 'update'; agnetaName: string; version: string | null; needed: string; running: boolean }
  /** Show Agneta's window for connecting a provider (of these kinds; null for any). */
  | { kind: 'setup'; agnetaName: string; kinds: ProviderKind[] | null }
);

/** Plain English an app may show as it is, or replace. */
export interface GuideText {
  title: string;
  detail: string;
  /** The button that says yes. */
  confirm: string;
  /** The button that says no. */
  cancel: string;
}

/** Answers one question; resolves to whether the user said yes. */
export type Guide = (question: GuideQuestion) => boolean | Promise<boolean>;

/** Each step of a connect, in order; `title` and `detail` are plain English an app may show as they are, or replace. */
export type ConnectProgress = { title: string; detail: string } & (
  | { step: 'looking' }
  | { step: 'notInstalled' }
  | { step: 'installing' }
  | { step: 'onDiskImage' }
  | { step: 'installed' }
  | { step: 'notRunning' }
  | { step: 'opening' }
  /** Still opening after `seconds`; from `keepWaiting` on, offer Keep Waiting or Cancel (it waits meanwhile). */
  | { step: 'slow'; seconds: number; keepWaiting: boolean }
  | { step: 'connecting' }
  | { step: 'outdated'; version: string | null; needed: string }
  | { step: 'needsProvider'; kinds: ProviderKind[] | null }
  | { step: 'settingUp'; kinds: ProviderKind[] | null }
  /** Waiting for the user in Agneta's approval window; `code` for an app Agneta can't verify. */
  | { step: 'pairing'; code: string | null }
  | { step: 'connected' }
);

export type ConnectStep = ConnectProgress['step'];
