import assert from 'node:assert/strict';
import test from 'node:test';
import * as agneta from '../dist/index.js';

const { fromRpcError, isAgnetaError, AgnetaError, AgnetaRpcError } = agneta;
const make = (code, data, message = 'Agneta said no') => fromRpcError({ code, message, data }, 'session/new');

test('each of Agneta\'s codes maps to its kind, keeping the message, code, data and method', () => {
  const cases = [
    [-32001, 'needsPairing', agneta.NeedsPairingError],
    [-32002, 'notAllowed', agneta.NotAllowedError],
    [-32010, 'noTurnRunning', agneta.NoTurnRunningError],
    [-32011, 'turnBusy', agneta.TurnBusyError],
    [-32012, 'queueFull', agneta.QueueFullError],
    [-32013, 'paused', agneta.PausedError],
    [-32014, 'unsupportedByEngine', agneta.UnsupportedByEngineError],
    [-32015, 'engineDownloading', agneta.EngineDownloadingError],
    [-32016, 'appLimit', agneta.AppLimitError],
    [-32601, 'methodNotFound', agneta.MethodNotFoundError],
    [-32602, 'invalidParams', agneta.InvalidParamsError],
    [-32603, 'internal', agneta.InternalError],
    [-32000, 'rpc', agneta.UnknownRpcError],
    [-31999, 'rpc', agneta.UnknownRpcError]
  ];
  for (const [code, kind, type] of cases) {
    const error = make(code, { x: 1 });
    assert.equal(error.kind, kind, String(code));
    assert.ok(error instanceof type && error instanceof AgnetaRpcError && error instanceof AgnetaError && error instanceof Error);
    assert.ok(isAgnetaError(error));
    assert.equal(error.code, code);
    assert.equal(error.message, 'Agneta said no');
    assert.deepEqual(error.data, { x: 1 });
    assert.equal(error.method, 'session/new');
    assert.equal(typeof error.advice, 'string');
    assert.ok(error.advice.length > 5);
    assert.deepEqual(error.toJSON(), { code, message: 'Agneta said no', data: { x: 1 } });
    assert.equal(error.name, type.name);
  }
});

test('structured data is typed for each kind', () => {
  const paused = make(-32013, { agneta: { paused: 'acct-1' } });
  assert.equal(paused.account, 'acct-1');

  const engine = make(-32014, { agneta: { engine: 'codex' } });
  assert.equal(engine.engine, 'codex');

  const downloading = make(-32015, { agneta: { engineDownloading: { engine: 'opencode', received: 10, total: null } } });
  assert.deepEqual(downloading.progress, { engine: 'opencode', received: 10, total: null });
  assert.equal(make(-32015).progress, null);

  const unenforceable = make(-32602, { agneta: { unenforceable: ['sandbox', 7], reason: 'the user keeps this app contained' } });
  assert.equal(unenforceable.kind, 'unenforceable');
  assert.deepEqual(unenforceable.fields, ['sandbox']);
  assert.equal(unenforceable.reason, 'the user keeps this app contained');

  const refused = make(-32602, { agneta: { access: { providers: [] } } });
  assert.equal(refused.kind, 'engineRefused');
  assert.deepEqual(refused.access, { providers: [] });

  assert.equal(make(-32602, { agneta: { accessChanged: true } }).kind, 'accessChanged');

  const state = make(-32602, { agneta: { stateChanged: { engine: 'goose', saved: 'a', current: 'b' } } });
  assert.equal(state.kind, 'stateChanged');
  assert.deepEqual([state.engine, state.saved, state.current], ['goose', 'a', 'b']);
});

test('needsSignIn and rateLimited are recognised by their data whatever the code', () => {
  const signIn = make(-32000, { agneta: { needsSignIn: 'acct-2' }, engine: 'kept' });
  assert.equal(signIn.kind, 'needsSignIn');
  assert.equal(signIn.account, 'acct-2');
  assert.equal(signIn.code, -32000);
  assert.equal(make(-32603, { agneta: { needsSignIn: 'a' } }).kind, 'needsSignIn');

  const limited = make(-32603, { agneta: { rateLimited: { account: 'a', message: 'Rate limit exceeded', resetsAt: '2026-11-19T15:00:00.000000Z' } } });
  assert.equal(limited.kind, 'rateLimited');
  assert.equal(limited.account, 'a');
  assert.equal(limited.providerMessage, 'Rate limit exceeded');
  assert.equal(limited.resetsAt.toISOString(), '2026-11-19T15:00:00.000Z');
  assert.equal(make(-32603, { agneta: { rateLimited: { account: 'a', message: 'x', resetsAt: null } } }).resetsAt, null);
});

test('a switch on kind narrows (the union covers every class)', () => {
  const describe = (error) => {
    if (!isAgnetaError(error)) return 'other';
    switch (error.kind) {
      case 'paused': return `paused ${error.account}`;
      case 'unenforceable': return `refused ${error.fields.join(',')}`;
      default: return error.kind;
    }
  };
  assert.equal(describe(make(-32013, { agneta: { paused: 'p' } })), 'paused p');
  assert.equal(describe(make(-32602, { agneta: { unenforceable: ['tools'] } })), 'refused tools');
  assert.equal(describe(new Error('x')), 'other');
  assert.equal(describe(new agneta.TimeoutError('initialize', 30_000)), 'timeout');
});

test('transport errors say what happened and what to do', () => {
  const notRunning = new agneta.NotRunningError('ws://127.0.0.1:47321/acp', 'agneta://open');
  assert.equal(notRunning.kind, 'notRunning');
  assert.match(notRunning.advice, /Ask the user whether to open Agneta.*agneta:\/\/open/);
  assert.match(new agneta.NotRunningError('ws://x', null).advice, /Open Agneta/);
  assert.equal(new agneta.ConnectionRefusedError('ws://x').kind, 'refused');
  const closed = new agneta.ConnectionClosedError(1006, 'gone');
  assert.deepEqual([closed.kind, closed.closeCode, closed.closeReason], ['connectionClosed', 1006, 'gone']);
  assert.match(new agneta.TimeoutError('agneta/pair', 310_000).message, /agneta\/pair within 310 s/);
  assert.equal(new agneta.ProtocolError('odd', { a: 1 }).detail.a, 1);
});

test('a limit the user set for the app says which, how far and when it resets', () => {
  const error = make(-32016, { agneta: { appLimit: { limit: 'spend', max: 5, used: 5.04, period: 'day', resetsAt: '2026-11-20T23:00:00Z', whenReached: 'stop' } } });
  assert.equal(error.kind, 'appLimit');
  assert.deepEqual(error.limit, { limit: 'spend', max: 5, used: 5.04, period: 'day', resetsAt: '2026-11-20T23:00:00Z', whenReached: 'stop' });
  assert.equal(make(-32016, {}).limit, null);
});
