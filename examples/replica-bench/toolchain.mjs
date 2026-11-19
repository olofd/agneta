// The Rust toolchain the bench hands its agent on Agneta's contained path, as a demanding app hands its own: the
// user's rustup toolchains and cargo's proxies, granted read-only, with a CARGO_HOME of the run's own (cargo writes
// its registry and locks there). Under developer access the agent finds the user's toolchains by itself.
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const rustup = join(homedir(), '.rustup');
const proxies = join(homedir(), '.cargo', 'bin');

/** The toolchain folders that exist on this Mac, for the pairing scope and the session's readOnly. */
export function toolchainFolders() {
  return [rustup, proxies].filter((folder) => existsSync(folder));
}

/** The session's toolEnvironment for a run's workspace, or nothing when there's no Rust toolchain. */
export function toolchainEnvironment(workspace) {
  if (!existsSync(proxies)) return undefined;
  return { PATH: proxies, RUSTUP_HOME: rustup, CARGO_HOME: join(workspace, '.cargo-home') };
}
