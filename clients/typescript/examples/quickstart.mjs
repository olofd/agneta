// Pair with Agneta and run one prompt, streaming the reply.
//   node examples/quickstart.mjs ["your prompt"] [--dev]      (AGNETA_PORT=<port> for an isolated instance)
// The first run opens Agneta's approval window; choose Always Allow and the next run connects without asking (the
// token is kept in ~/.agneta-quickstart-token, readable only by you). A real app keeps it in the Keychain.
import { homedir } from 'node:os';
import { join } from 'node:path';
import { AgnetaClient, isAgnetaError } from '@agneta/client';
import { fileTokenStore, openAgneta } from '@agneta/client/node';

const dev = process.argv.includes('--dev');
const prompt = process.argv.slice(2).find((arg) => !arg.startsWith('--')) ?? 'Say hello in five words.';

const client = new AgnetaClient({
  name: 'Agneta Quickstart',
  build: dev ? 'dev' : 'release',
  ...(process.env.AGNETA_PORT ? { port: Number(process.env.AGNETA_PORT) } : {}),
  tokens: fileTokenStore(join(homedir(), `.agneta-quickstart-token${dev ? '-dev' : ''}`)),
  // Agneta isn't running: a real app asks the user first. Here, running the script is the yes. (An isolated instance
  // has no URL to open it by.)
  ...(process.env.AGNETA_PORT ? {} : { launch: () => openAgneta(dev ? 'dev' : 'release') })
});
client.on('pairingCode', (code) => console.log(`Agneta shows a code: check it's ${code}, then allow the app.`));

try {
  const access = await client.connect();
  console.log(`Connected. Providers: ${access.providers.map((provider) => `${provider.label} (${provider.engines.join(', ')})`).join('; ')}`);

  // App-only tools and no approvals: the agent can only answer. Nothing on this Mac is touched.
  const session = await client.newSession({ policy: { tools: 'app-only', approval: 'never-ask', limits: { maxTurns: 5, maxSeconds: 120 } }, task: 'Quickstart' });
  console.log(`Session on ${session.engine}, model ${session.model?.current ?? 'the engine\'s default'}.\n`);

  const turn = session.prompt(prompt);
  for await (const text of turn.textStream()) process.stdout.write(text);
  const result = await turn;
  console.log(`\n\n${result.stopReason} · ${result.usage?.modelCalls ?? '?'} model calls · ${result.usage?.inputTokens ?? '?'} in, ${result.usage?.outputTokens ?? '?'} out`);
  await session.close();
} catch (error) {
  if (!isAgnetaError(error)) throw error;
  console.error(`${error.message}\n${error.advice}`);
  process.exitCode = 1;
} finally {
  client.close();
}
