import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { duration, gotText, markdown, modesTable, outcomeText, summarize, writeReport } from '../report.mjs';

const result = (fields) => ({
  scenario: 'python-probe', title: 'Probe with Python', account: 'a1', engine: 'goose', sandbox: 'contained', got: 'contained', outcome: 'pass', achieved: true, attempted: true,
  expected: { outcome: 'pass', why: null }, checks: [{ name: 'the probe reached the gateway', ok: true, detail: '3 gateway calls' }],
  refusals: [], toolCalls: 4, failedToolCalls: 0, mcpCalls: 0, gatewayHits: 3, turnMs: 75_000, modelCalls: 6, cost: 0.0123, costKind: 'estimated', ...fields
});

const dev = { sandbox: 'developer', got: 'developer' };

test('the summary compares contained with developer access, leaving boundary scenarios out', () => {
  const results = [
    result({}), result(dev),
    result({ scenario: 'rust-build', outcome: 'expected-fail', achieved: false, expected: { outcome: 'fail', why: 'a reason' } }), result({ scenario: 'rust-build', ...dev }),
    result({ scenario: 'network', outcome: 'expected-fail', achieved: false }), result({ scenario: 'network', ...dev }),
    result({ scenario: 'clone', outcome: 'not exercised', achieved: false, attempted: false }),
    result({ scenario: 'clone', sandbox: 'developer', got: null, outcome: 'refused', achieved: null, refused: { fields: ['sandbox'], reason: 'the user keeps this app\'s tasks contained' } })
  ];
  assert.equal(summarize(results),
    'Contained matched developer access on 1 of 2 scenarios (goose); it fell short on rust-build on goose. 6 of 8 runs went as expected (4 passed, 2 failed as expected); 1 not exercised, 1 refused by Agneta.');
});

test('outcomes read plainly, saying whether an expected failure is a gap or a boundary', () => {
  assert.equal(outcomeText(result({ outcome: 'expected-fail', expected: { why: 'a reason' } })), 'expected fail (a known gap)');
  assert.equal(outcomeText(result({ outcome: 'expected-fail', expected: { why: 'a reason', boundary: true } })), 'expected fail (must fail)');
  assert.equal(outcomeText(result({ outcome: 'expected-fail', expected: {} })), 'expected fail (must fail)');
  assert.equal(outcomeText(result({ outcome: 'unexpected', achieved: false })), '**unexpected**: failed');
  assert.equal(outcomeText(result({ outcome: 'refused', refused: { fields: ['sandbox'] } })), 'refused by Agneta (sandbox)');
  assert.equal(duration(75_400), '1:15');
  assert.equal(duration(undefined), '—');
});

test('the report has a table per scenario, with the plain-terminal reference row', async (t) => {
  const reference = { label: 'Plain Claude Code in Terminal', results: { 'python-probe': { outcome: 'pass', minutes: 2, modelCalls: 9, cost: 0.4, notes: 'by hand' } } };
  const text = markdown({ results: [result({}), result({ ...dev, refusals: [{ what: 'fetch', why: 'WebSearch' }] })], reference, meta: { agneta: 'Agneta Dev (port 47331)', grant: 'developer' } });
  assert.match(text, /^# Replica Bench report\n\nContained matched developer access on 1 of 1 scenarios/);
  assert.match(text, /## Sandbox\n\nThis app's grant is \*\*developer\*\*\. Full power, as in a terminal/);
  assert.match(text, /The user picks each app's mode in Agneta/);
  assert.match(text, /\| Engine \| Asked \| Got \| Outcome \|/);
  assert.match(text, /## python-probe: Probe with Python/);
  assert.match(text, /\| goose \| contained \| contained \| pass \| 1:15 \| 6 \| \$0\.01 \| 4 \| 0 \| 3 \| 0 \| the probe reached the gateway: yes \(3 gateway calls\) \|/);
  assert.match(text, /\| Plain Claude Code in Terminal \| terminal \| terminal \| pass \| 2:00 \| 9 \| \$0\.40 \|/);
  assert.match(text, /Refusals:\n- goose developer: fetch, WebSearch/);

  const folder = await mkdtemp(join(tmpdir(), 'replica-bench-report-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  const paths = await writeReport(folder, { results: [result({})], reference, meta: { home: '/bench' } });
  const json = JSON.parse(await readFile(paths.json, 'utf8'));
  assert.equal(json.version, 2);
  assert.equal(json.results.length, 1);
  assert.equal(json.reference.label, reference.label);
  assert.match(await readFile(paths.md, 'utf8'), /Bench data: \/bench/);
});

test('a refused run shows what it asked, that Agneta refused it, and Agneta\'s reason', () => {
  const refused = result({
    sandbox: 'contained', got: null, outcome: 'refused', achieved: null, checks: [],
    refused: { fields: ['sandbox'], reason: 'Goose runs Claude Code with all its own tools; choose another engine, or developer access' }
  });
  const text = markdown({ results: [refused], meta: { grant: 'developer' } });
  assert.equal(gotText(refused), 'refused');
  assert.match(text, /\| goose \| contained \| refused \| refused by Agneta \(sandbox\) \|/);
  assert.match(text, /Sessions Agneta refused:\n- goose asked contained: Goose runs Claude Code with all its own tools; choose another engine, or developer access/);
  assert.equal(gotText(result({ got: null })), '—');
});

const modeRows = [
  { provider: 'Claude', engine: 'claude-code', levels: ['contained', 'developer'], uncontained: false, sandbox: 'contained', got: 'contained', refused: null, verdict: 'as declared', expected: { outcome: 'got' } },
  { provider: 'Claude', engine: 'goose', levels: ['developer'], uncontained: true, sandbox: 'contained', got: null, refused: { fields: ['sandbox'], reason: 'Goose can\'t keep Claude\'s tasks contained' }, verdict: 'as declared', expected: { outcome: 'refused', why: 'this engine provides developer only on this provider' } },
  { provider: 'Claude', engine: 'goose', levels: ['developer'], uncontained: true, sandbox: 'developer', got: 'contained', refused: null, verdict: 'unexpected', expected: { outcome: 'got' } }
];

test('the modes table shows what each engine can provide, asked, got, and Agneta\'s reason', () => {
  const lines = modesTable(modeRows);
  assert.equal(lines[0], '| Provider | Engine | Can provide | Asked | Got | As declared | Agneta\'s reason |');
  assert.equal(lines[2], '| Claude | claude-code | contained, developer | contained | contained | yes |  |');
  assert.equal(lines[3], '| Claude | goose (uncontained) | developer | contained | refused | yes | Goose can\'t keep Claude\'s tasks contained |');
  assert.equal(lines[4], '| Claude | goose (uncontained) | developer | developer | contained | **no** (expected it to open) |  |');
  assert.equal(summarize([], modeRows), 'Modes: 2 of 3 sessions got what Agneta declared (2 opened, 1 refused); 1 disagreed: goose on Claude asked developer.');
  const text = markdown({ results: [], modes: modeRows, meta: { grant: 'contained' } });
  assert.match(text, /This app's grant is \*\*contained\*\*\. The session's folders only/);
  assert.match(text, /### Modes check/);
  assert.match(text, /Uncontained \(developer only; Agneta can't confine its own tools there\): goose on Claude\./);
});
