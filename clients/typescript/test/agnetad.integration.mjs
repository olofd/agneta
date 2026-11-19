// The library against the real headless Agneta (agnetad) running Goose on the fake model (agneta-fakes), as Project
// Chat's smoke test does: a temporary --home, ports in 47800–47899 (Agneta's own Swift tests use 474xx and 476xx,
// Replica Bench 479xx), nothing of the user's touched, and every process stopped by its process group. The fake model
// answers "CALL <tool> <json>" with that tool call and "slowly" after 5 s, so this proves the wire, not an agent.
//
// From the repository root: scripts/fetch-engines && swift build --product agnetad --product agneta-fakes
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { constants } from 'node:fs';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer as createHTTPServer } from 'node:http';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import {
  AgnetaClient, httpMcpServer, memoryTokenStore, NeedsPairingError, NotRunningError, UnenforceableError, chooseProvider
} from '../dist/index.js';
import { fileTokenStore } from '../dist/node.js';

const repo = fileURLToPath(new URL('../../../', import.meta.url));

/** A free port in 47800–47899, never one of Agneta's own (47321, 47331) or its other tests'. */
async function portInRange(skip = []) {
  for (let port = 47800 + Math.floor(Math.random() * 50); port < 47900; port++) {
    if (skip.includes(port)) continue;
    const listener = createServer();
    const free = await new Promise((resolve) => {
      listener.once('error', () => resolve(false));
      listener.listen(port, '127.0.0.1', () => resolve(true));
    });
    if (free) {
      await new Promise((resolve) => listener.close(resolve));
      return port;
    }
  }
  throw new Error('No free port in 47800–47899.');
}

/** Starts a process in its own group, so stopping it stops whatever it started. */
function start(command, args) {
  const child = spawn(command, args, { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  let output = '';
  for (const stream of [child.stdout, child.stderr]) {
    stream.setEncoding('utf8');
    stream.on('data', (text) => { output = (output + text).slice(-20000); });
  }
  let stopped = false;
  child.on('error', (error) => { output += error.message; });
  const exited = new Promise((resolve) => child.once('close', () => { stopped = true; resolve(); }));
  const signal = (name) => { try { process.kill(-child.pid, name); } catch {} };
  return {
    get output() { return output; },
    get stopped() { return stopped; },
    async stop() {
      if (stopped) return;
      signal('SIGTERM');
      const watchdog = setTimeout(() => signal('SIGKILL'), 5000);
      try { await exited; } finally { clearTimeout(watchdog); }
    }
  };
}

async function waitFor(condition, description, process) {
  for (let attempt = 0; attempt < 100 && !process.stopped; attempt++) {
    if (await condition()) return;
    await delay(100);
  }
  assert.fail(`${description}\n${process.output}`);
}

/** A minimal Streamable HTTP MCP server with one tool, `echo`, behind a bearer: an app's own tools. */
async function echoTools() {
  const token = randomBytes(16).toString('hex');
  const calls = [];
  const server = createHTTPServer(async (req, res) => {
    if (req.headers.authorization !== `Bearer ${token}`) return res.writeHead(401).end();
    let body = '';
    for await (const chunk of req) body += chunk;
    const json = JSON.parse(body || '{}');
    if (json.id === undefined) return res.writeHead(202).end();
    const reply = (fields) => res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ jsonrpc: '2.0', id: json.id, ...fields }));
    switch (json.method) {
      case 'initialize': return reply({ result: { protocolVersion: json.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'echo', version: '1' } } });
      case 'tools/list': return reply({ result: { tools: [{ name: 'echo', description: 'Echoes its text.', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] } });
      case 'tools/call':
        calls.push(json.params);
        return reply({ result: { content: [{ type: 'text', text: `echo: ${json.params?.arguments?.text}` }] } });
      case 'ping': return reply({ result: {} });
      // Anything else, such as a newer MCP's server/discover, isn't offered: the client falls back to initialize.
      default: return reply({ error: { code: -32601, message: `${json.method} isn't offered` } });
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    calls,
    port: server.address().port,
    registration: httpMcpServer({ name: 'test', url: `http://127.0.0.1:${server.address().port}/mcp`, token }),
    close() { server.close(); server.closeAllConnections(); }
  };
}

test('the client against agnetad: open, catalog, pair, sessions, streaming, tools, cancel, refusals, traces, fork, load, tokens', { timeout: 240_000 }, async (t) => {
  const hostBinary = join(repo, '.build/debug/agnetad');
  const fakes = join(repo, '.build/debug/agneta-fakes');
  const goose = join(repo, 'Engines', 'bin', process.arch === 'arm64' ? 'arm64' : 'x86_64', 'goose-acp');
  await access(hostBinary, constants.X_OK).catch(() => assert.fail('Run swift build --product agnetad at the repository root.'));
  await access(fakes, constants.X_OK).catch(() => assert.fail('Run swift build --product agneta-fakes at the repository root.'));
  await access(goose, constants.X_OK).catch(() => assert.fail('Run scripts/fetch-engines at the repository root.'));

  const root = await mkdtemp(join(tmpdir(), 'agneta-client-'));
  const children = [];
  const clients = [];
  const tools = await echoTools();
  t.after(async () => {
    for (const client of clients) client.close();
    tools.close();
    for (const child of children.reverse()) await child.stop();
    await rm(root, { recursive: true, force: true });
  });

  const modelPort = await portInRange();
  const modelURL = `http://127.0.0.1:${modelPort}/v1`;
  const modelLog = join(root, 'model.jsonl');
  const model = start(fakes, ['model', String(modelPort), modelLog]);
  children.push(model);
  await waitFor(() => fetch(`${modelURL}/models`, { signal: AbortSignal.timeout(1000) }).then((res) => res.ok, () => false), 'The fake model did not start.', model);

  const port = await portInRange([modelPort]);
  let host;
  const startHost = () => {
    host = start(hostBinary, ['--goose', goose, '--home', join(root, 'host'), '--port', String(port),
      '--env', 'GOOSE_MODEL=gpt-4o', '--env', 'OPENAI_API_KEY=fake', '--env', `OPENAI_BASE_URL=${modelURL}`]);
    children.push(host);
  };

  // 1. Agneta isn't running: without launch, NotRunningError; when the user declines, the same; when they agree, the
  // client waits for it ("opening" it starts agnetad here) and connects.
  const tokens = fileTokenStore(join(root, 'app', 'agneta-token'));
  const asked = [];
  let agree = false;
  const client = new AgnetaClient({
    name: 'Client Test', port, tokens,
    scope: { tools: 'workspace', providers: 'all', engines: ['goose'], sandbox: 'contained' },
    launch: (info) => { asked.push(info.url); if (agree) startHost(); return agree; },
    launchTimeout: 30_000
  });
  clients.push(client);
  await assert.rejects(client.connect(), NotRunningError);
  agree = true;
  const catalog = await client.catalog();
  assert.equal(asked.length, 2);
  assert.equal(catalog.connected, true);
  assert.ok(catalog.providers.some((provider) => provider.kind === 'openai-key' && provider.connected));
  assert.ok(catalog.engines.some((engine) => engine.id === 'goose' && engine.state === 'ready'));

  // 2. Pairing (agnetad approves everything, contained, Always Allow): the token is kept.
  const paired = client.next('paired');
  const access_ = await client.connect();
  const [pairing] = await paired;
  assert.equal(pairing.remembered, true);
  assert.deepEqual(pairing.unmet.filter((item) => item.provider === 'openai-key'), []);
  assert.equal(await tokens.load(), pairing.token);
  assert.equal(client.state, 'connected');
  assert.deepEqual(access_.providers.map(({ id }) => id), ['dev']);
  assert.equal(access_.scope.sandbox, 'contained');
  assert.equal(typeof access_.workspace, 'string');
  assert.ok(client.extensions.includes('agneta/policy'));
  const choice = chooseProvider(access_, { engine: 'goose', sandbox: 'contained' });
  assert.equal(choice.account, 'dev');

  // 3. A session with a policy, the app's tools, a title, instructions and a live trace.
  const records = [];
  const session = await client.newSession({
    account: choice.account, engine: 'goose', mcpServers: [tools.registration],
    policy: { tools: 'workspace', sandbox: 'contained', network: 'none', approval: 'never-ask', limits: { maxTurns: 20, maxSeconds: 120 } },
    task: { title: 'Client test', stopWarning: 'Nothing is kept' }, instructions: 'Be brief.', trace: true
  });
  session.on('trace', (batch) => records.push(...batch));
  assert.match(session.id, /^s_/);
  assert.equal(session.engine, 'goose');
  assert.equal(session.sandbox, 'contained');
  assert.equal(session.capabilities.steer, true);
  assert.equal(session.model?.current, 'gpt-4o');
  await session.setConfigOption(session.model.id, session.model.current);

  // 4. Streaming.
  const turn = session.prompt('Hello there');
  const kinds = new Set();
  for await (const event of turn) if (event.type === 'update') kinds.add(event.update.sessionUpdate);
  const result = await turn;
  assert.equal(result.stopReason, 'end_turn');
  assert.ok(result.text.length > 0, 'the fake model replied');
  assert.ok(kinds.has('agent_message_chunk'));
  assert.equal(result.usage.billing, 'api-key');
  assert.equal(result.usage.modelCalls, 1);

  // 5. The app's own tool, through the MCP server with its bearer.
  const toolTurn = await session.prompt('CALL test__echo {"text":"hi"}');
  assert.deepEqual(tools.calls.map((call) => call.arguments), [{ text: 'hi' }]);
  assert.ok(toolTurn.toolCalls.some((call) => call.status === 'completed'), JSON.stringify(toolTurn.toolCalls));

  // 6. Steering and cancelling a slow turn.
  const slow = session.prompt('Reply slowly.');
  await waitFor(async () => (await readFile(modelLog, 'utf8')).includes('Reply slowly.'), 'The fake model never got the slow prompt.', model);
  const steered = await slow.steer('And briefly.').catch((error) => error);
  assert.ok(steered.delivery === 'accepted' || steered.kind === 'noTurnRunning', String(steered));
  slow.cancel();
  assert.equal((await slow).cancelled, true);

  // 7. Instructions between turns, where the engine can.
  assert.equal(session.capabilities.instructionsBetweenTurns, true);
  await session.setInstructions('Also be kind.', { mode: 'append', key: 'tone' });

  // 8. Refusals, typed: more than the grant's sandbox; an unknown policy field.
  await assert.rejects(client.newSession({ policy: { tools: 'workspace', sandbox: 'developer' } }),
    (error) => error instanceof UnenforceableError && error.fields.includes('sandbox') && typeof error.reason === 'string');
  await assert.rejects(client.newSession({ policy: { bogus: true } }), (error) => error instanceof UnenforceableError && error.fields.includes('bogus'));

  // 9. Traces: live records arrived, and reading afterwards gets the same, page by page.
  await waitFor(() => records.some((record) => record.type === 'event' && record.kind === 'turn'), 'No live turn record.', host);
  assert.equal(records[0].type, 'meta');
  const read = [];
  for await (const record of session.traceRecords({ limit: 5 })) read.push(record);
  // Read by default without raw `acp` frames, so the sequence skips them; in order, from `meta`, across pages of 5.
  assert.equal(read[0].type, 'meta');
  assert.ok(read.length > 5);
  assert.ok(read.every((record, index) => index === 0 || record.seq > read[index - 1].seq));
  const turns = (list) => list.filter((record) => record.type === 'event' && record.kind === 'turn').map(({ seq }) => seq);
  assert.deepEqual(turns(read).slice(0, turns(records).length), turns(records), 'the same turns as live');

  // 10. Fork, then close and load the original again (its conversation replayed).
  assert.equal(session.capabilities.fork, true);
  const fork = await session.fork({ mcpServers: [] });
  assert.equal(fork.forkOf, session.id);
  assert.notEqual(fork.id, session.id);
  await fork.close();
  await session.close();
  assert.equal(client.sessions.length, 0);
  const loaded = await client.loadSession(session.id, { mcpServers: [tools.registration] });
  assert.equal(loaded.resumed, true);
  assert.ok(loaded.history.length > 0, 'the conversation was replayed');
  assert.equal((await loaded.prompt('Hello again')).stopReason, 'end_turn');
  await loaded.close();

  // 11. The kept token: a new client connects without pairing (quietly). A token Agneta doesn't know is forgotten.
  client.close();
  const again = new AgnetaClient({ name: 'Client Test', port, tokens });
  clients.push(again);
  await again.connect({ pair: 'never' });
  assert.equal(again.remembered, true);
  again.close();
  const stale = memoryTokenStore('not-a-token-agneta-knows');
  const removed = new AgnetaClient({ name: 'Client Test', port, tokens: stale });
  clients.push(removed);
  await assert.rejects(removed.connect({ pair: 'never' }), NeedsPairingError);
  assert.equal(await stale.load(), null);

  // 12. Agneta quits: the connection is gone, and the open session ended with it.
  const last = new AgnetaClient({ name: 'Client Test', port, tokens });
  clients.push(last);
  await last.connect({ pair: 'never' });
  const open = await last.newSession({ policy: { tools: 'app-only', approval: 'never-ask' } });
  const ended = open.next('ended');
  await host.stop();
  const [end] = await ended;
  assert.equal(end.reason, 'disconnected');
  assert.equal(last.state, 'disconnected');
  await assert.rejects(last.connect({ pair: 'never' }), NotRunningError);
});
