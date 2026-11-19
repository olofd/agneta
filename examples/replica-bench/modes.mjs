// The modes check: the quick, cheap demonstration of Agneta's sandbox modes. For every provider × engine the app may
// use it opens one session asking `contained` and one asking `developer`, with no prompt (opening a session starts
// the engine but calls no model), records what each got (`_meta.agneta.sandbox`) or Agneta's refusal and reason, and
// closes it. Each answer is compared with what Agneta declared: the grant's ceiling and the engine's sandboxLevels.
import { describeError, refusal } from './agneta.mjs';
import { policyFor } from './run.mjs';
import { expectedMode, modes as ladder } from './sandbox.mjs';
import { createRun } from './workspace.mjs';

/**
 * Checks every mode on every provider × engine (one provider with `account`). Engines Agneta reports unavailable
 * are listed with their reason, not opened. Resolves to one row per check.
 */
export async function checkModes(agneta, home, { account = 'all', log = () => {} } = {}) {
  const providers = agneta.providers().filter((provider) => !provider.paused && (account === 'all' || provider.id === account));
  if (!providers.length) throw new Error(account === 'all' ? 'No active provider was granted. Connect one in Agneta and pair again.' : `No active provider ${account} in this app's access.`);
  // One workspace serves every check: the sessions run nothing in it.
  const run = await createRun(home, { label: 'modes' });
  const grant = agneta.grant;
  const rows = [];
  for (const provider of providers) {
    for (const engine of provider.engines) {
      for (const sandbox of ladder) {
        const row = {
          account: provider.id, provider: provider.label, engine: engine.id, levels: engine.levels, uncontained: engine.uncontained,
          sandbox, got: null, refused: null, error: null, ms: null,
          expected: expectedMode({ grant, levels: engine.levels, asked: sandbox })
        };
        if (['unavailable', 'failed'].includes(engine.state)) {
          row.error = `${engine.name} is ${engine.state}${engine.reason ? `: ${engine.reason}` : ''}`;
        } else {
          const started = Date.now();
          try {
            const session = await agneta.newSession({
              cwd: run.workspace,
              account: provider.id,
              engine: engine.id,
              policy: policyFor(run, { sandbox }),
              task: `Modes check · ${engine.name} · ${sandbox} · Replica Bench`
            });
            row.got = session.sandbox ?? null;
            await session.close({ timeout: 10_000 }).catch(() => {});
          } catch (error) {
            row.refused = refusal(error);
            if (!row.refused) row.error = describeError(error);
          }
          row.ms = Date.now() - started;
        }
        // As declared: got exactly the mode asked when it should open, refused (for the sandbox) when it shouldn't.
        row.verdict = row.error ? 'error'
          : row.expected.outcome === 'got' ? (row.got === sandbox ? 'as declared' : 'unexpected')
          : (row.refused?.fields?.includes('sandbox') ? 'as declared' : 'unexpected');
        log(`${provider.label} · ${engine.id} · asked ${sandbox}: ${row.error ? `error, ${row.error}` : row.refused ? `refused (${row.refused.reason})` : `got ${row.got ?? 'nothing reported'}`}${row.verdict === 'unexpected' ? ' · NOT as declared' : ''}`);
        rows.push(row);
      }
    }
  }
  return rows;
}
