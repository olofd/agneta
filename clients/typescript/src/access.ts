// Reading the access report: which provider and engine a task can run on, as a picker would show them.
import type { Access, AccessEngine, AccessProvider, EngineId, ProviderKind, SandboxLevel } from './protocol.js';

/** An engine of a provider, with what the access report says of it there. */
export interface ProviderEngine {
  id: EngineId;
  name: string;
  state: AccessEngine['state'] | 'unknown';
  /** Why it failed or is unavailable. */
  reason?: string;
  /** The modes it can provide on this provider, or null where Agneta doesn't say. */
  sandboxLevels: SandboxLevel[] | null;
  /** Agneta's policy can't confine its own tools here: developer access only. */
  uncontained: boolean;
  /** The provider's default. */
  isDefault: boolean;
  engine: AccessEngine | undefined;
}

/** The engine's entry in the access report. */
export function engineInfo(access: Access | null | undefined, id: EngineId): AccessEngine | undefined {
  return access?.engines?.find((engine) => engine.id === id);
}

/** A provider's engines, the default first, each with its state, modes and whether it's uncontained. */
export function providerEngines(access: Access | null | undefined, provider: AccessProvider): ProviderEngine[] {
  return (provider.engines ?? []).map((id, index) => {
    const engine = engineInfo(access, id);
    const levels = provider.sandboxLevels?.[id];
    return {
      id,
      name: engine?.name ?? id,
      state: engine?.state ?? 'unknown',
      ...(engine && 'reason' in engine && engine.reason ? { reason: engine.reason } : {}),
      sandboxLevels: Array.isArray(levels) ? levels : null,
      uncontained: (provider.uncontained ?? []).includes(id),
      isDefault: provider.defaultEngine ? provider.defaultEngine === id : index === 0,
      engine
    };
  });
}

export interface EngineChoice {
  provider: AccessProvider;
  engine: ProviderEngine;
  /** For `newSession`. */
  account: string;
}

/**
 * The first provider and engine a task can run on now: not paused or waiting for sign-in, of `kind` when given, on
 * `engine` (else the provider's default first) when it can provide `sandbox`, and not failed or unavailable here. Null
 * when there's none: show the access report's reasons.
 */
export function chooseProvider(access: Access | null | undefined, wanted: { kind?: ProviderKind; account?: string; engine?: EngineId; sandbox?: SandboxLevel } = {}): EngineChoice | null {
  for (const provider of access?.providers ?? []) {
    if (provider.paused || provider.needsSignIn) continue;
    if (wanted.kind && provider.kind !== wanted.kind) continue;
    if (wanted.account && provider.id !== wanted.account) continue;
    for (const engine of providerEngines(access, provider)) {
      if (wanted.engine && engine.id !== wanted.engine) continue;
      if (engine.state === 'failed' || engine.state === 'unavailable') continue;
      if (wanted.sandbox && engine.sandboxLevels && !engine.sandboxLevels.includes(wanted.sandbox)) continue;
      return { provider, engine, account: provider.id };
    }
  }
  return null;
}
