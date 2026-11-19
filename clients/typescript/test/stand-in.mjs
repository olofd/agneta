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

/**
 * Agneta's behaviour, enough for the client: pairs (Always Allow unless `remembered: false`, with a pairing code),
 * initializes known tokens, opens sessions, and answers prompts with `prompt(message, peer)` (default: a short reply).
 * Every handler can be replaced through `handlers[method]`.
 */
export function agnetaLike({ remembered = true, code = '123456', access = accessReport(), handlers = {} } = {}) {
  const state = { tokens: new Set(['kept-token']), sessions: 0, access, config: new Map() };
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
        return { result: { protocolVersion: 1, agentCapabilities: { loadSession: true }, authMethods: [], _meta: { agneta: { extensions: ['agneta/policy', 'agneta/access'], access: state.access } } } };
      case 'agneta/access': return { result: state.access };
      case 'session/new': return { result: sessionResult(`s${++state.sessions}`) };
      case 'session/load': return { result: (({ sessionId, ...rest }) => rest)(sessionResult(params.sessionId, { resumed: true })) };
      case 'agneta/fork': return { result: sessionResult(`s${++state.sessions}`, { forkOf: params.sessionId }) };
      case 'session/prompt': {
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
