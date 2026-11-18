import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { constants } from 'node:fs';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { ProjectChat, memoryTokens } from '../chat.mjs';

const repo = fileURLToPath(new URL('../../../', import.meta.url));

async function availablePort() {
  const listener = createServer().listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const { port } = listener.address();
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

function start(command, args) {
  const child = spawn(command, args, { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  for (const stream of [child.stdout, child.stderr]) {
    stream.setEncoding('utf8');
    stream.on('data', (text) => { output += text; });
  }
  let stopped = false;
  child.on('error', (error) => { output += error.message; });
  const exited = new Promise((resolve) => child.once('close', () => {
    stopped = true;
    resolve();
  }));
  return {
    get output() { return output; },
    get stopped() { return stopped; },
    async stop() {
      if (stopped) return;
      child.kill('SIGTERM');
      const watchdog = setTimeout(() => child.kill('SIGKILL'), 5000);
      try {
        await exited;
      } finally {
        clearTimeout(watchdog);
      }
    }
  };
}

async function waitFor(condition, description, process) {
  for (let attempt = 0; attempt < 80 && !process.stopped; attempt++) {
    if (await condition()) return;
    await delay(100);
  }
  assert.fail(`${description}\n${process.output}`);
}

test('Project Chat pairs, reads a brief, stages a draft, and stops a turn', { timeout: 35_000 }, async (t) => {
  const hostBinary = join(repo, '.build/debug/agnetad');
  const fakes = join(repo, '.build/debug/agneta-fakes');
  const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const goose = join(repo, 'Engines', 'bin', arch, 'goose-acp');
  await access(hostBinary, constants.X_OK).catch(() => assert.fail('Run swift build --product agnetad at the repository root.'));
  await access(fakes, constants.X_OK).catch(() => assert.fail('Run swift build --product agneta-fakes at the repository root.'));
  await access(goose, constants.X_OK).catch(() => assert.fail('Run scripts/fetch-engines at the repository root.'));

  const root = await mkdtemp(join(tmpdir(), 'agneta-project-chat-'));
  const children = [];
  let chat;
  t.after(async () => {
    chat?.disconnect();
    for (const child of children.reverse()) await child.stop();
    await rm(root, { recursive: true, force: true });
  });

  const modelPort = await availablePort();
  const modelURL = `http://127.0.0.1:${modelPort}/v1`;
  const modelLog = join(root, 'model.jsonl');
  const model = start(fakes, ['model', String(modelPort), modelLog]);
  children.push(model);
  await waitFor(
    () => fetch(`${modelURL}/models`, { signal: AbortSignal.timeout(1000) }).then((res) => res.ok, () => false),
    'The fake provider did not start.',
    model
  );

  const port = await availablePort();
  const tokens = memoryTokens();
  // Agneta isn't running: Project Chat asks whether to open it. "Not Now" leaves it disconnected; "Open" starts the
  // headless host here (the app opens agneta-dev://), and Project Chat waits for it, then connects.
  let asked = 0, open = false;
  const openAgneta = async () => {
    asked += 1;
    if (!open) return false;
    children.push(start(hostBinary, [
      '--goose', goose, '--home', join(root, 'host'), '--port', String(port),
      '--env', 'GOOSE_MODEL=gpt-4o', '--env', 'OPENAI_API_KEY=fake', '--env', `OPENAI_BASE_URL=${modelURL}`
    ]));
    return true;
  };
  chat = new ProjectChat(port, { tokens, openAgneta });
  await chat.connect();
  assert.equal(chat.view.phase, 'disconnected');
  assert.match(chat.view.status, /Agneta isn't running\. Open it, then connect\./);
  assert.equal(asked, 1);

  open = true;
  await chat.connect();
  assert.equal(asked, 2);
  assert.equal(chat.view.phase, 'ready', chat.view.status);
  // What agnetad lets it use: its one development provider, on Goose.
  assert.deepEqual(chat.view.providers.map((provider) => provider.id), ['dev']);
  assert.equal(chat.view.account, 'dev');
  assert.equal(chat.view.engine, 'goose');
  // The session opens ahead of the first message, so the engine's models can be chosen first: Goose's, gpt-4o current.
  await waitFor(() => chat.view.models.length > 0, 'Goose\'s models never showed.', children[0]);
  assert.equal(chat.view.model, 'gpt-4o');
  assert.ok(chat.view.models.some(({ value }) => value === 'gpt-4o'));

  // The fake provider recognizes CALL so this checks the wire flow without
  // depending on a live model's tool choices.
  await chat.send('CALL project__read_project_brief {}');
  assert.equal(chat.view.status, 'Ready');
  assert.ok(chat.view.messages.some(({ role, text }) => role === 'tool' && text === 'Read the project brief'));
  assert.ok(chat.view.messages.some(({ role, text }) => role === 'assistant' && text.includes('Field Notes')));

  const draft = 'Offline search and PDF export are ready.';
  await chat.send(`CALL project__propose_note ${JSON.stringify({ text: draft })}`);
  assert.equal(chat.view.draft, draft);
  assert.deepEqual(chat.view.notes, []);
  chat.review(true);
  assert.deepEqual(chat.view.notes, [draft]);

  await chat.send('CALL project__propose_note {"text":"Draft to dismiss"}');
  assert.equal(chat.view.draft, 'Draft to dismiss');
  chat.review(false);
  assert.equal(chat.view.draft, null);
  assert.deepEqual(chat.view.notes, [draft]);

  const turn = chat.send('Reply slowly.');
  assert.equal(chat.view.phase, 'running');
  await waitFor(async () => (await readFile(modelLog, 'utf8')).includes('Reply slowly.'),
    'The fake provider did not receive the slow prompt.', model);
  chat.stop();
  await turn;
  assert.equal(chat.view.status, 'Turn stopped.');

  await chat.newChat();
  assert.equal(chat.view.phase, 'ready', chat.view.status);
  assert.deepEqual(chat.view.messages, []);
  assert.deepEqual(chat.view.notes, [draft]);
  chat.disconnect();
  assert.equal(chat.view.phase, 'disconnected');

  // agnetad answers Always Allow: the token was kept, and the next launch connects without asking.
  assert.equal(typeof await tokens.load(), 'string');
  const relaunched = new ProjectChat(port, { tokens });
  await relaunched.connect({ quiet: true });
  assert.equal(relaunched.view.phase, 'ready', relaunched.view.status);
  relaunched.disconnect();

  // A token Agneta no longer accepts (access removed) is forgotten, and a quiet connect says so rather than asking.
  await tokens.save('a-token-agneta-no-longer-accepts');
  const removed = new ProjectChat(port, { tokens });
  await removed.connect({ quiet: true });
  assert.equal(removed.view.phase, 'disconnected');
  assert.match(removed.view.status, /access was removed/);
  assert.equal(await tokens.load(), null);
});
