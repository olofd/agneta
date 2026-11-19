// The modes check against a stand-in Agneta holding the protocol's sandbox rules: every provider × engine asked for
// each mode, what it got or why it was refused, and whether that's what Agneta declared.
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { Agneta } from '../agneta.mjs';
import { checkModes } from '../modes.mjs';
import { agnetaLike, standIn } from './stand-in.mjs';

async function check(t, options) {
  const home = await mkdtemp(join(tmpdir(), 'replica-bench-modes-'));
  const fake = agnetaLike(options);
  const server = await standIn(fake.answer);
  const agneta = new Agneta(server.port, { home });
  t.after(async () => { agneta.close(); server.close(); await rm(home, { recursive: true, force: true }); });
  await agneta.connect();
  const lines = [];
  const rows = await checkModes(agneta, home, { log: (line) => lines.push(line) });
  return { rows, lines, fake };
}

const summary = (rows) => rows.map(({ engine, sandbox, got, refused, verdict }) => `${engine} ${sandbox}: ${refused ? 'refused' : got} (${verdict})`);

test('under a developer grant every engine gives what it provides, and an uncontained one refuses contained', async (t) => {
  const { rows, lines, fake } = await check(t, {});
  assert.deepEqual(summary(rows), [
    'claude-code contained: contained (as declared)',
    'claude-code developer: developer (as declared)',
    'goose contained: refused (as declared)',
    'goose developer: developer (as declared)'
  ]);
  const refused = rows[2];
  assert.equal(refused.uncontained, true);
  assert.deepEqual(refused.levels, ['developer']);
  assert.deepEqual(refused.refused.fields, ['sandbox']);
  assert.match(refused.refused.reason, /goose can't keep Claude's tasks contained/);
  assert.match(lines[2], /asked contained: refused \(goose can't keep/);
  // Each session asked for its mode explicitly, with no prompt, and was closed again.
  const opened = fake.calls.filter(({ method }) => method === 'session/new');
  assert.deepEqual(opened.map(({ params }) => params._meta['agneta/policy'].sandbox), ['contained', 'developer', 'contained', 'developer']);
  assert.ok(opened.every(({ params }) => params.mcpServers.length === 0 && !('access' in params._meta['agneta/policy'])));
  assert.equal(fake.calls.filter(({ method }) => method === 'session/close').length, 3);
  assert.equal(fake.calls.filter(({ method }) => method === 'session/prompt').length, 0);
});

test('under a contained grant developer is refused everywhere, with Agneta\'s reason', async (t) => {
  const { rows } = await check(t, { grant: 'contained' });
  assert.deepEqual(summary(rows), [
    'claude-code contained: contained (as declared)',
    'claude-code developer: refused (as declared)',
    'goose contained: refused (as declared)',
    'goose developer: refused (as declared)'
  ]);
  assert.match(rows[1].refused.reason, /the user keeps this app's tasks contained/);
  assert.equal(rows[1].expected.why, 'the user granted this app contained only');
});

test('an answer that disagrees with what Agneta declared is marked, and unavailable engines aren\'t opened', async (t) => {
  // OpenCode declares both modes, but this Agneta answers a contained request with developer (more than asked):
  // the check marks it. Goose is unavailable on this Mac: listed with the reason, never opened.
  const providers = [{
    id: 'k', label: 'OpenAI key', engines: ['goose', 'opencode'],
    sandboxLevels: { goose: ['contained', 'developer'], opencode: ['contained', 'developer'] }, uncontained: []
  }];
  const fake = agnetaLike({ providers });
  const server = await standIn((message) => {
    const reply = fake.answer(message);
    if (message.method === 'session/new' && message.params._meta.agneta.engine === 'opencode') reply.result._meta.agneta.sandbox = 'developer';
    return reply;
  });
  const home = await mkdtemp(join(tmpdir(), 'replica-bench-modes-'));
  const agneta = new Agneta(server.port, { home });
  t.after(async () => { agneta.close(); server.close(); await rm(home, { recursive: true, force: true }); });
  await agneta.connect();
  agneta.access.engines = [{ id: 'goose', name: 'Goose', state: 'unavailable', reason: 'Install Goose' }, { id: 'opencode', name: 'OpenCode', state: 'ready' }];
  const rows = await checkModes(agneta, home);
  assert.deepEqual(rows.map(({ engine, sandbox, verdict, error }) => [engine, sandbox, verdict, error]), [
    ['goose', 'contained', 'error', 'Goose is unavailable: Install Goose'],
    ['goose', 'developer', 'error', 'Goose is unavailable: Install Goose'],
    ['opencode', 'contained', 'unexpected', null],
    ['opencode', 'developer', 'as declared', null]
  ]);
  assert.equal(fake.calls.filter(({ method, params }) => method === 'session/new' && params._meta.agneta.engine === 'goose').length, 0);
});
