// A stand-in Agneta for unit tests: a minimal WebSocket server speaking JSON-RPC, which pairs, initializes and opens
// sessions by the protocol's sandbox rules (docs/APP_PROTOCOL.md, "Sandbox"), so the bench's client and modes check
// can be tested on cases a real Agneta can't be put in at will.
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';

/** A one-connection-at-a-time WebSocket server speaking JSON-RPC through `answer(message)`, on `port` (default: any free one). */
export async function standIn(answer, { port = 0 } = {}) {
  const server = createServer();
  const sockets = new Set();
  const send = (socket, message) => {
    const body = Buffer.from(JSON.stringify(message));
    const head = body.length < 126 ? Buffer.from([0x81, body.length]) : Buffer.from([0x81, 126, body.length >> 8, body.length & 0xff]);
    socket.write(Buffer.concat([head, body]));
  };
  server.on('upgrade', (request, socket) => {
    sockets.add(socket);
    const accept = createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    let buffer = Buffer.alloc(0);
    socket.on('data', (data) => {
      buffer = Buffer.concat([buffer, data]);
      for (;;) {
        if (buffer.length < 2) return;
        const opcode = buffer[0] & 0x0f;
        let length = buffer[1] & 0x7f, at = 2;
        if (length === 126) { length = buffer.readUInt16BE(2); at = 4; }
        if (buffer.length < at + 4 + length) return;
        const mask = buffer.subarray(at, at + 4);
        const payload = Buffer.from(buffer.subarray(at + 4, at + 4 + length).map((byte, index) => byte ^ mask[index % 4]));
        buffer = buffer.subarray(at + 4 + length);
        if (opcode === 8) { socket.end(); return; }
        const message = JSON.parse(payload.toString('utf8'));
        const reply = answer(message);
        if (reply) send(socket, { jsonrpc: '2.0', id: message.id, ...reply });
      }
    });
    socket.on('error', () => {});
  });
  server.listen(port, '127.0.0.1');
  await once(server, 'listening');
  return {
    port: server.address().port,
    /** Sends a notification to every connection, as Agneta sends agneta/accessChanged. */
    notify(method, params) { for (const socket of sockets) send(socket, { jsonrpc: '2.0', method, params }); },
    close() { for (const socket of sockets) socket.destroy(); server.close(); }
  };
}

const order = ['contained', 'developer'];

/**
 * Agneta's side: `grant` is what the user picks in the approval window (default: what the app asked for, else
 * developer); `providers` the access report's providers, with their sandboxLevels and uncontained engines.
 */
export function agnetaLike({ grant, folders, providers } = {}) {
  const calls = [];
  const access = (scope) => ({
    providers: providers ?? [{
      id: 'p1', label: 'Claude', engines: ['claude-code', 'goose'], defaultEngine: 'claude-code',
      sandboxLevels: { 'claude-code': ['contained', 'developer'], goose: ['developer'] }, uncontained: ['goose']
    }],
    engines: [{ id: 'claude-code', name: 'Claude Code', state: 'ready' }, { id: 'goose', name: 'Goose', state: 'downloadable' }],
    scope, workspace: '/tmp/workspace'
  });
  let granted = { tools: 'workspace', folders, sandbox: grant ?? 'developer' };
  let sessions = 0;
  const refuse = (field, reason) => ({ error: { code: -32602, message: `Agneta can't enforce ${field}: ${reason}`, data: { agneta: { unenforceable: [field], reason } } } });
  const answer = (message) => {
    calls.push(message);
    const params = message.params ?? {};
    if (message.method === 'agneta/pair') {
      // As Agneta: the scope's fields, with "any" (or no mode) giving the user's picker its developer start.
      const unknown = Object.keys(params.scope ?? {}).filter((key) => !['tools', 'folders', 'sandbox', 'providers', 'engines'].includes(key));
      if (unknown.length) return refuse('scope', `unknown fields ${unknown.join(', ')}`);
      const asked = params.scope.sandbox === 'any' ? undefined : params.scope.sandbox;
      granted = { tools: params.scope.tools, folders: params.scope.folders, sandbox: grant ?? asked ?? 'developer' };
      return { result: { token: `token-${calls.length}`, remembered: true, access: access(granted) } };
    }
    if (message.method === 'initialize') return { result: { protocolVersion: 1, _meta: { agneta: { access: access(granted) } } } };
    if (message.method === 'session/new') {
      const policy = params._meta?.['agneta/policy'] ?? {};
      if ('access' in policy) return refuse('access', 'isn\'t a policy field Agneta knows');
      const asked = policy.sandbox ?? granted.sandbox;
      if (order.indexOf(asked) > order.indexOf(granted.sandbox)) return refuse('sandbox', 'the user keeps this app\'s tasks contained (Settings → Apps in Agneta); an app can ask for less, not more');
      const provider = access(granted).providers.find(({ id }) => id === params._meta?.agneta?.account);
      const levels = provider?.sandboxLevels?.[params._meta?.agneta?.engine];
      if (levels && !levels.includes(asked)) return refuse('sandbox', `${params._meta.agneta.engine} can't keep ${provider.label}'s tasks contained; choose another engine, or developer access`);
      sessions += 1;
      return { result: { sessionId: `s${sessions}`, configOptions: [], _meta: { agneta: { sandbox: asked, capabilities: { engine: params._meta?.agneta?.engine } } } } };
    }
    if (message.method === 'session/close') return { result: {} };
    return { error: { code: -32601, message: 'no' } };
  };
  return { calls, answer };
}
