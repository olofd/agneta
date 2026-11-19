// The probe gateway: how the agent's own programs reach the target. A demanding app's probe kit talks to its app over a
// connection like this, and Agneta's plan carries it as loopback TCP with a per-run token on the policy's toolPorts
// (a Unix socket in the app's TMPDIR sits outside every readable folder). One JSON object per line each way:
//   {"token", "op": "describe" | "evaluate" | "evaluate_batch", "inputs", "params", "cases"}  →  {"ok", ...} | {"ok": false, "error"}
// Every request is recorded: a hit is the app-side proof that a probe ran.
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { description, evaluate, evaluateBatch } from './target.mjs';

const maxLineBytes = 16 * 1024 * 1024;

/** Starts a gateway on an OS-assigned loopback port. `hit` hears every request: {at, op, samples, ok, error}. */
export async function startGateway({ hit = () => {} } = {}) {
  const token = randomBytes(24).toString('base64url');
  const expected = Buffer.from(token);
  const sockets = new Set();

  function answer(request) {
    if (request === null || typeof request !== 'object') return { ok: false, error: 'each line must be one JSON object' };
    const supplied = Buffer.from(typeof request?.token === 'string' ? request.token : '');
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return { ok: false, error: 'wrong or missing token' };
    try {
      switch (request.op) {
        case 'describe': return { ok: true, ...description() };
        case 'evaluate': return { ok: true, outputs: evaluate(request.inputs, request.params) };
        case 'evaluate_batch': return { ok: true, outputs: evaluateBatch(request.cases) };
        default: return { ok: false, error: 'op must be describe, evaluate or evaluate_batch' };
      }
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  const server = createServer((socket) => {
    sockets.add(socket);
    socket.setTimeout(10 * 60_000, () => socket.destroy());
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => {});
    let buffered = '';
    socket.setEncoding('utf8');
    socket.on('data', (text) => {
      buffered += text;
      if (buffered.length > maxLineBytes) {
        socket.end(JSON.stringify({ ok: false, error: 'line too long' }) + '\n');
        return;
      }
      let newline;
      while ((newline = buffered.indexOf('\n')) >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        if (!line.trim()) continue;
        const started = Date.now();
        let request = null;
        try { request = JSON.parse(line); } catch {}
        const reply = answer(request);
        const op = typeof request?.op === 'string' ? request.op.slice(0, 40) : 'unknown';
        const samples = Array.isArray(request?.inputs) ? request.inputs.length
          : Array.isArray(request?.cases) ? request.cases.reduce((sum, entry) => sum + (Array.isArray(entry?.inputs) ? entry.inputs.length : 0), 0) : 0;
        hit({ at: started, op, samples, ok: reply.ok, error: reply.ok ? undefined : reply.error, ms: Date.now() - started });
        socket.write(JSON.stringify(reply) + '\n');
      }
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    host: '127.0.0.1',
    port: server.address().port,
    token,
    close() {
      server.close();
      for (const socket of sockets) socket.destroy();
    }
  };
}
