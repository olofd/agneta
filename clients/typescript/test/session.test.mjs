import assert from 'node:assert/strict';
import test from 'node:test';
import {
  connect, httpMcpServer, chooseProvider, configSetting, findConfigOption, permissionResponse, providerEngines,
  AbortedError, InvalidParamsError, TimeoutError, EngineDownloadingError, NoTurnRunningError, RateLimitedError, TurnBusyError, UnenforceableError, PausedError
} from '../dist/index.js';
import { agnetaLike, accessReport, standIn, workspace } from './stand-in.mjs';

async function setUp(t, options = {}, clientOptions = {}) {
  const behaviour = agnetaLike(options);
  const agneta = await standIn(behaviour.answer);
  let client;
  t.after(async () => { client?.close(); await agneta.close(); });
  client = await connect({ name: 'Example', port: agneta.port, ...clientOptions });
  return { agneta, client, state: behaviour.state };
}

const update = (sessionId, value) => ({ sessionId, update: value });
const text = (value) => ({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: value } });

test('newSession sends cwd, servers and every _meta part, and reads the reply', async (t) => {
  const { agneta, client } = await setUp(t);
  const server = httpMcpServer({ name: 'app', url: 'http://127.0.0.1:5000/mcp', token: 'secret', headers: { 'X-Trace': '1' } });
  assert.deepEqual(server, { type: 'http', name: 'app', url: 'http://127.0.0.1:5000/mcp', headers: [{ name: 'Authorization', value: 'Bearer secret' }, { name: 'X-Trace', value: '1' }] });
  const session = await client.newSession({
    account: 'p1', engine: 'claude-code', mcpServers: [server],
    policy: { tools: 'workspace', sandbox: 'contained', network: 'none', approval: 'never-ask', toolPorts: [5000], toolEnvironment: { CARGO_HOME: '/x' }, limits: { maxTurns: 5, maxSeconds: 60 } },
    task: 'Tidying notes', instructions: 'Be brief.', trace: true, meta: { 'agneta/task': { title: 'Override', stopWarning: 'kept' } },
    params: { extra: 1 }
  });
  const [request] = agneta.calls('session/new');
  assert.deepEqual(request.params, {
    cwd: workspace, mcpServers: [server], extra: 1,
    _meta: {
      agneta: { account: 'p1', engine: 'claude-code' },
      'agneta/policy': { tools: 'workspace', sandbox: 'contained', network: 'none', approval: 'never-ask', toolPorts: [5000], toolEnvironment: { CARGO_HOME: '/x' }, limits: { maxTurns: 5, maxSeconds: 60 } },
      'agneta/task': { title: 'Override', stopWarning: 'kept' },
      'agneta/instructions': { text: 'Be brief.' },
      'agneta/trace': { live: true }
    }
  });
  assert.equal(session.id, 's1');
  assert.equal(session.account, 'p1');
  assert.equal(session.engine, 'claude-code');
  assert.equal(session.sandbox, 'contained');
  assert.equal(session.dedicatedEngine, true);
  assert.equal(session.capabilities.steer, true);
  assert.equal(session.resumed, false);
  assert.equal(client.session('s1'), session);

  // Nothing given: the app's workspace, no servers, no _meta.
  await client.newSession();
  assert.deepEqual(agneta.calls('session/new')[1].params, { cwd: workspace, mcpServers: [] });
});

test('model and effort are found by category, with grouped choices flattened, and set between turns', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession();
  assert.deepEqual([session.model.id, session.model.current, session.model.choices.map(({ value }) => value)], ['model', 'sonnet', ['sonnet', 'opus']]);
  assert.deepEqual(session.effort.choices.map(({ value, group }) => `${value}/${group}`), ['low/all', 'medium/all', 'high/all']);
  const changed = [];
  session.on('configOptions', (options) => changed.push(options.length));
  await session.setModel('opus');
  await session.setEffort('high');
  assert.deepEqual(agneta.calls('session/set_config_option').map(({ params }) => [params.configId, params.value]), [['model', 'opus'], ['effort', 'high']]);
  assert.equal(session.model.current, 'opus');
  assert.equal(session.effort.current, 'high');
  assert.deepEqual(changed, [2, 2]);
  // An engine's config_option_update counts too.
  agneta.notify('session/update', update('s1', { sessionUpdate: 'config_option_update', configOptions: [] }));
  await session.next('configOptions');
  assert.equal(session.model, undefined);
  await assert.rejects(session.setEffort('low'), TypeError);
});

test('configSetting lists a current value the engine didn\'t list, first', () => {
  const option = { id: 'model', name: 'Model', type: 'select', currentValue: 'gpt-4o', options: [{ value: 'gpt-5', name: 'GPT-5' }] };
  assert.deepEqual(configSetting(option).choices.map(({ value }) => value), ['gpt-4o', 'gpt-5']);
  assert.equal(findConfigOption([option], 'model'), option, 'found by the id model');
  assert.equal(configSetting({ id: 'b', name: 'B', type: 'boolean', currentValue: true }), undefined);
});

test('a turn streams its events, merges tool calls, and resolves with text and usage', async (t) => {
  const { client } = await setUp(t, {
    handlers: {
      'session/prompt': (message, peer) => {
        const id = message.params.sessionId;
        peer.notify('agneta/queued', { sessionId: id, position: 1 });
        peer.notify('session/update', update(id, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Hmm.' } }));
        peer.notify('session/update', update(id, { sessionUpdate: 'tool_call', toolCallId: 't1', title: 'Read', kind: 'read', status: 'pending' }));
        peer.notify('session/update', update(id, { sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'completed', rawOutput: { ok: true } }));
        peer.notify('session/update', update(id, text('Done ')));
        peer.notify('session/update', update(id, text('now.')));
        return { result: { stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 }, _meta: { 'agneta/usage': { modelCalls: 2, costKind: 'estimated' } } } };
      }
    }
  });
  const session = await client.newSession();
  const turn = session.prompt('Go');
  assert.equal(session.turn, turn);
  assert.throws(() => session.prompt('Again'), TurnBusyError);
  const kinds = [];
  for await (const event of turn) kinds.push(event.type === 'update' ? event.update.sessionUpdate : event.type);
  assert.deepEqual(kinds, ['queued', 'agent_thought_chunk', 'tool_call', 'tool_call_update', 'agent_message_chunk', 'agent_message_chunk']);
  const result = await turn;
  assert.equal(result.text, 'Done now.');
  assert.equal(result.thought, 'Hmm.');
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(result.cancelled, false);
  assert.deepEqual(result.engineUsage, { inputTokens: 1, outputTokens: 2, totalTokens: 3 });
  assert.equal(result.usage.modelCalls, 2);
  assert.equal(result.limit, null);
  assert.deepEqual(result.toolCalls, [{ toolCallId: 't1', title: 'Read', kind: 'read', status: 'completed', rawOutput: { ok: true } }]);
  assert.equal(session.turn, null);
  // Iterating after the end replays everything; textStream gives the reply's pieces.
  const pieces = [];
  for await (const piece of turn.textStream()) pieces.push(piece);
  assert.deepEqual(pieces, ['Done ', 'now.']);
});

test('a prompt\'s content: a string, a block, or blocks', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession();
  await session.prompt('Hi');
  await session.prompt({ type: 'image', data: 'AAAA', mimeType: 'image/png' });
  await session.prompt([{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }]);
  assert.deepEqual(agneta.calls('session/prompt').map(({ params }) => params.prompt.length), [1, 1, 2]);
  assert.deepEqual(agneta.calls('session/prompt')[0].params, { sessionId: 's1', prompt: [{ type: 'text', text: 'Hi' }] });
});

test('cancel sends session/cancel; an aborted signal does the same; the turn ends cancelled', async (t) => {
  let finish;
  const { agneta, client } = await setUp(t, {
    handlers: { 'session/prompt': () => new Promise((resolve) => { finish = () => resolve({ result: { stopReason: 'cancelled' } }); }) }
  });
  agneta.received.length = 0;
  const session = await client.newSession();
  const turn = session.prompt('Slowly');
  await new Promise((resolve) => setTimeout(resolve, 20));
  turn.cancel();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(agneta.calls('session/cancel').map(({ params, id }) => [params.sessionId, id]), [['s1', undefined]]);
  finish();
  assert.equal((await turn).cancelled, true);

  const controller = new AbortController();
  const second = session.prompt('Slowly', { signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 20));
  controller.abort();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(agneta.calls('session/cancel').length, 2);
  finish();
  assert.equal((await second).stopReason, 'cancelled');
});

test('steering a running turn, and NoTurnRunningError without one', async (t) => {
  let finish;
  const { agneta, client } = await setUp(t, {
    handlers: {
      'session/prompt': () => new Promise((resolve) => { finish = () => resolve({ result: { stopReason: 'end_turn' } }); }),
      'agneta/steer': () => finish ? { result: { delivery: 'accepted', runId: 'r1' } } : undefined
    }
  });
  const session = await client.newSession();
  await assert.rejects(session.steer('Hurry'), NoTurnRunningError);
  const turn = session.prompt('Go');
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(await turn.steer('Also this'), { delivery: 'accepted', runId: 'r1' });
  assert.deepEqual(agneta.calls('agneta/steer').at(-1).params, { sessionId: 's1', prompt: [{ type: 'text', text: 'Also this' }] });
  finish();
  await turn;
  const next = session.prompt('Another turn');
  await assert.rejects(turn.steer('Too late'), NoTurnRunningError);
  await next.steer('For this turn');
  assert.equal(agneta.calls('agneta/steer').length, 3);
  finish();
  await next;
});

test('the user\'s Stop ends the session; the turn ends with stoppedBy', async (t) => {
  const { client } = await setUp(t, {
    handlers: {
      'session/prompt': (message, peer) => new Promise((resolve) => {
        peer.notify('agneta/sessionStopped', { sessionId: message.params.sessionId, stoppedBy: 'user' });
        setTimeout(() => resolve({ result: { stopReason: 'cancelled' } }), 10);
      })
    }
  });
  const session = await client.newSession();
  const stopped = client.next('sessionStopped');
  const ended = session.next('ended');
  const result = await session.prompt('Go');
  assert.deepEqual((await ended)[0], { reason: 'stopped', stoppedBy: 'user' });
  assert.equal((await stopped)[0].stoppedBy, 'user');
  assert.equal(result.stoppedBy, 'user');
  assert.equal(result.cancelled, true);
  assert.deepEqual(session.ended, { reason: 'stopped', stoppedBy: 'user' });
  assert.equal(client.session(session.id), undefined);
});

test('a contained session whose socket or port the app stopped serving: why reaches ended and the turn', async (t) => {
  const why = 'loopback port 8125 is served by another program now, not Example, so this contained session was stopped';
  const { client } = await setUp(t, {
    handlers: {
      'session/prompt': (message, peer) => new Promise((resolve) => {
        peer.notify('agneta/sessionStopped', { sessionId: message.params.sessionId, stoppedBy: 'reach', reason: why });
        setTimeout(() => resolve({ result: { stopReason: 'cancelled' } }), 10);
      })
    }
  });
  const session = await client.newSession();
  const ended = session.next('ended');
  const turn = session.prompt('Go');
  const events = [];
  for await (const event of turn) events.push(event);
  const result = await turn;
  assert.deepEqual((await ended)[0], { reason: 'stopped', stoppedBy: 'reach', detail: why });
  assert.deepEqual(events.find((event) => event.type === 'stopped'), { type: 'stopped', stoppedBy: 'reach', detail: why });
  assert.equal(result.stoppedBy, 'reach');
});

test('a limit Agneta enforced: the result says so, and the session ended', async (t) => {
  const { client } = await setUp(t, {
    handlers: {
      'session/prompt': (message, peer) => {
        peer.notify('agneta/sessionStopped', { sessionId: message.params.sessionId, stoppedBy: 'limit' });
        return { result: { sessionId: message.params.sessionId, stopReason: 'cancelled', _meta: { 'agneta/limit': { limit: 'maxSeconds', value: 60, sessionEnded: true } } } };
      }
    }
  });
  const session = await client.newSession();
  const result = await session.prompt('Go');
  assert.deepEqual(result.limit, { limit: 'maxSeconds', value: 60, sessionEnded: true });
  assert.equal(result.stoppedBy, 'limit');
});

test('a rate limit: a turn event, a session event, and a RateLimitedError', async (t) => {
  const { client } = await setUp(t, {
    handlers: {
      'session/prompt': (message, peer) => {
        const details = { account: 'p1', message: 'Rate limit exceeded', resetsAt: '2026-11-19T15:00:00.000000Z' };
        peer.notify('agneta/rateLimited', { ...details, sessionId: message.params.sessionId });
        return { error: { code: -32603, message: 'Rate limit exceeded', data: { agneta: { rateLimited: details } } } };
      }
    }
  });
  const session = await client.newSession();
  const seen = [];
  session.on('rateLimited', (details) => seen.push(details.resetsAt));
  const turn = session.prompt('Go');
  const events = [];
  await assert.rejects(async () => { for await (const event of turn) events.push(event.type); }, RateLimitedError);
  await assert.rejects(turn, (error) => error instanceof RateLimitedError && error.resetsAt.getUTCHours() === 15);
  assert.deepEqual(events, ['rateLimited']);
  assert.deepEqual(seen, ['2026-11-19T15:00:00.000000Z']);
  assert.equal(session.turn, null, 'the next prompt may go');
});

test('a paused account refuses the prompt with PausedError', async (t) => {
  const { client } = await setUp(t, {
    handlers: { 'session/prompt': () => ({ error: { code: -32013, message: 'Claude is paused in Agneta', data: { agneta: { paused: 'p1' } } } }) }
  });
  const session = await client.newSession();
  await assert.rejects(session.prompt('Go'), (error) => error instanceof PausedError && error.account === 'p1');
});

test('an engine still downloading: the client waits, reporting progress, then opens', async (t) => {
  let attempts = 0;
  const { client } = await setUp(t, {
    handlers: {
      'session/new': () => (++attempts < 3
        ? { error: { code: -32015, message: 'Agneta is downloading what OpenCode needs; try again shortly', data: { agneta: { engineDownloading: { engine: 'opencode', received: attempts * 10, total: 100 } } } } }
        : undefined)
    }
  });
  const progress = [], events = [];
  client.on('engineDownloading', (value) => events.push(value.received));
  const original = globalThis.setTimeout;
  // Skip the 2-second waits.
  globalThis.setTimeout = (fn, ms, ...args) => original(fn, ms === 2000 ? 1 : ms, ...args);
  try {
    const session = await client.newSession({ engine: 'opencode', onDownloadProgress: (value) => progress.push(value) });
    assert.equal(session.id, 's1');
  } finally {
    globalThis.setTimeout = original;
  }
  assert.deepEqual(progress, [{ engine: 'opencode', received: 10, total: 100 }, { engine: 'opencode', received: 20, total: 100 }]);
  assert.deepEqual(events, [10, 20]);
  attempts = 0;
  await assert.rejects(client.newSession({ waitForDownload: false }), (error) => error instanceof EngineDownloadingError && error.progress.total === 100);
});

test('a refused policy is UnenforceableError, naming the field and reason', async (t) => {
  const { client } = await setUp(t, {
    handlers: { 'session/new': () => ({ error: { code: -32602, message: 'Agneta can\'t enforce sandbox: no', data: { agneta: { unenforceable: ['sandbox'], reason: 'no' } } } }) }
  });
  await assert.rejects(client.newSession({ policy: { sandbox: 'developer' } }), (error) => error instanceof UnenforceableError && error.fields[0] === 'sandbox' && error.reason === 'no');
  assert.equal(client.sessions.length, 0);
});

test('updates that arrive before session/new answers are kept in history; a load\'s replay too', async (t) => {
  const { agneta, client } = await setUp(t, {
    handlers: {
      'session/new': (message, peer, state) => {
        const id = `s${++state.sessions}`;
        peer.notify('session/update', update(id, { sessionUpdate: 'available_commands_update', availableCommands: [] }));
        return { result: { sessionId: id, _meta: { agneta: { account: 'p1', dedicatedEngine: false, sandbox: 'contained', capabilities: { engine: 'goose' } } } } };
      },
      'session/load': (message, peer) => {
        peer.notify('session/update', update(message.params.sessionId, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'Earlier' } }));
        peer.notify('session/update', update(message.params.sessionId, text('Reply')));
        return undefined;
      }
    }
  });
  const session = await client.newSession();
  assert.deepEqual(session.history.map(({ sessionUpdate }) => sessionUpdate), ['available_commands_update']);
  const loaded = await client.loadSession('s-old', { mcpServers: [], policy: { tools: 'read' } });
  assert.equal(loaded.id, 's-old');
  assert.equal(loaded.resumed, true);
  assert.deepEqual(loaded.history.map(({ sessionUpdate }) => sessionUpdate), ['user_message_chunk', 'agent_message_chunk']);
  assert.deepEqual(agneta.calls('session/load')[0].params, { sessionId: 's-old', cwd: workspace, mcpServers: [], _meta: { 'agneta/policy': { tools: 'read' } } });
});

test('appTools asks for the app\'s tools up front on new, load and fork, and reads what the session got', async (t) => {
  const { agneta, client } = await setUp(t, {
    handlers: {
      'session/new': (message, peer, state) => ({ result: { sessionId: `s${++state.sessions}`, _meta: { agneta: { account: 'p1', dedicatedEngine: true, sandbox: 'contained', capabilities: { engine: 'claude-code' }, appTools: { load: 'always', upfront: true } } } } })
    }
  });
  const session = await client.newSession({ appTools: 'always' });
  assert.deepEqual(agneta.calls('session/new')[0].params._meta, { 'agneta/appTools': { load: 'always' } });
  assert.deepEqual(session.appTools, { load: 'always', upfront: true });
  await client.loadSession('s-old', { mcpServers: [], appTools: 'engine' });
  assert.deepEqual(agneta.calls('session/load')[0].params._meta, { 'agneta/appTools': { load: 'engine' } });
  await session.fork({ appTools: 'always' });
  assert.deepEqual(agneta.calls('agneta/fork')[0].params._meta, { 'agneta/appTools': { load: 'always' } });
  // Not given: nothing sent, so Agneta keeps the original's.
  await session.fork();
  assert.equal(agneta.calls('agneta/fork')[1].params._meta, undefined);
});

test('policy.builtins narrows the engine\'s own tools, and session.builtins reads what the session has', async (t) => {
  const { agneta, client } = await setUp(t, {
    handlers: {
      'session/new': (message, peer, state) => ({ result: { sessionId: `s${++state.sessions}`, _meta: { agneta: { account: 'p1', dedicatedEngine: true, sandbox: 'developer', capabilities: { engine: 'claude-code' }, builtins: ['read', 'edit', 'execute'] } } } })
    }
  });
  const session = await client.newSession({ policy: { tools: 'workspace', builtins: ['read', 'edit', 'execute'] } });
  assert.deepEqual(agneta.calls('session/new')[0].params._meta['agneta/policy'], { tools: 'workspace', builtins: ['read', 'edit', 'execute'] });
  assert.deepEqual(session.builtins, ['read', 'edit', 'execute']);
  // Refused where the engine can't honour it: the field and the reason, typed.
  const refusing = await setUp(t, {
    handlers: {
      'session/new': () => ({ error: { code: -32602, message: "Agneta can't enforce builtins: Goose always offers its load_skill tool", data: { agneta: { unenforceable: ['builtins'], reason: 'Goose always offers its load_skill tool' } } } })
    }
  });
  await assert.rejects(refusing.client.newSession({ policy: { builtins: ['read'] } }), (error) => error instanceof UnenforceableError && error.fields[0] === 'builtins');
});

test('an aborted close keeps the handle registered for a retry', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession();
  await assert.rejects(session.close({ signal: AbortSignal.abort() }), AbortedError);
  assert.equal(agneta.calls('session/close').length, 0);
  assert.equal(session.ended, null);
  assert.equal(client.session(session.id), session);
  await session.close();
  assert.equal(agneta.calls('session/close').length, 1);
  assert.deepEqual(session.ended, { reason: 'closed' });
});

test('a close with a lost reply can reconcile an already closed session', async (t) => {
  let closed = false;
  const { client } = await setUp(t, { handlers: {
    'session/close': () => {
      if (closed) return { error: { code: -32602, message: 'Unknown session' } };
      closed = true;
      return null; // Agneta closed it, but the acknowledgement never arrived.
    }
  } });
  const session = await client.newSession();
  await assert.rejects(session.close({ timeout: 50 }), TimeoutError);
  assert.equal(session.ended, null);
  await session.close();
  assert.equal(closed, true);
  assert.deepEqual(session.ended, { reason: 'closed' });
  assert.equal(client.session(session.id), undefined);
});

test('an ended handle cannot submit work to a resumed session', async (t) => {
  const { agneta, client } = await setUp(t);
  const old = await client.newSession();
  await old.close();
  const current = await client.loadSession(old.id);
  await assert.rejects(old.prompt('stale').result, InvalidParamsError);
  await assert.rejects(old.steer('stale'), InvalidParamsError);
  await assert.rejects(old.setMode('plan'), InvalidParamsError);
  await assert.rejects(old.setModel('opus'), InvalidParamsError);
  await assert.rejects(old.setInstructions('stale'), InvalidParamsError);
  old.cancel();
  assert.equal((await current.prompt('current')).text, 'Hello there.');
  assert.equal(agneta.calls('session/prompt').length, 1);
  for (const method of ['agneta/steer', 'session/set_mode', 'session/set_config_option', 'agneta/instructions/set', 'session/cancel']) {
    assert.equal(agneta.calls(method).length, 0, method);
  }
  assert.equal((await old.readTrace()).complete, true);
  assert.equal((await old.fork()).forkOf, old.id);
});

test('loading after a lost close reply retires the earlier handle', async (t) => {
  let fail = false;
  const { agneta, client } = await setUp(t, {
    handlers: {
      'session/close': () => null,
      'session/load': (message, peer) => {
        peer.notify('session/update', update(message.params.sessionId, text('Replayed')));
        return fail ? { error: { code: -32603, message: 'Internal error' } } : undefined;
      }
    }
  });
  const old = await client.newSession();
  const oldUpdates = [];
  old.on('update', (u) => oldUpdates.push(u));
  await assert.rejects(old.close({ timeout: 50 }), TimeoutError);
  // A load that fails gives the id back to the earlier handle, and its replay goes nowhere.
  fail = true;
  await assert.rejects(client.loadSession(old.id));
  assert.equal(client.session(old.id), old);
  assert.equal(old.ended, null);
  fail = false;
  const current = await client.loadSession(old.id);
  // The replay reaches the new handle, never the earlier one.
  assert.deepEqual(current.history.map(({ sessionUpdate }) => sessionUpdate), ['agent_message_chunk']);
  assert.deepEqual(oldUpdates, []);
  assert.deepEqual(old.ended, { reason: 'closed' });
  await old.close();
  assert.equal(agneta.calls('session/close').length, 1);
  assert.equal(client.session(current.id), current);
});

test('fork, close, mode and instructions', async (t) => {
  const { agneta, client } = await setUp(t);
  const session = await client.newSession();
  const fork = await session.fork({ instructions: 'Review it.' });
  assert.equal(fork.forkOf, 's1');
  assert.deepEqual(agneta.calls('agneta/fork')[0].params, { sessionId: 's1', mcpServers: [], _meta: { 'agneta/instructions': { text: 'Review it.' } } });
  await session.setMode('plan');
  assert.deepEqual(agneta.calls('session/set_mode')[0].params, { sessionId: 's1', modeId: 'plan' });
  await session.setInstructions('More.', { mode: 'append', key: 'notes' });
  assert.deepEqual(agneta.calls('agneta/instructions/set')[0].params, { sessionId: 's1', text: 'More.', mode: 'append', key: 'notes' });
  const ended = session.next('ended');
  await session.close();
  assert.deepEqual((await ended)[0], { reason: 'closed' });
  await session.close(); // a second close does nothing
  assert.equal(agneta.calls('session/close').length, 1);
  assert.deepEqual(client.sessions, [fork]);
});

test('live trace records, overflow, and reading a trace page by page', async (t) => {
  const records = Array.from({ length: 5 }, (_, index) => ({ v: 1, seq: index + 1, t: 'x', mono: 0, task: 's1', turn: 0, type: 'event', kind: 'prompt' }));
  const { agneta, client } = await setUp(t, {
    handlers: {
      'agneta/trace/read': (message) => {
        const after = message.params.after ?? 0;
        const page = records.filter(({ seq }) => seq > after).slice(0, 2);
        return { result: { records: page, next: page.at(-1)?.seq ?? null, complete: after + 2 >= records.length } };
      }
    }
  });
  const session = await client.newSession({ trace: { live: true, include: ['acp'] } });
  assert.deepEqual(agneta.calls('session/new')[0].params._meta['agneta/trace'], { live: true, include: ['acp'] });
  const live = session.next('trace');
  agneta.notify('agneta/trace', { sessionId: 's1', records: records.slice(0, 2) });
  assert.equal((await live)[0].length, 2);
  const overflow = session.next('traceOverflow');
  agneta.notify('agneta/trace', { sessionId: 's1', records: [], overflow: { after: 2 } });
  assert.equal((await overflow)[0], 2);
  const read = [];
  for await (const record of session.traceRecords({ after: 0, limit: 2 })) read.push(record.seq);
  assert.deepEqual(read, [1, 2, 3, 4, 5]);
  assert.deepEqual(agneta.calls('agneta/trace/read').map(({ params }) => params.after), [0, 2, 4]);
  assert.equal((await client.readTrace('s1', { after: 4 })).records.length, 1);
});

test('permission requests: declined by default; answered by the client\'s or the session\'s handler', async (t) => {
  const errors = [];
  let answer = 'allow';
  const { agneta, client } = await setUp(t, {}, { permissions: (request) => { if (answer === 'throw') throw new Error('oops'); return answer; } });
  client.on('error', (error) => errors.push(error.message));
  const session = await client.newSession();
  const peer = agneta.peers[0];
  const options = [{ optionId: 'a1', kind: 'allow_always', name: 'Always' }, { optionId: 'a0', kind: 'allow_once', name: 'Once' }, { optionId: 'r0', kind: 'reject_once', name: 'No' }];
  const ask = async (sessionId = 's1') => (await peer.request('session/request_permission', { sessionId, toolCall: { toolCallId: 't', kind: 'edit', title: 'Edit' }, options })).result;
  assert.deepEqual(await ask(), { outcome: { outcome: 'selected', optionId: 'a0' } }, 'allow picks once');
  answer = 'reject';
  assert.deepEqual(await ask(), { outcome: { outcome: 'selected', optionId: 'r0' } });
  answer = 'throw';
  // A handler that throws declines, by the engine's own reject option.
  assert.deepEqual(await ask(), { outcome: { outcome: 'selected', optionId: 'r0' } });
  assert.deepEqual(errors, ['oops']);
  const seen = [];
  const off = session.onPermission((request) => { seen.push([request.session === session, request.toolCall.title]); return { optionId: 'a1' }; });
  assert.deepEqual(await ask(), { outcome: { outcome: 'selected', optionId: 'a1' } });
  assert.deepEqual(seen, [[true, 'Edit']]);
  off();
  answer = 'cancel';
  assert.deepEqual(await ask(), { outcome: { outcome: 'cancelled' } });

  // No handler anywhere: declined, by the engine's reject option.
  const bare = await setUp(t);
  await bare.client.newSession();
  assert.deepEqual((await bare.agneta.peers[0].request('session/request_permission', { sessionId: 's1', toolCall: { toolCallId: 't' }, options })).result, { outcome: { outcome: 'selected', optionId: 'r0' } });
});

test('permissionResponse falls back to the other option of the kind, else cancels', () => {
  const always = [{ optionId: 'x', kind: 'allow_always', name: 'Always' }];
  assert.deepEqual(permissionResponse('allow', always), { outcome: { outcome: 'selected', optionId: 'x' } });
  assert.deepEqual(permissionResponse('reject', always), { outcome: { outcome: 'cancelled' } });
  assert.deepEqual(permissionResponse({ outcome: { outcome: 'cancelled' } }, always), { outcome: { outcome: 'cancelled' } });
});

test('reading the access report: engines per provider, and a provider to run on', () => {
  const access = accessReport({
    providers: [
      { ...accessReport().providers[0], id: 'paused', paused: true },
      accessReport().providers[0],
      { id: 'k', label: 'Key', kind: 'openai-key', paused: false, needsSignIn: false, engines: ['goose'], defaultEngine: 'goose', uncontained: [], sandboxLevels: { goose: ['contained', 'developer'] } }
    ]
  });
  const engines = providerEngines(access, access.providers[1]);
  assert.deepEqual(engines.map(({ id, state, uncontained, isDefault, sandboxLevels }) => [id, state, uncontained, isDefault, sandboxLevels.join('+')]),
    [['claude-code', 'ready', false, true, 'contained+developer'], ['goose', 'downloadable', true, false, 'developer']]);
  assert.equal(chooseProvider(access).account, 'p1');
  assert.equal(chooseProvider(access, { engine: 'goose', sandbox: 'contained' }).account, 'k');
  assert.equal(chooseProvider(access, { kind: 'claude', engine: 'goose' }).engine.id, 'goose');
  assert.equal(chooseProvider(access, { kind: 'chatgpt' }), null);
});

test('live trace records that arrive before session/new answers reach the listeners given in `on`', async (t) => {
  const record = { v: 1, seq: 1, t: 'x', mono: 0, task: 's1', turn: 0, type: 'meta' };
  const { client } = await setUp(t, {
    handlers: {
      'session/new': (message, peer) => {
        peer.notify('agneta/trace', { sessionId: 's1', records: [record] });
        peer.notify('session/update', update('s1', text('early')));
        return undefined;
      }
    }
  });
  const traced = [], updates = [];
  const session = await client.newSession({ trace: true, on: { trace: (records) => traced.push(...records), update: (value) => updates.push(value) } });
  assert.deepEqual(traced, [record]);
  assert.deepEqual(session.history.map(({ sessionUpdate }) => sessionUpdate), ['agent_message_chunk']);
  assert.deepEqual(updates, [], 'early updates are the history, not events');
});

test('disconnect while loading retires the temporarily unregistered old handle', async (t) => {
  const { agneta, client } = await setUp(t, { handlers: {
    'session/load': (_message, peer) => { peer.destroy(); return null; }
  } });
  const old = await client.newSession();
  await assert.rejects(client.loadSession(old.id), (error) => error.kind === 'connectionClosed');
  assert.equal(old.ended?.reason, 'disconnected');
  assert.equal(client.sessions.length, 0);
  assert.equal(agneta.calls('session/load').length, 1);
});

test('overlapping loads are rejected before resetting or stealing the first replay buffer', { timeout: 3000 }, async (t) => {
  let finish;
  const { agneta, client } = await setUp(t, { handlers: {
    'session/load': (message, peer) => new Promise((resolve) => {
      peer.notify('session/update', update(message.params.sessionId, text('Replay')));
      finish = () => resolve({ result: {} });
    })
  } });
  const old = await client.newSession();
  const first = client.loadSession(old.id, { timeout: 1000 });
  while (!finish) await new Promise((resolve) => setTimeout(resolve, 1));
  const second = client.loadSession(old.id, { timeout: 1000 });
  const rejected = assert.rejects(second, TurnBusyError);
  finish();
  await rejected;
  const loaded = await first;
  assert.equal(agneta.calls('session/load').length, 1);
  assert.deepEqual(loaded.history.map((u) => u.content.text), ['Replay']);
});

test('failed-load replay is discarded but a terminal stop is retained', async (t) => {
  const { client } = await setUp(t, { handlers: {
    'session/load': (message, peer) => {
      peer.notify('session/update', update(message.params.sessionId, text('Failed replay')));
      peer.notify('agneta/sessionStopped', { sessionId: message.params.sessionId, stoppedBy: 'reach', reason: 'server stopped' });
      return { error: { code: -32603, message: 'load failed' } };
    }
  } });
  const old = await client.newSession();
  let updates = 0;
  old.on('update', () => updates++);
  await assert.rejects(client.loadSession(old.id));
  assert.deepEqual(old.ended, { reason: 'stopped', stoppedBy: 'reach', detail: 'server stopped' });
  assert.equal(client.session(old.id), undefined);
  assert.equal(updates, 0);
});

test('loading a running turn cannot steal its updates', { timeout: 3000 }, async (t) => {
  let finish;
  const { agneta, client } = await setUp(t, { handlers: { 'session/prompt': (message, peer) => new Promise((resolve) => {
    finish = () => {
      peer.notify('session/update', update(message.params.sessionId, text('Still here')));
      resolve({ result: { stopReason: 'end_turn' } });
    };
  }) } });
  const session = await client.newSession();
  const turn = session.prompt('Running');
  await assert.rejects(client.loadSession(session.id), TurnBusyError);
  while (!finish) await new Promise((resolve) => setTimeout(resolve, 1));
  finish();
  assert.equal((await turn).text, 'Still here');
  assert.equal(agneta.calls('session/load').length, 0);
});

test('observer-triggered prompt abort sends graceful cancel after its prompt', { timeout: 3000 }, async (t) => {
  let prompt;
  const { agneta, client } = await setUp(t, { handlers: {
    'session/prompt': (message) => { prompt = message; return null; },
    'session/cancel': (_message, peer) => {
      if (prompt) peer.send({ id: prompt.id, result: { stopReason: 'cancelled' } });
      return null;
    }
  } });
  const session = await client.newSession();
  const controller = new AbortController();
  client.connection.on('message', (message, direction) => {
    if (direction === 'out' && message.method === 'session/prompt') controller.abort();
  });
  const turn = session.prompt('Start and stop', { signal: controller.signal, timeout: 1000 });
  assert.equal((await turn).cancelled, true);
  assert.deepEqual(agneta.received.filter((m) => ['session/prompt', 'session/cancel'].includes(m.method)).map((m) => m.method),
    ['session/prompt', 'session/cancel']);
});
