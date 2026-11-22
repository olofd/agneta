import assert from 'node:assert/strict';
import test from 'node:test';
import {
  connect, isAgnetaError, resultCallOf, Answer, Ask, InternalError, ResultInvalidError, ResultMissingError, Turn, UnenforceableError,
  UnsupportedByAgnetaError
} from '../dist/index.js';
import { agnetaLike, standIn, workspace } from './stand-in.mjs';

async function setUp(t, options = {}) {
  const behaviour = agnetaLike(options);
  const agneta = await standIn(behaviour.answer);
  const client = await connect({ name: 'Example', port: agneta.port });
  t.after(async () => { client.close(); await agneta.close(); });
  return { agneta, client, state: behaviour.state };
}

const contact = { type: 'object', properties: { name: { type: 'string' }, email: { type: 'string' } }, required: ['name'], additionalProperties: false };
const invoice = { type: 'object', properties: { number: { type: 'string' }, total: { type: 'number' } }, required: ['number', 'total'] };
const call = (tool, value) => `CALL ${tool} ${JSON.stringify(value)}`;
const lines = (...parts) => parts.join('\n');
const sentResult = (agneta) => agneta.calls('session/prompt').at(-1).params._meta?.['agneta/result'];

/** A minimal Standard Schema with Standard JSON Schema, as Zod 4.2+ or ArkType give one. */
function standard(json, validate, vendor = 'mini') {
  const targets = [];
  const schema = { '~standard': { version: 1, vendor, validate, jsonSchema: { input: ({ target }) => { targets.push(target); return json; }, output: () => json } } };
  return { schema, targets };
}

test('declaring results: named schemas with every, the shorthand, and what Agneta answered', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { invoice, contact }, every: 'invoice' } });
  assert.deepEqual(agneta.calls('session/new')[0].params._meta, { 'agneta/result': { schemas: { invoice, contact }, every: 'invoice' } });
  assert.deepEqual(session.results, { declared: ['contact', 'invoice'], every: 'invoice', mechanism: 'tool' });

  const short = await client.newSession({ results: { schema: contact }, meta: { extra: 1 } });
  assert.deepEqual(agneta.calls('session/new')[1].params._meta, { 'agneta/result': { schema: contact }, extra: 1 });
  assert.deepEqual(short.results, { declared: ['result'], every: 'result', mechanism: 'tool' });

  const plain = await client.newSession();
  assert.equal(plain.results, null);
  assert.equal(agneta.calls('session/new')[2].params._meta, undefined);
  await assert.rejects(client.newSession({ results: {} }), TypeError);
  await assert.rejects(client.newSession({ results: { schema: contact, schemas: { contact } } }), TypeError);
  assert.equal(agneta.calls('session/new').length, 3, 'nothing sent for a mistake');
});

test('a root that isn\'t an object is wrapped as { value } for Agneta, definitions hoisted and references moved', async (t) => {
  const { agneta, client } = await setUp(t);
  const tree = {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $defs: { node: { type: 'object', properties: { children: { type: 'array', items: { $ref: '#' } }, tag: { $ref: '#/$defs/tag' } } }, tag: { type: 'string' } },
    type: 'array', items: { $ref: '#/$defs/node' }, default: [{ $ref: 'not a reference' }], prefixItems: [{ $ref: '#/items' }]
  };
  await client.newSession({ results: { schemas: { list: { type: 'array', items: { type: 'string' } }, tree } } });
  const { schemas } = agneta.calls('session/new')[0].params._meta['agneta/result'];
  assert.deepEqual(schemas.list, { type: 'object', properties: { value: { type: 'array', items: { type: 'string' } } }, required: ['value'], additionalProperties: false });
  assert.deepEqual(schemas.tree, {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    type: 'object', required: ['value'], additionalProperties: false,
    properties: { value: { type: 'array', items: { $ref: '#/$defs/node' }, default: [{ $ref: 'not a reference' }], prefixItems: [{ $ref: '#/properties/value/items' }] } },
    $defs: { node: { type: 'object', properties: { children: { type: 'array', items: { $ref: '#/properties/value' } }, tag: { $ref: '#/$defs/tag' } } }, tag: { type: 'string' } }
  });
});

test('ask reads a valid value, typed by its schema, with its details; the result tool\'s calls are tagged and kept apart', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact, invoice } } });
  const ask = session.ask(lines('Looking.', call('read_file', { path: 'a' }), call('submit_contact', { name: 'Ada' }), 'Done.'), { schema: contact, attempts: 2 });
  assert.ok(ask instanceof Ask);
  assert.ok(ask.turn instanceof Turn);
  const tags = [];
  for await (const update of ask.turn.updates()) tags.push(resultCallOf(update));
  assert.deepEqual(sentResult(agneta), { name: 'contact', attempts: 2 });
  assert.deepEqual(tags, [null, null, null, { name: 'contact' }, { name: 'contact' }, null]);
  assert.deepEqual(await ask, { name: 'Ada' });
  const details = await ask.details;
  assert.deepEqual({ ...details, turnResult: undefined }, { value: { name: 'Ada' }, name: 'contact', mechanism: 'tool', attempts: 1, turnResult: undefined });
  assert.equal(details.turnResult.text, 'Looking.Done.');
  assert.deepEqual(details.turnResult.toolCalls.map(({ title }) => title), ['read_file'], 'the model\'s own calls only');
  assert.deepEqual(details.turnResult.resultCalls.map(({ title, status, result }) => [title, status, result]), [['submit_contact', 'completed', { name: 'contact' }]]);
  assert.deepEqual(ask.turn.resultCalls.length, 1);
  assert.equal(details.turnResult.structured.status, 'valid');

  // By name, and by an equal schema written in another order.
  assert.deepEqual(await session.ask(call('submit_invoice', { number: 'A-1', total: 3 }), { name: 'invoice' }), { number: 'A-1', total: 3 });
  const reordered = { required: ['number', 'total'], properties: { total: { type: 'number' }, number: { type: 'string' } }, type: 'object' };
  assert.deepEqual(await session.ask(call('submit_invoice', { number: 'A-2', total: 4 }), { schema: reordered }), { number: 'A-2', total: 4 });
  assert.equal(sentResult(agneta).name, 'invoice');
});

test('every: a prompt asks for it unless it says false; the low-level turn carries the report', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact }, every: 'contact' } });
  const turn = await session.prompt(call('submit_contact', { name: 'Ada' }));
  assert.equal(sentResult(agneta), undefined);
  assert.deepEqual(turn.structured, { status: 'valid', name: 'contact', mechanism: 'tool', attempts: 1, value: { name: 'Ada' } });
  const none = await session.prompt('Just talk.', { result: false });
  assert.equal(sentResult(agneta), false);
  assert.equal(none.structured, null);
  assert.deepEqual(await session.ask(call('submit_contact', { name: 'Bo' })), { name: 'Bo' }, 'no schema or name: every');
  assert.deepEqual(sentResult(agneta), { name: 'contact' });
});

test('invalid: Agneta\'s issues and last value, source agneta', async (t) => {
  const { client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact } } });
  const error = await session.ask(lines(call('submit_contact', { name: 7 }), call('submit_contact', { email: 'x' })), { schema: contact, attempts: 2 })
    .then(() => assert.fail('resolved'), (error) => error);
  assert.ok(error instanceof ResultInvalidError && isAgnetaError(error));
  assert.equal(error.kind, 'resultInvalid');
  assert.equal(error.source, 'agneta');
  assert.equal(error.resultName, 'contact');
  assert.deepEqual(error.value, { email: 'x' });
  assert.deepEqual(error.issues, [{ path: '', keyword: 'required', message: 'missing name', schemaPath: '/required' }]);
  assert.equal(error.valueOmitted, null);
  assert.equal(error.turnResult.structured.attempts, 2);
  assert.match(error.message, /didn't match its schema: the value: missing name/);
  assert.match(error.advice, /try again/);
});

test('missing, for every reason, with the last refused value when there was one', async (t) => {
  const { client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact } } });
  const missing = (prompt) => session.ask(prompt, { name: 'contact' }).then(() => assert.fail('resolved'), (error) => error);

  const notSubmitted = await missing('I won\'t call anything.');
  assert.ok(notSubmitted instanceof ResultMissingError);
  assert.deepEqual([notSubmitted.kind, notSubmitted.reason, notSubmitted.value, notSubmitted.issues, notSubmitted.turnResult.stopReason],
    ['resultMissing', 'not-submitted', undefined, [], 'end_turn']);

  const stopped = await missing(lines(call('submit_contact', { name: 1 }), 'STOP cancelled'));
  assert.equal(stopped.reason, 'stopped');
  assert.deepEqual(stopped.value, { name: 1 });
  assert.equal(stopped.issues[0].path, '/name');
  assert.equal(stopped.turnResult.cancelled, true);

  assert.equal((await missing('STOP refusal')).reason, 'refused');
  assert.equal((await missing('STOP max_tokens')).reason, 'truncated');
  assert.equal((await missing('STOP max_turn_requests')).reason, 'stopped');

  // The wrong result's tool counts as an attempt.
  const wrong = await missing(call('submit_other', { name: 'Ada' }));
  assert.deepEqual([wrong.reason, wrong.structured.attempts], ['not-submitted', 1]);

  for (const reason of ['stopped', 'refused', 'truncated', 'not-submitted']) {
    const error = new ResultMissingError({ status: 'missing', name: 'contact', mechanism: 'tool', attempts: 0, reason }, {});
    assert.ok(error.message.length > 10 && error.advice.length > 10, reason);
  }
});

test('a refused value nested too deeply to report: valueOmitted', async (t) => {
  const { client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact } } });
  let deep = 'x';
  for (let level = 0; level < 70; level++) deep = { deep };
  const error = await session.ask(call('submit_contact', { name: 'Ada', extra: deep }), { name: 'contact', attempts: 1 }).catch((error) => error);
  assert.ok(error instanceof ResultInvalidError);
  assert.equal(error.value, undefined);
  assert.equal(error.valueOmitted, 'nested too deeply to report');
  assert.equal(error.issues[0].keyword, 'additionalProperties');
});

test('a wrapped root is unwrapped: its value, and the paths of its issues', async (t) => {
  const { client } = await setUp(t);
  const tags = { type: 'array', items: { type: 'string' } };
  const session = await client.newSession({ results: { schemas: { tags } } });
  assert.deepEqual(await session.ask(call('submit_tags', { value: ['a', 'b'] }), { schema: tags }), ['a', 'b']);
  const error = await session.ask(call('submit_tags', { value: ['a', 2] }), { schema: tags, attempts: 1 }).catch((error) => error);
  assert.deepEqual(error.value, ['a', 2]);
  assert.deepEqual(error.issues, [{ path: '/1', keyword: 'type', message: 'expected string, got integer', schemaPath: '/items/type' }]);
});

test('a Standard Schema: converted for 2020-12, Agneta\'s value checked again and given as its output; it may only reject further', async (t) => {
  const { agneta, client } = await setUp(t);
  const { schema, targets } = standard(contact, async (value) => value.name === 'Nobody'
    ? { issues: [{ message: 'not a real name', path: [{ key: 'name' }] }, { message: 'odd', path: ['a/b', 0] }] }
    : { value: { ...value, name: value.name.toUpperCase() } }, 'zod');
  const session = await client.newSession({ results: { schemas: { contact: schema } } });
  assert.deepEqual(agneta.calls('session/new')[0].params._meta['agneta/result'], { schemas: { contact } });
  assert.deepEqual(targets, ['draft-2020-12']);
  assert.deepEqual(await session.ask(call('submit_contact', { name: 'Ada' }), { schema }), { name: 'ADA' });

  const error = await session.ask(call('submit_contact', { name: 'Nobody' }), { schema }).catch((error) => error);
  assert.ok(error instanceof ResultInvalidError);
  assert.equal(error.source, 'client');
  assert.equal(error.structured.status, 'valid', 'Agneta accepted it');
  assert.deepEqual(error.value, { name: 'Nobody' });
  assert.deepEqual(error.issues, [
    { path: '/name', keyword: 'zod', message: 'not a real name', schemaPath: '' },
    { path: '/a~1b/0', keyword: 'zod', message: 'odd', schemaPath: '' }
  ]);
  assert.match(error.advice, /app's own schema/);
  // Agneta's refusal stands, whatever the app's schema would say.
  const refused = await session.ask(call('submit_contact', { name: 3 }), { schema, attempts: 1 }).catch((error) => error);
  assert.equal(refused.source, 'agneta');

  // A Standard Schema with no JSON Schema can't be declared.
  await assert.rejects(client.newSession({ results: { schema: { '~standard': { version: 1, vendor: 'old', validate: () => ({ value: 1 }) } } } }), /can't give its JSON Schema/);
});

test('parse: transforms, and a throw rejects the value (source client) with the cause', async (t) => {
  const { client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact } } });
  assert.equal(await session.ask(call('submit_contact', { name: 'Ada' }), { schema: contact, parse: (value) => `<${value.name}>` }), '<Ada>');
  const cause = new Error('no email');
  const error = await session.ask(call('submit_contact', { name: 'Ada' }), { name: 'contact', parse: () => { throw cause; } }).catch((error) => error);
  assert.equal(error.source, 'client');
  assert.equal(error.cause, cause);
  assert.deepEqual(error.issues, [{ path: '', keyword: 'parse', message: 'no email', schemaPath: '' }]);
});

test('a schema or name the session didn\'t declare is an error before anything is sent', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact } } });
  const before = agneta.calls('session/prompt').length;
  assert.throws(() => session.ask('x', { schema: invoice }), /didn't declare that schema.*only when a session opens/s);
  assert.throws(() => session.ask('x', { name: 'invoice' }), /"invoice" wasn't declared/);
  assert.throws(() => session.ask('x', { name: 'contact', schema: invoice }), /isn't the one this session declared/);
  assert.throws(() => session.ask('x'), /no every/);
  const plain = await client.newSession();
  assert.throws(() => plain.ask('x', { schema: contact }), /declared no results/);
  assert.equal(agneta.calls('session/prompt').length, before);

  // Asked anyway at the low level: Agneta refuses, typed.
  await assert.rejects(session.prompt('x', { result: { name: 'invoice' } }),
    (error) => error instanceof UnenforceableError && error.fields[0] === 'agneta/result' && /wasn't declared/.test(error.reason));
  await assert.rejects(session.prompt('x', { result: { name: 'contact', attempts: 11 } }), UnenforceableError);
  await assert.rejects(plain.prompt('x', { result: { name: 'contact' } }), (error) => /declared no results/.test(error.reason));
});

test('a declaration Agneta refuses is UnenforceableError, with advice about the schema', async (t) => {
  const { client } = await setUp(t);
  for (const results of [{ schemas: { Bad: contact } }, { schemas: { contact }, every: 'other' }, { schema: { ...contact, if: {} } }]) {
    const error = await client.newSession({ results }).catch((error) => error);
    assert.ok(error instanceof UnenforceableError, JSON.stringify(results));
    assert.deepEqual(error.fields, ['agneta/result']);
    assert.equal(typeof error.reason, 'string');
    assert.match(error.advice, /schema/);
  }
});

test('load and fork keep the original\'s declaration; a handle that knows its schemas matches them, one that doesn\'t asks by name', async (t) => {
  const { agneta, client } = await setUp(t);
  const tags = { type: 'array', items: { type: 'string' } };
  const session = await client.newSession({ results: { schemas: { tags } } });
  const fork = await session.fork();
  assert.equal(agneta.calls('agneta/fork')[0].params._meta, undefined);
  assert.deepEqual(fork.results.declared, ['tags']);
  assert.deepEqual(await fork.ask(call('submit_tags', { value: ['a'] }), { schema: tags }), ['a'], 'known: matched and unwrapped');

  await session.close();
  const loaded = await client.loadSession(session.id);
  assert.deepEqual(loaded.results.declared, ['tags']);
  assert.throws(() => loaded.ask('x', { schema: tags }), /doesn't know the schemas it declared.*ask by name \(tags\)/s);
  assert.deepEqual(await loaded.ask(call('submit_tags', { value: ['b'] }), { name: 'tags' }), { value: ['b'] }, 'unknown: as Agneta sent it');
  assert.deepEqual(await loaded.ask(call('submit_tags', { value: ['c'] }), { name: 'tags', schema: tags }), ['c'], 'the schema says how to read it');

  const again = await client.loadSession(session.id, { results: { schemas: { tags } } });
  assert.deepEqual(await again.ask(call('submit_tags', { value: ['d'] }), { schema: tags }), ['d']);
});

test('an engine that fails after a value was accepted: the error carries the report', async (t) => {
  const { client } = await setUp(t);
  const session = await client.newSession({ results: { schemas: { contact } } });
  const error = await session.ask(lines(call('submit_contact', { name: 'Ada' }), 'FAIL'), { schema: contact }).catch((error) => error);
  assert.ok(error instanceof InternalError);
  assert.deepEqual(error.structured, { status: 'valid', name: 'contact', mechanism: 'tool', attempts: 1, value: { name: 'Ada' } });
  await assert.rejects(session.ask(lines(call('submit_contact', { name: 'Ada' }), 'FAIL'), { schema: contact }).details, InternalError);
});

test('a prompt cancelled while queued (or over its cost limit) reports missing, stopped', async (t) => {
  const { client } = await setUp(t, {
    handlers: {
      'session/prompt': (message) => message.params.prompt[0].text === 'queued'
        ? { result: { sessionId: message.params.sessionId, stopReason: 'cancelled', _meta: { 'agneta/result': { status: 'missing', name: 'contact', mechanism: 'tool', attempts: 0, reason: 'stopped' } } } }
        : undefined
    }
  });
  const session = await client.newSession({ results: { schemas: { contact } } });
  const error = await session.ask('queued', { schema: contact }).catch((error) => error);
  assert.deepEqual([error.kind, error.reason, error.structured.attempts], ['resultMissing', 'stopped', 0]);
});

test('an aborted signal cancels the ask: missing, stopped', async (t) => {
  let finish;
  const { agneta, client } = await setUp(t, {
    handlers: {
      'session/prompt': () => new Promise((resolve) => {
        finish = () => resolve({ result: { stopReason: 'cancelled', _meta: { 'agneta/result': { status: 'missing', name: 'contact', mechanism: 'tool', attempts: 0, reason: 'stopped' } } } });
      })
    }
  });
  const session = await client.newSession({ results: { schemas: { contact } } });
  const controller = new AbortController();
  const ask = session.ask('slowly', { schema: contact, signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 20));
  controller.abort();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(agneta.calls('session/cancel').length, 1);
  finish();
  await assert.rejects(ask, (error) => error.kind === 'resultMissing' && error.reason === 'stopped');
});

test('client.ask: one session declaring the schema, one ask, closed after; closed after a failure too', async (t) => {
  const { agneta, client } = await setUp(t);
  const turns = [];
  const ask = client.ask(call('submit_result', { name: 'Ada' }), { schema: contact, task: 'Reading a card', attempts: 2, onTurn: (turn) => turns.push(turn) });
  assert.ok(ask instanceof Answer && !(ask instanceof Ask));
  assert.deepEqual(await ask, { name: 'Ada' });
  assert.ok(turns.length === 1 && turns[0] instanceof Turn);
  assert.equal(turns[0].resultCalls.length, 1);
  assert.equal((await ask.details).attempts, 1);
  const [opened] = agneta.calls('session/new');
  assert.deepEqual(opened.params._meta, {
    'agneta/policy': { tools: 'app-only', approval: 'never-ask' }, 'agneta/task': { title: 'Reading a card' }, 'agneta/result': { schema: contact }
  });
  assert.equal(opened.params.cwd, workspace);
  assert.deepEqual(sentResult(agneta), { name: 'result', attempts: 2 });
  assert.deepEqual(agneta.calls('session/close').map(({ params }) => params.sessionId), ['s1']);
  assert.equal(client.sessions.length, 0);

  // A wrapped root, a policy of the app's, and a failure: closed all the same.
  const list = { type: 'array', items: { type: 'string' } };
  assert.deepEqual(await client.ask(call('submit_result', { value: ['x'] }), { schema: list, policy: { tools: 'read' } }), ['x']);
  assert.deepEqual(agneta.calls('session/new')[1].params._meta['agneta/policy'], { tools: 'read' });
  await assert.rejects(client.ask('Nothing.', { schema: contact }), ResultMissingError);
  assert.equal(agneta.calls('session/close').length, 3);

  // A schema Agneta refuses: nothing opened, nothing to close; the turn promise rejects too.
  const refused = client.ask('x', { schema: { type: 'object', if: {} }, onTurn: () => assert.fail('no turn') });
  await assert.rejects(refused, UnenforceableError);
  await assert.rejects(refused.details, UnenforceableError);
  assert.equal(agneta.calls('session/close').length, 3);
});

test('an Agneta without structured results: refused before sending, never a silent fallback', async (t) => {
  const { agneta, client } = await setUp(t, { extensions: ['agneta/policy', 'agneta/access'] });
  const error = await client.newSession({ results: { schema: contact } }).catch((error) => error);
  assert.ok(error instanceof UnsupportedByAgnetaError);
  assert.deepEqual([error.kind, error.extension], ['unsupportedByAgneta', 'agneta/result']);
  assert.match(error.advice, /update Agneta/);
  await assert.rejects(client.ask('x', { schema: contact }), UnsupportedByAgnetaError);
  assert.equal(agneta.calls('session/new').length, 0);
  const session = await client.newSession();
  assert.throws(() => session.prompt('x', { result: { name: 'result' } }), UnsupportedByAgnetaError);
  assert.throws(() => session.prompt('x', { result: false }), UnsupportedByAgnetaError);
  assert.throws(() => session.ask('x', { schema: contact }), UnsupportedByAgnetaError);
  assert.equal(agneta.calls('session/prompt').length, 0);
  await session.prompt('An ordinary turn still works.');
});
