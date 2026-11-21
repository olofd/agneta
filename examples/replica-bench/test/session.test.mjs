import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { BenchRun } from '../run.mjs';

test('the session stop reason survives the cancelled prompt result', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'bench-stop-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const run = new BenchRun({
    async newSession({ on }) {
      return {
        id: 'task', configOptions: [], sandbox: 'contained',
        async prompt() {
          on.ended({ reason: 'stopped', stoppedBy: 'reach', detail: 'The tool socket closed.' });
          return { stopReason: 'cancelled' };
        }
      };
    }
  }, root, null, { account: 'provider', engine: 'goose', sandbox: 'contained' });
  try {
    assert.equal(await run.start(), true);
    await run.prompt('hello');
    assert.equal(run.phase, 'ended');
    assert.match(run.status, /The tool socket closed/);
  } finally {
    await run.close();
  }
});
