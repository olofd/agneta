// Structured results: pull a contact and the action items out of a text, as a value Agneta checked against a schema.
//   node examples/extract.mjs <file.txt> [--dev]      (AGNETA_PORT=<port> for an isolated instance)
// Pairs as examples/quickstart.mjs does (the token is kept in ~/.agneta-quickstart-token), then runs one task: Agneta
// opens a session that declares the schema, the model reads the text and submits the value through a tool Agneta
// serves, Agneta validates it (telling the model what to fix, if anything), and the value comes back typed.
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { AgnetaClient, isAgnetaError } from '@agneta/client';
import { fileTokenStore, nodeEnvironment } from '@agneta/client/node';

const dev = process.argv.includes('--dev');
const file = process.argv.slice(2).find((arg) => !arg.startsWith('--'));
if (!file) {
  console.error('Usage: node examples/extract.mjs <file.txt> [--dev]');
  process.exit(2);
}
const text = await readFile(file, 'utf8');

// A plain JSON Schema `as const` types the value in TypeScript; in JavaScript it's the same object.
const notes = /** @type {const} */ ({
  type: 'object',
  properties: {
    contact: {
      type: 'object',
      properties: { name: { type: 'string' }, email: { type: ['string', 'null'] } },
      required: ['name', 'email'],
      additionalProperties: false
    },
    actions: {
      type: 'array',
      items: {
        type: 'object',
        properties: { what: { type: 'string' }, due: { type: ['string', 'null'], description: 'An ISO date, or null' } },
        required: ['what', 'due'],
        additionalProperties: false
      }
    }
  },
  required: ['contact', 'actions'],
  additionalProperties: false
});

const client = new AgnetaClient({
  name: 'Agneta Quickstart',
  build: dev ? 'dev' : 'release',
  ...(process.env.AGNETA_PORT ? { port: Number(process.env.AGNETA_PORT) } : {}),
  tokens: fileTokenStore(join(homedir(), `.agneta-quickstart-token${dev ? '-dev' : ''}`)),
  environment: nodeEnvironment()
});
client.on('pairingCode', (code) => console.log(`Agneta shows a code: check it's ${code}, then allow the app.`));

try {
  await client.connect({ guide: (question) => question.kind === 'open' });
  // One-shot: a session that declares the schema (app-only tools, no approvals), one prompt, closed.
  const answer = client.ask(`Find who wrote this, and the action items in it.\n\n${text}`, {
    schema: notes,
    task: 'Extract notes',
    // The turn, to stream the model's text while it works (or to cancel it).
    onTurn: (turn) => void (async () => { for await (const chunk of turn.textStream()) process.stdout.write(chunk); })()
  });
  const value = await answer;
  const { mechanism, attempts, turnResult } = await answer.details;
  console.log(`\n${JSON.stringify(value, null, 2)}`);
  console.log(`\nChecked by Agneta (${mechanism}), ${attempts} attempt${attempts === 1 ? '' : 's'}, ${turnResult.usage?.modelCalls ?? '?'} model calls.`);
} catch (error) {
  if (!isAgnetaError(error)) throw error;
  // resultMissing and resultInvalid say why there's no value; the rest are as in the quickstart.
  console.error(`${error.message}\n${error.advice}`);
  process.exitCode = 1;
} finally {
  client.close();
}
