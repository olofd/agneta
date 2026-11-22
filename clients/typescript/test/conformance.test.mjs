import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { connect } from '../dist/index.js';
import { agnetaLike, standIn } from './stand-in.mjs';

// One fixture is packaged with the Swift tests and exercised by both official clients.
const fixture = JSON.parse(await readFile(new URL('../../swift/Tests/AgnetaClientTests/Fixtures/structured-results.json', import.meta.url), 'utf8'));
for (const item of fixture.cases) {
  test(`shared structured result contract: ${item.id}`, { timeout: 5000 }, async (t) => {
    const behavior = agnetaLike({ handlers: {
      'session/prompt': () => item.rpcCode
        ? { error: { code: item.rpcCode, message: 'engine stopped', data: { agneta: { result: item.report } } } }
        : { result: { stopReason: 'end_turn', _meta: { 'agneta/result': item.report } } }
    } });
    const host = await standIn(behavior.answer);
    let client;
    t.after(async () => { client?.close(); await host.close(); });
    client = await connect({ name: 'Conformance', port: host.port });
    const session = await client.newSession({ results: { schema: item.schema } });
    assert.deepEqual(host.calls('session/new')[0].params._meta['agneta/result'].schema, item.wireSchema);
    const answer = session.ask('Return the result');
    try {
      const value = await answer;
      assert.equal(item.kind, 'valid', 'unexpectedly accepted');
      assert.deepEqual(value, item.value);
    } catch (error) {
      if (item.kind === 'rpc') {
        assert.equal(error.code, item.rpcCode);
        assert.deepEqual(error.accepted, { value: item.value, issues: null });
        assert.deepEqual(error.structured, item.report);
      } else if (item.kind === 'protocol') {
        assert.equal(error.kind, 'protocol');
      } else {
        assert.equal(error.kind, item.kind === 'missing' ? 'resultMissing' : 'resultInvalid');
        assert.deepEqual(error.value, item.value);
        assert.deepEqual(error.submitted, item.report.value);
        if (item.issuePaths) assert.deepEqual(error.issues.map((issue) => issue.path), item.issuePaths);
        if (item.schemaPaths) assert.deepEqual(error.issues.map((issue) => issue.schemaPath), item.schemaPaths);
      }
    }
    assert.deepEqual(host.calls('session/prompt')[0].params._meta['agneta/result'], { name: 'result' });
  });
}
