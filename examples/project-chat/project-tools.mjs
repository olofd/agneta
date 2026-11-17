import { randomBytes, timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';

export const project = {
  name: 'Field Notes',
  description: 'A small Mac app for organizing research.',
  facts: [
    'Version 1.2 is due Thursday.',
    'Offline search and PDF export are ready to announce.',
    'Shared folders are still in testing and should stay out of the announcement.'
  ]
};

const tools = [
  {
    name: 'read_project_brief',
    description: 'Read the current project facts before answering a question or drafting a note.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'propose_note',
    description: 'Stage a draft note for human review in Project Chat. Only the user can save it.',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string', minLength: 1, maxLength: 600 } },
      required: ['text'],
      additionalProperties: false
    }
  }
];

const content = (text) => ({ content: [{ type: 'text', text }] });
const maxBodyBytes = 16 * 1024;

// One stateless Streamable HTTP endpoint and a fresh bearer per ACP session.
export async function startProjectTools({ readBrief, stageNote }) {
  const token = randomBytes(32).toString('base64url');
  const expected = Buffer.from(`Bearer ${token}`);
  const server = createServer({ requestTimeout: 10_000, headersTimeout: 5000 }, async (req, res) => {
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
          serverInfo: { name: 'project-chat', version: '0.1.0' }
        } });
      }
      case 'ping':
        return reply({ result: {} });
      case 'tools/list':
        return reply({ result: { tools } });
      case 'tools/call': {
        const { name, arguments: args = {} } = json.params ?? {};
        if (name === 'read_project_brief') {
          readBrief();
          return reply({ result: content([project.name, project.description, ...project.facts].join('\n')) });
        }
        if (name !== 'propose_note') return reply({ error: { code: -32602, message: 'Unknown project tool' } });
        const text = typeof args?.text === 'string' ? args.text.trim() : '';
        if (!text || text.length > 600) return reply({ result: { ...content('Send a note of 1 to 600 characters.'), isError: true } });
        if (!stageNote(text)) return reply({ result: {
          ...content('The app cannot accept a draft right now. Leave any existing proposal for the user to review.'),
          isError: true
        } });
        return reply({ result: content('Draft staged for the user to review. It has not been saved.') });
      }
      default:
        return reply({ error: { code: -32601, message: 'Method not supported by Project Chat' } });
    }
  });

  // Port 0 lets macOS select a free port for every chat.
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    registration: {
      type: 'http',
      name: 'project',
      url: `http://127.0.0.1:${server.address().port}/mcp`,
      headers: [{ name: 'Authorization', value: `Bearer ${token}` }]
    },
    close() {
      server.close();
      server.closeAllConnections();
    }
  };
}
