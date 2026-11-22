// A stand-in Agneta for unit tests: a small WebSocket server (RFC 6455 text frames of any size, close, ping) speaking
// JSON-RPC, with scripted answers, notifications and requests to the app. It can be put in states a real Agneta can't
// be put in at will: an engine downloading, a queue, a rate limit, the user's Stop, a refused upgrade.
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';

function frame(text, opcode = 0x1) {
  const body = Buffer.from(text);
  let head;
  if (body.length < 126) head = Buffer.from([0x80 | opcode, body.length]);
  else if (body.length < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x80 | opcode; head[1] = 126; head.writeUInt16BE(body.length, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x80 | opcode; head[1] = 127; head.writeBigUInt64BE(BigInt(body.length), 2);
  }
  return Buffer.concat([head, body]);
}

/**
 * Starts the stand-in. `answer(message, peer)` returns `{result}`, `{error}`, a promise of one, or undefined (no
 * answer). `refuse: true` refuses every upgrade with 403, as Agneta refuses a browser's. `port`: a fixed one.
 */
export async function standIn(answer = () => undefined, { refuse = false, port = 0 } = {}) {
  const server = createServer((request, response) => { response.writeHead(426); response.end(); });
  const peers = new Set();
  const received = [];
  let nextId = 1000;

  server.on('upgrade', (request, socket) => {
    if (refuse || request.headers.origin) {
      socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    const accept = createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const waiting = new Map();
    const peer = {
      headers: request.headers,
      send(message) { if (!socket.destroyed) socket.write(frame(JSON.stringify({ jsonrpc: '2.0', ...message }))); },
      notify(method, params) { peer.send({ method, params }); },
      /** A request to the app; resolves with its whole response. */
      request(method, params) {
        const id = nextId++;
        return new Promise((resolve) => { waiting.set(id, resolve); peer.send({ id, method, params }); });
      },
      close(code = 1000) {
        const payload = Buffer.alloc(2);
        payload.writeUInt16BE(code);
        if (!socket.destroyed) socket.end(Buffer.concat([Buffer.from([0x88, 2]), payload]));
      },
      destroy() { socket.destroy(); }
    };
    peers.add(peer);
    socket.on('close', () => peers.delete(peer));
    socket.on('error', () => {});
    let buffer = Buffer.alloc(0);
    socket.on('data', (data) => {
      buffer = Buffer.concat([buffer, data]);
      for (;;) {
        if (buffer.length < 2) return;
        const opcode = buffer[0] & 0x0f;
        let length = buffer[1] & 0x7f, at = 2;
        if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); at = 4; }
        else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); at = 10; }
        if (buffer.length < at + 4 + length) return;
        const mask = buffer.subarray(at, at + 4);
        const payload = Buffer.from(buffer.subarray(at + 4, at + 4 + length));
        for (let index = 0; index < payload.length; index++) payload[index] ^= mask[index % 4];
        buffer = buffer.subarray(at + 4 + length);
        if (opcode === 0x8) { socket.end(frame('', 0x8)); return; }
        if (opcode === 0x9) { socket.write(frame(payload.toString(), 0xA)); continue; }
        if (opcode !== 0x1) continue;
        const message = JSON.parse(payload.toString('utf8'));
        received.push(message);
        if (message.method === undefined && waiting.has(message.id)) {
          const resolve = waiting.get(message.id);
          waiting.delete(message.id);
          resolve(message);
          continue;
        }
        Promise.resolve(answer(message, peer)).then((reply) => {
          if (reply && message.id !== undefined) peer.send({ id: message.id, ...reply });
        });
      }
    });
  });
  server.listen(port, '127.0.0.1');
  await once(server, 'listening');
  return {
    port: server.address().port,
    get url() { return `ws://127.0.0.1:${server.address().port}/acp`; },
    received,
    /** Requests received of a method. */
    calls(method) { return received.filter((message) => message.method === method); },
    get peers() { return [...peers]; },
    notify(method, params) { for (const peer of peers) peer.notify(method, params); },
    /** Drops every connection without a close frame, as when Agneta quits. */
    drop() { for (const peer of peers) peer.destroy(); },
    async close() {
      for (const peer of peers) peer.destroy();
      await new Promise((resolve) => server.close(resolve));
    }
  };
}

export const workspace = '/tmp/agneta-stand-in/workspace';

/** An access report like agnetad's, with overrides. */
export function accessReport(overrides = {}) {
  return {
    providers: [{
      id: 'p1', label: 'Claude', kind: 'claude', paused: false, needsSignIn: false, engines: ['claude-code', 'goose'],
      defaultEngine: 'claude-code', uncontained: ['goose'],
      sandboxLevels: { 'claude-code': ['contained', 'developer'], goose: ['developer'] }
    }],
    engines: [
      { id: 'claude-code', name: 'Claude Code', state: 'ready', capabilities: { engine: 'claude-code', steer: true, fork: false, instructionsBetweenTurns: false, reportsCost: false } },
      { id: 'goose', name: 'Goose', state: 'downloadable', size: 113000000 }
    ],
    allowedEngines: 'all',
    scope: { tools: 'app-only', folders: [workspace], sandbox: 'contained' },
    workspace,
    ...overrides
  };
}

export const catalogReport = (connected = true) => ({
  providers: [
    { kind: 'claude', name: 'Claude plan', connected, engines: [{ id: 'claude-code', sandboxLevels: ['contained', 'developer'] }, { id: 'goose', sandboxLevels: ['developer'], uncontained: true }] },
    { kind: 'chatgpt', name: 'ChatGPT plan', connected: false, engines: [{ id: 'codex', sandboxLevels: ['contained', 'developer'] }] }
  ],
  engines: [{ id: 'claude-code', name: 'Claude Code', state: 'ready' }],
  connected
});

// MARK: agneta/result, as Agneta answers it (Sources/AgnetaKit/Results, Router+Results.swift)

const resultKey = 'agneta/result';
const refuse = (reason) => ({ error: { code: -32602, message: `Agneta can't enforce agneta/result: ${reason}`, data: { agneta: { unenforceable: [resultKey], reason } } } });
const usableName = (name) => /^[a-z][a-z0-9_]{0,31}$/.test(name) && !name.includes('__') && name !== 'any';

/** `_meta["agneta/result"]` on a session's opening: `{ declaration }`, or `{ refusal }`. Agneta's rules, its validator aside. */
export function parseDeclaration(value) {
  if (value === undefined || value === null) return { declaration: null };
  if (typeof value !== 'object' || Array.isArray(value)) return { refusal: refuse('it must be an object') };
  const unknown = Object.keys(value).sort().find((key) => !['schema', 'schemas', 'every'].includes(key));
  if (unknown) return { refusal: refuse(`unknown field ${unknown}`) };
  let schemas, every = value.every;
  if (value.schema !== undefined && value.schemas === undefined) {
    if (value.every !== undefined) return { refusal: refuse('"schema" already asks for its result on every prompt') };
    schemas = { result: value.schema };
    every = 'result';
  } else if (value.schemas !== undefined && value.schema === undefined) {
    schemas = value.schemas;
    if (!schemas || typeof schemas !== 'object' || !Object.keys(schemas).length) return { refusal: refuse('"schemas" must name at least one schema') };
  } else return { refusal: refuse('declare either "schema" or "schemas"') };
  if (every !== undefined && typeof every !== 'string') return { refusal: refuse('"every" must be a schema\'s name') };
  if (Object.keys(schemas).length > 8) return { refusal: refuse('a session may declare at most 8 schemas') };
  for (const [name, schema] of Object.entries(schemas)) {
    if (!usableName(name)) return { refusal: refuse(`"${name}" isn't a usable name`) };
    if (!(schema?.type === 'object' || (Array.isArray(schema?.type) && schema.type.length === 1 && schema.type[0] === 'object'))) {
      return { refusal: refuse(`schema "${name}" at /type: the root must be "type": "object"`) };
    }
    if ('if' in schema) return { refusal: refuse(`schema "${name}" at /if: if isn't supported`) };
  }
  if (every !== undefined && !(every in schemas)) return { refusal: refuse(`"every" names "${every}", which isn't declared`) };
  return { declaration: { schemas, every: every ?? null } };
}

/** `_meta["agneta/result"]` on a prompt: `{ ask }` (null for none), or `{ refusal }`. */
function parseAsk(value, declaration) {
  if (value === undefined || value === null) return { ask: declaration?.every ? { name: declaration.every, attempts: 3 } : null };
  if (value === false) return { ask: null };
  if (typeof value !== 'object' || Array.isArray(value)) return { refusal: refuse('a prompt asks with {"name": "…"}, or false') };
  if (!declaration) return { refusal: refuse('this session declared no results') };
  if (value.schema !== undefined) return { refusal: refuse('a schema is declared when the session opens and asked for by name here') };
  const unknown = Object.keys(value).sort().find((key) => !['name', 'attempts'].includes(key));
  if (unknown) return { refusal: refuse(`unknown field ${unknown}`) };
  // A name given as null is refused, as Agneta does; only a missing one takes every.
  const name = 'name' in value ? value.name : declaration.every;
  if (typeof name !== 'string' || !(name in declaration.schemas)) return { refusal: refuse(`"${name}" wasn't declared when the session opened`) };
  const attempts = value.attempts ?? 3;
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > 10) return { refusal: refuse('attempts must be a whole number from 1 to 10') };
  return { ask: { name, attempts } };
}

/** A small validator, enough for the tests: type (lists too), required, properties, additionalProperties false, items, enum. */
function check(schema, value, path = '', schemaPath = '') {
  const issues = [];
  const kind = (v) => v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v;
  if (schema.type !== undefined) {
    const types = [schema.type].flat();
    if (!types.some((type) => type === kind(value) || (type === 'number' && kind(value) === 'integer'))) {
      return [{ path, keyword: 'type', message: `expected ${types.join(' or ')}, got ${kind(value)}`, schemaPath: `${schemaPath}/type` }];
    }
  }
  if (schema.enum && !schema.enum.some((item) => JSON.stringify(item) === JSON.stringify(value))) {
    issues.push({ path, keyword: 'enum', message: 'not one of the allowed values', schemaPath: `${schemaPath}/enum` });
  }
  if (kind(value) === 'object') {
    for (const key of schema.required ?? []) {
      if (!(key in value)) issues.push({ path, keyword: 'required', message: `missing ${key}`, schemaPath: `${schemaPath}/required` });
    }
    for (const [key, item] of Object.entries(value)) {
      if (schema.properties?.[key]) issues.push(...check(schema.properties[key], item, `${path}/${key}`, `${schemaPath}/properties/${key}`));
      else if (schema.additionalProperties === false) issues.push({ path: `${path}/${key}`, keyword: 'additionalProperties', message: `${key} isn't allowed`, schemaPath: `${schemaPath}/additionalProperties` });
    }
  }
  if (kind(value) === 'array' && schema.items) value.forEach((item, index) => issues.push(...check(schema.items, item, `${path}/${index}`, `${schemaPath}/items`)));
  return issues;
}

const depth = (value) => value && typeof value === 'object' ? 1 + Math.max(0, ...Object.values(value).map(depth)) : 0;

/**
 * One turn's result, by ResultTurn's rules: every call counts, the first valid value wins, and the outcome's precedence
 * (valid; attempts used up; an abnormal end; a refused value; nothing submitted).
 */
function resultTurn(ask, declaration) {
  let submissions = 0, accepted, lastRefused;
  return {
    submit(tool, value) {
      // A tool the session doesn't have is answered "There's no tool …" and isn't counted.
      if (!(tool.slice('submit_'.length) in declaration.schemas)) return;
      if (accepted !== undefined || submissions >= ask.attempts) return;
      submissions++;
      if (tool !== `submit_${ask.name}`) return;
      const issues = check(declaration.schemas[ask.name], value);
      if (!issues.length) accepted = value;
      else lastRefused = { value, issues };
    },
    report(stopReason, stopped) {
      const base = { name: ask.name, mechanism: 'tool', attempts: submissions };
      const refused = () => depth(lastRefused.value) <= 64 ? { value: lastRefused.value, issues: lastRefused.issues } : { valueOmitted: 'nested too deeply to report', issues: lastRefused.issues };
      if (accepted !== undefined) return { status: 'valid', ...base, value: accepted };
      if (lastRefused && submissions >= ask.attempts) return { status: 'invalid', ...base, ...refused() };
      const abnormal = stopped || stopReason === 'cancelled' || stopReason === 'max_turn_requests' ? 'stopped'
        : stopReason === 'max_tokens' ? 'truncated' : stopReason === 'refusal' ? 'refused' : null;
      if (abnormal) return { status: 'missing', ...base, reason: abnormal, ...(lastRefused ? refused() : {}) };
      if (lastRefused) return { status: 'invalid', ...base, ...refused() };
      return { status: 'missing', ...base, reason: 'not-submitted' };
    }
  };
}

/**
 * A prompt that may ask for a result, scripted by its text, a line each: `CALL <tool> <json>` calls a tool (`submit_<name>`
 * is the result tool, its updates tagged as Agneta tags them), `STOP <stopReason>` ends the turn so, `FAIL` makes the
 * engine stop after the calls (-32603 "The engine stopped") and `FAIL <code>` answer with an error of its own; either way
 * the turn's result is in the error's `data.agneta.result`, as Agneta puts it once a turn has started. Anything else is a
 * reply.
 */
function scriptedPrompt(params, peer, state) {
  const id = params.sessionId;
  const declaration = state.declarations.get(id) ?? null;
  const parsed = parseAsk(params._meta?.[resultKey], declaration);
  if (parsed.refusal) return parsed.refusal;
  const turn = parsed.ask ? resultTurn(parsed.ask, declaration) : null;
  const text = params.prompt.map((block) => block.text ?? '').join('\n');
  let stopReason = 'end_turn', fail = null, calls = 0;
  const notify = (update) => peer.notify('session/update', { sessionId: id, update });
  for (const line of text.split('\n')) {
    const call = /^CALL (\S+) (.*)$/.exec(line);
    if (call) {
      const [, tool, json] = call;
      const toolCallId = `call-${++calls}`;
      const name = tool.startsWith('submit_') && declaration && tool.slice(7) in declaration.schemas ? tool.slice(7) : null;
      const tag = declaration && tool.startsWith('submit_') ? { _meta: { agneta: { result: { name } } } } : {};
      const value = JSON.parse(json);
      notify({ sessionUpdate: 'tool_call', toolCallId, title: tool, kind: 'other', status: 'pending', rawInput: value, ...tag });
      if (tag._meta) turn?.submit(tool, value);
      notify({ sessionUpdate: 'tool_call_update', toolCallId, status: 'completed', ...tag });
    } else if (line.startsWith('STOP ')) stopReason = line.slice(5);
    else if (line === 'FAIL' || line.startsWith('FAIL ')) fail = line === 'FAIL' ? -32603 : Number(line.slice(5));
    else if (line) notify({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: line } });
  }
  const report = turn?.report(fail !== null ? 'error' : stopReason, fail !== null);
  if (fail === -32603) return { error: { code: fail, message: 'The engine stopped', ...(report ? { data: { agneta: { result: report } } } : {}) } };
  if (fail !== null) return { error: { code: fail, message: 'The engine failed', data: { engine: 'own', ...(report ? { agneta: { result: report } } : {}) } } };
  return { result: { stopReason, _meta: report ? { [resultKey]: report } : {} } };
}

/**
 * Agneta's behaviour, enough for the client: pairs (Always Allow unless `remembered: false`, with a pairing code),
 * initializes known tokens, opens sessions, and answers prompts with `prompt(message, peer)` (default: a short reply).
 * Structured results as Agneta answers them: declarations, asks, their refusals, and a prompt that asks for a result
 * scripted by its text (`scriptedPrompt`). `extensions`: what `initialize` lists; `recordSchemas: false`, an Agneta whose
 * session replies don't carry the declared schemas yet. Every handler can be replaced through
 * `handlers[method]`.
 */
export function agnetaLike({
  remembered = true, code = '123456', access = accessReport(), handlers = {}, extensions = ['agneta/policy', 'agneta/access', resultKey],
  recordSchemas = true
} = {}) {
  const state = { tokens: new Set(['kept-token']), sessions: 0, access, config: new Map(), declarations: new Map() };
  /** A session's declaration, as Agneta keeps it: given, the original's (load, fork), or refused. */
  const declare = (params, original) => {
    const given = params._meta?.[resultKey];
    if (given === undefined && original !== undefined) return { declaration: state.declarations.get(original) ?? null };
    return parseDeclaration(given);
  };
  const opened = (id, declaration, extra = {}) => {
    if (declaration) state.declarations.set(id, declaration);
    else state.declarations.delete(id);
    return { result: sessionResult(id, { ...extra, ...(declaration ? { results: { declared: Object.keys(declaration.schemas).sort(), every: declaration.every, mechanism: 'tool', ...(recordSchemas ? { schemas: declaration.schemas } : {}) } } : {}) }) };
  };
  const sessionResult = (id, extra = {}) => ({
    sessionId: id,
    configOptions: [
      { id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: 'sonnet', options: [{ value: 'sonnet', name: 'Sonnet' }, { value: 'opus', name: 'Opus' }] },
      { id: 'effort', name: 'Effort', category: 'thought_level', type: 'select', currentValue: 'medium', options: [{ group: 'all', name: 'All', options: [{ value: 'low', name: 'Low' }, { value: 'medium', name: 'Medium' }, { value: 'high', name: 'High' }] }] }
    ],
    _meta: { agneta: { account: 'p1', dedicatedEngine: true, sandbox: 'contained', capabilities: access.engines[0].capabilities, ...extra } }
  });
  const answer = async (message, peer) => {
    const custom = handlers[message.method];
    if (custom) {
      const reply = await custom(message, peer, state);
      if (reply !== undefined) return reply;
    }
    const params = message.params ?? {};
    switch (message.method) {
      case 'agneta/catalog': return { result: catalogReport() };
      case 'agneta/setup': return { result: { shown: true } };
      case 'agneta/pair': {
        if (code) peer.notify('agneta/pairingCode', { code, name: params.name });
        const token = `token-${state.tokens.size}`;
        state.tokens.add(token);
        return { result: { token, remembered, access: state.access, unmet: [] } };
      }
      case 'initialize':
        if (!state.tokens.has(params._meta?.agneta?.token)) return { error: { code: -32001, message: 'Pair with Agneta first', data: { agneta: { needsPairing: true } } } };
        return { result: { protocolVersion: 1, agentCapabilities: { loadSession: true }, authMethods: [], _meta: { agneta: { extensions, access: state.access } } } };
      case 'agneta/access': return { result: state.access };
      case 'session/new': {
        const { declaration, refusal } = declare(params);
        return refusal ?? opened(`s${++state.sessions}`, declaration);
      }
      case 'session/load': {
        const { declaration, refusal } = declare(params, params.sessionId);
        if (refusal) return refusal;
        return { result: (({ sessionId, ...rest }) => rest)(opened(params.sessionId, declaration, { resumed: true }).result) };
      }
      case 'agneta/fork': {
        const { declaration, refusal } = declare(params, params.sessionId);
        return refusal ?? opened(`s${++state.sessions}`, declaration, { forkOf: params.sessionId });
      }
      case 'session/prompt': {
        if (state.declarations.has(params.sessionId) || params._meta?.[resultKey] !== undefined) return scriptedPrompt(params, peer, state);
        peer.notify('session/update', { sessionId: params.sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Hello ' } } });
        peer.notify('session/update', { sessionId: params.sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'there.' } } });
        return { result: { stopReason: 'end_turn', _meta: { 'agneta/usage': { modelCalls: 1, models: ['m'], inputTokens: 3, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 0, cost: null, costKind: 'plan-equivalent', taskCost: null, billing: 'subscription', account: 'p1', ms: 12, msToFirstToken: 5, basis: 'engine-ledger' } } } };
      }
      case 'session/close': return { result: {} };
      case 'session/set_config_option': {
        const current = state.config.get(params.sessionId) ?? sessionResult('x').configOptions;
        const next = current.map((option) => option.id === params.configId ? { ...option, currentValue: params.value } : option);
        state.config.set(params.sessionId, next);
        return { result: { configOptions: next } };
      }
      case 'session/set_mode': return { result: {} };
      case 'agneta/instructions/set': return { result: {} };
      case 'agneta/steer': return { error: { code: -32010, message: 'No turn is running to steer' } };
      case 'agneta/trace/read': return { result: { records: [], next: null, complete: true } };
      default:
        if (message.id === undefined) return undefined;
        return { error: { code: -32601, message: `Agneta doesn't offer ${message.method}` } };
    }
  };
  return { answer, state };
}
