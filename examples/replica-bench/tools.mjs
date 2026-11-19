// The app's MCP tools: how the agent reaches the target, sees plots, and hands in its work. As in Project Chat
// (project-tools.mjs), one stateless Streamable HTTP endpoint on loopback with a fresh bearer per ACP session, so
// another session's bearer (or a web page) gets nothing. A real app of this kind offers about 80 such tools; these six have the same
// shapes: plain data, data in bulk, an image result, a handed-in artifact, and a long app-side job (the referee).
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { realpath, stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { isAbsolute, join, relative, sep } from 'node:path';
import { plotResidual } from './png.mjs';
import { describeScore } from './referee.mjs';
import { description, evaluate, evaluateBatch, limits } from './target.mjs';

const numbers = { type: 'array', items: { type: 'number' } };
const params = {
  type: 'object',
  description: 'Parameter values by name; names left out take their defaults (see describe_target).',
  additionalProperties: { type: 'number' }
};

export const tools = [
  {
    name: 'describe_target',
    description: 'The target\'s parameter names, ranges and defaults, the input limits, and how calls behave. Start here.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'evaluate',
    description: `The target's outputs for one input array (1 to ${limits.maxSamples} samples within ±${limits.maxAbsInput}) and parameters. Each call starts from rest.`,
    inputSchema: { type: 'object', properties: { inputs: numbers, params }, required: ['inputs'], additionalProperties: false }
  },
  {
    name: 'evaluate_batch',
    description: `The target's outputs for up to ${limits.maxBatchCases} cases ({inputs, params}) at once, ${limits.maxBatchSamples} samples in all.`,
    inputSchema: {
      type: 'object',
      properties: { cases: { type: 'array', items: { type: 'object', properties: { inputs: numbers, params }, required: ['inputs'] } } },
      required: ['cases'],
      additionalProperties: false
    }
  },
  {
    name: 'plot_residual',
    description: 'A PNG of the target\'s outputs (green) and yours (orange) for the same inputs and parameters, with their difference (red) below on its own scale, and the errors as text.',
    inputSchema: {
      type: 'object',
      properties: { inputs: numbers, params, outputs: { ...numbers, description: 'Your candidate\'s outputs for these inputs.' } },
      required: ['inputs', 'outputs'],
      additionalProperties: false
    }
  },
  {
    name: 'submit_candidate',
    description: 'Hands in a candidate crate for scoring: the path of its folder (with Cargo.toml) inside the workspace, usually "candidate".',
    inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'], additionalProperties: false }
  },
  {
    name: 'score_candidate',
    description: 'The app builds the submitted candidate itself (cargo, offline, no dependencies or build scripts) and scores it on a held-out set you can\'t see: max abs error and RMS error in dB relative to the target. Below -100 dB is a clone.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  }
];

const text = (value) => ({ content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }] });
const failure = (message) => ({ ...text(message), isError: true });
const maxBodyBytes = 8 * 1024 * 1024;

/**
 * Starts the tool server for one session. `workspace` is where submitted paths must lie; `score(path)` runs the
 * referee (referee.mjs) and resolves to its result; `called({tool, ok, ms, summary})` hears every call, the app-side
 * evidence a check reads.
 */
export async function startTools({ workspace, score, called = () => {} }) {
  const token = randomBytes(32).toString('base64url');
  const expected = Buffer.from(`Bearer ${token}`);
  const root = await realpath(workspace);
  let submitted = null;
  // One referee build at a time per session: a second score waits for the first.
  let scoring = Promise.resolve();

  async function call(name, args) {
    switch (name) {
      case 'describe_target':
        return { result: text(description()), summary: 'described the target' };
      case 'evaluate': {
        const outputs = evaluate(args.inputs, args.params);
        return { result: text({ outputs }), summary: `${outputs.length} samples` };
      }
      case 'evaluate_batch': {
        const outputs = evaluateBatch(args.cases);
        return { result: text({ outputs }), summary: `${outputs.length} cases` };
      }
      case 'plot_residual': {
        const target = evaluate(args.inputs, args.params);
        if (!Array.isArray(args.outputs) || args.outputs.length !== target.length) throw new RangeError(`outputs must have ${target.length} numbers, one per input`);
        const { png, stats } = plotResidual(target, args.outputs);
        const db = stats.rmsError === 0 ? '-inf' : (20 * Math.log10(stats.rmsError / (stats.rmsTarget || 1))).toFixed(1);
        return {
          result: { content: [
            { type: 'image', data: png.toString('base64'), mimeType: 'image/png' },
            { type: 'text', text: `Target (green) and yours (orange) above, yours minus the target (red) below. ${stats.samples} samples; max abs error ${stats.maxAbsError.toExponential(3)}; RMS error ${db} dB relative to the target.` }
          ] },
          summary: `plot, ${db} dB`
        };
      }
      case 'submit_candidate': {
        if (typeof args.path !== 'string' || !args.path) throw new RangeError('path must name a folder in the workspace');
        let folder;
        try {
          folder = await realpath(isAbsolute(args.path) ? args.path : join(root, args.path));
        } catch {
          throw new RangeError(`there's no folder ${args.path} in the workspace`);
        }
        if (folder !== root && !folder.startsWith(root + sep)) throw new RangeError('the candidate must be inside the workspace');
        if (!(await stat(join(folder, 'Cargo.toml')).then((info) => info.isFile(), () => false))) throw new RangeError(`${args.path} has no Cargo.toml`);
        submitted = folder;
        const shown = relative(root, folder) || '.';
        return { result: text(`Recorded the candidate at ${shown}. Call score_candidate to have the app build and score it.`), summary: shown };
      }
      case 'score_candidate': {
        if (!submitted) throw new RangeError('submit a candidate first (submit_candidate)');
        const folder = submitted;
        const scored = await (scoring = scoring.then(() => score(folder), () => score(folder)));
        return { result: scored.ok ? text(describeScore(scored)) : failure(describeScore(scored)), summary: scored.ok ? `${scored.rmsErrorDb.toFixed(1)} dB` : `${scored.stage} failed`, ok: scored.ok };
      }
      default:
        return null;
    }
  }

  const server = createServer({ requestTimeout: 60_000, headersTimeout: 5000 }, async (req, res) => {
    const end = (status) => res.writeHead(status).end();
    const supplied = Buffer.from(req.headers.authorization ?? '');
    if (req.headers.origin !== undefined || req.headers.host !== `127.0.0.1:${server.address()?.port}`) return end(403);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return end(401);
    if (req.url !== '/mcp') return end(404);
    if (req.method !== 'POST') return res.writeHead(405, { Allow: 'POST' }).end();

    const chunks = [];
    let size = 0;
    let json;
    try {
      for await (const chunk of req) {
        size += chunk.length;
        if (size <= maxBodyBytes) chunks.push(chunk);
        else {
          res.writeHead(413, { Connection: 'close' }).end();
          return;
        }
      }
      json = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
      return end(400);
    }

    if (json?.jsonrpc !== '2.0' || typeof json.method !== 'string') return end(400);
    if (!Object.hasOwn(json, 'id')) return end(202);
    if (typeof json.id !== 'string' && !Number.isSafeInteger(json.id)) return end(400);
    const envelope = { jsonrpc: '2.0', id: json.id };
    const reply = (body) => res.writeHead(200, { 'Content-Type': 'application/json' })
      .end(JSON.stringify({ ...envelope, ...body }));

    switch (json.method) {
      case 'initialize': {
        const supported = ['2025-03-26', '2025-06-18', '2025-11-25'];
        const requested = json.params?.protocolVersion;
        return reply({ result: {
          protocolVersion: supported.includes(requested) ? requested : '2025-11-25',
          capabilities: { tools: {} },
          serverInfo: { name: 'replica-bench', version: '0.1.0' }
        } });
      }
      case 'ping':
        return reply({ result: {} });
      case 'tools/list':
        return reply({ result: { tools } });
      case 'tools/call': {
        const { name, arguments: args = {} } = json.params ?? {};
        const started = Date.now();
        try {
          const answer = await call(name, args ?? {});
          if (!answer) return reply({ error: { code: -32602, message: 'Unknown Replica Bench tool' } });
          called({ tool: name, ok: answer.ok ?? true, ms: Date.now() - started, at: started, summary: answer.summary });
          return reply({ result: answer.result });
        } catch (error) {
          called({ tool: name, ok: false, ms: Date.now() - started, at: started, summary: error.message });
          return reply({ result: failure(error.message) });
        }
      }
      default:
        return reply({ error: { code: -32601, message: 'Method not supported by Replica Bench' } });
    }
  });

  // Port 0 lets macOS pick a free port for every session.
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    registration: {
      type: 'http',
      name: 'bench',
      url: `http://127.0.0.1:${server.address().port}/mcp`,
      headers: [{ name: 'Authorization', value: `Bearer ${token}` }]
    },
    get submitted() { return submitted; },
    close() {
      server.close();
      server.closeAllConnections();
    }
  };
}
