// Compile-time checks (`npm run typecheck`): the unions narrow, the method map types requests, and mistakes don't compile.
import {
  AgnetaClient, Connection, isAgnetaError, resultCallOf, type Access, type AccessEngine, type AgnetaPresence, type Answer,
  type Ask, type AskDetails, type ConnectProgress, type FromSchema, type GuideQuestion, type Session, type SessionUpdate,
  type StandardJSONSchemaV1, type StandardSchemaV1, type StructuredResult, type TraceRecord, type TurnEvent
} from '../src/index.js';
import { electronEnvironment, fileTokenStore, nodeEnvironment, safeStorageTokenStore } from '../src/node.js';

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
const expect = <T extends true>(): T => true as T;

async function narrowing(client: AgnetaClient, connection: Connection) {
  const session = await client.newSession({ policy: { tools: 'workspace', sandbox: 'contained', limits: { maxTurns: 10 } } });
  const turn = session.prompt('Hi');
  for await (const event of turn) {
    if (event.type === 'update') {
      const update: SessionUpdate = event.update;
      if (update.sessionUpdate === 'agent_message_chunk' && update.content.type === 'text') {
        const text: string = update.content.text;
        void text;
      }
      if (update.sessionUpdate === 'tool_call') {
        const id: string = update.toolCallId;
        void id;
      }
      if (update.sessionUpdate === 'usage_update') {
        const used: number = update.used;
        void used;
      }
    } else if (event.type === 'queued') {
      const position: number = event.position;
      void position;
    } else if (event.type === 'rateLimited') {
      const resets: string | null = event.details.resetsAt;
      void resets;
    } else {
      expect<Equal<typeof event, Extract<TurnEvent, { type: 'stopped' }>>>();
    }
  }
  const result = await turn;
  const stop: 'end_turn' | 'max_tokens' | 'max_turn_requests' | 'refusal' | 'cancelled' = result.stopReason;
  void stop;

  try {
    await session.prompt('Again');
  } catch (error) {
    if (isAgnetaError(error)) {
      switch (error.kind) {
        case 'unenforceable': { const fields: string[] = error.fields; void fields; break; }
        case 'engineDownloading': { const total: number | null | undefined = error.progress?.total; void total; break; }
        case 'rateLimited': { const at: Date | null = error.resetsAt; void at; break; }
        case 'paused': { const account: string | null = error.account; void account; break; }
        case 'notRunning': { const url: string | null = error.openURL; void url; break; }
        case 'needsSignIn': case 'needsPairing': case 'notAllowed': break;
      }
    }
  }

  // The method map types params and results; unknown methods stay reachable.
  const access: Access = await connection.request('agneta/access', {});
  const page = await connection.request('agneta/trace/read', { sessionId: 's', after: 0, types: ['event', 'acp'] });
  const record: TraceRecord | undefined = page.records[0];
  if (record?.type === 'acp') { const leg: string = record.leg; void leg; }
  const anything = await connection.request<{ x: number }>('engine/own', { a: 1 });
  const x: number = anything.x;
  void access; void x;
  // @ts-expect-error: session/new needs cwd and mcpServers
  await connection.request('session/new', {});
  // @ts-expect-error: not a sandbox level
  await client.newSession({ policy: { sandbox: 'open' } });
  // @ts-expect-error: not a tools level
  await client.pair({ tools: 'everything' });

  const engine: AccessEngine = access.engines[0]!;
  if (engine.state === 'downloading') { const received: number | undefined = engine.received; void received; }
  if (engine.state === 'ready') { const steer: boolean | undefined = engine.capabilities?.steer; void steer; }

  client.on('accessChanged', (next) => { const providers: Access['providers'] = next.providers; void providers; });
  // @ts-expect-error: not an event
  client.on('nope', () => {});
}

async function guided(client: AgnetaClient) {
  await client.connect({
    guide: (question: GuideQuestion) => {
      switch (question.kind) {
        case 'install': { const page: string = question.installURL; const brew: string | null = question.homebrew; void page; void brew; return true; }
        case 'update': { const needed: string = question.needed; const running: boolean = question.running; void needed; void running; return true; }
        case 'setup': { const kinds = question.kinds; void kinds; return true; }
        case 'open': { const title: string = question.title; void title; return true; }
      }
    },
    onProgress: (progress: ConnectProgress) => {
      if (progress.step === 'pairing') { const code: string | null = progress.code; void code; }
      if (progress.step === 'slow') { const keep: boolean = progress.keepWaiting; void keep; }
      if (progress.step === 'outdated') { const version: string | null = progress.version; void version; }
      // @ts-expect-error: only the pairing step has a code
      if (progress.step === 'connected') void progress.code;
    }
  });
  const presence: AgnetaPresence = await client.presence();
  if (presence.state === 'notRunning') { const where: 'applications' | 'elsewhere' = presence.location; void where; }
  // @ts-expect-error: not a step
  client.on('progress', (progress) => { if (progress.step === 'nope') return; });
  try { await client.connect(); } catch (error) {
    if (isAgnetaError(error)) {
      if (error.kind === 'notInstalled') { const url: string | null = error.installURL; void url; }
      if (error.kind === 'outdated') { const needed: string = error.needed; void needed; }
      if (error.kind === 'declined') { const question: 'install' | 'open' | 'update' | 'setup' = error.question; void question; }
    }
  }
}

const environments = [nodeEnvironment(), electronEnvironment({
  app: { getApplicationInfoForProtocol: async () => ({ name: 'Agneta', path: '/Applications/Agneta.app' }) },
  shell: { openExternal: async () => {}, openPath: async () => '' }
})];
void guided; void environments;

const store = fileTokenStore('/tmp/token');
const electron = safeStorageTokenStore({ isEncryptionAvailable: () => true, encryptString: (text) => Buffer.from(text), decryptString: (data) => data.toString() }, '/tmp/t');
void narrowing; void store; void electron;

// MARK: Structured results

// FromSchema: objects with required and optional properties, arrays, enum, const, primitives, type lists with null.
const contact = {
  type: 'object',
  properties: {
    name: { type: 'string' }, age: { type: 'integer' }, email: { type: ['string', 'null'] },
    tags: { type: 'array', items: { type: 'string' } }, kind: { enum: ['person', 'company'] }, v: { const: 1 },
    address: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] },
    extra: { type: 'object', additionalProperties: { type: 'boolean' } }, anything: { anyOf: [{ type: 'string' }] }
  },
  required: ['name', 'kind']
} as const;
type Contact = FromSchema<typeof contact>;
expect<Equal<Contact, {
  name: string; kind: 'person' | 'company';
  age?: number; email?: string | null; tags?: string[]; v?: 1; address?: { city: string }; extra?: { [key: string]: boolean };
  anything?: unknown;
}>>();
expect<Equal<FromSchema<{ type: 'array' }>, unknown[]>>();
expect<Equal<FromSchema<{ type: 'object' }>, { [key: string]: unknown }>>();
expect<Equal<FromSchema<{ type: string }>, unknown>>();
expect<Equal<FromSchema<{ readonly [key: string]: unknown }>, unknown>>();

/** A minimal hand-written Standard Schema with Standard JSON Schema, as Zod 4.2+ gives one. */
type Invoice = { number: string; total: number };
declare const invoiceSchema: StandardSchemaV1<{ number: string; total: string }, Invoice> & StandardJSONSchemaV1<{ number: string; total: string }, Invoice>;
const handWritten = {
  '~standard': {
    version: 1, vendor: 'mini',
    validate: (value: unknown) => ({ value: value as { id: number } }),
    jsonSchema: { input: () => ({ type: 'object' }), output: () => ({ type: 'object' }) },
    types: undefined as unknown as { input: { id: string }; output: { id: number } }
  }
} as const;

async function structured(client: AgnetaClient, session: Session) {
  await client.newSession({ results: { schemas: { contact, invoice: invoiceSchema }, every: 'contact' } });
  await client.newSession({ results: { schema: handWritten } });
  // @ts-expect-error: a declaration needs schema or schemas
  await client.newSession({ results: { every: 'x' } });

  const ask = session.ask('Who?', { schema: contact });
  expect<Equal<typeof ask, Ask<Contact>>>();
  const value = await ask;
  const name: string = value.name;
  // @ts-expect-error: optional
  const age: number = value.age;
  void name; void age;
  const details: AskDetails<Contact> = await ask.details;
  const turnText: string = details.turnResult.text;
  void turnText;
  for await (const event of ask.turn) if (event.type === 'update') { const tag: { name: string | null } | null = resultCallOf(event.update); void tag; }

  // Without `as const`: still typed, by the const type parameter.
  const inline = await session.ask('Tags?', { schema: { type: 'array', items: { type: 'string' } } });
  expect<Equal<typeof inline, string[]>>();

  // A Standard Schema: its output type.
  const fromStandard = await session.ask('Invoice?', { schema: invoiceSchema });
  expect<Equal<typeof fromStandard, Invoice>>();
  const fromHandWritten = await session.ask('Id?', { schema: handWritten });
  expect<Equal<typeof fromHandWritten, { id: number }>>();

  // A plain schema with the app's own type, by parse or given.
  const parsed = await session.ask('Date?', { schema: { type: 'string' }, parse: (raw) => new Date(String(raw)) });
  expect<Equal<typeof parsed, Date>>();
  const given = await session.ask<Invoice>('Invoice?', { schema: { type: 'object' } });
  expect<Equal<typeof given, Invoice>>();
  const byName = await session.ask('Again', { name: 'contact', attempts: 2 });
  expect<Equal<typeof byName, unknown>>();

  // One-shot: an Answer, without a turn of its own.
  const once = client.ask('Who?', { schema: contact, engine: 'goose', onTurn: (turn) => turn.cancel() });
  expect<Equal<typeof once, Answer<Contact>>>();
  // @ts-expect-error: the one-shot's turn is given to onTurn
  void once.turn;
  // @ts-expect-error: client.ask needs a schema
  client.ask('Who?', { name: 'result' });

  // The low level: the ask and the report, discriminated by status.
  const turn = await session.prompt('Who?', { result: { name: 'contact', attempts: 3 } });
  await session.prompt('Chat', { result: false });
  // @ts-expect-error: Agneta takes schemas only when a session opens
  await session.prompt('Who?', { result: { schema: contact } });
  const report: StructuredResult | null = turn.structured;
  if (report?.status === 'valid') { const v: unknown = report.value; void v; }
  if (report?.status === 'missing') { const reason: string = report.reason; void reason; }
  if (report?.status === 'invalid') { const path: string | undefined = report.issues[0]?.path; void path; }
  // @ts-expect-error: only missing has a reason
  if (report?.status === 'valid') void report.reason;
  const resultCalls = turn.resultCalls.map((call) => call.result?.name);
  void resultCalls;
  const results = session.results;
  if (results) { const every: string | null = results.every; void every; }

  try { await ask; } catch (error) {
    if (isAgnetaError(error)) {
      switch (error.kind) {
        case 'resultMissing': { const reason: string = error.reason; const usage = error.turnResult.usage; void reason; void usage; break; }
        case 'resultInvalid': { const source: 'agneta' | 'client' = error.source; const path: string | undefined = error.issues[0]?.path; void source; void path; break; }
        case 'unsupportedByAgneta': { const extension: string = error.extension; void extension; break; }
        case 'internal': { const accepted: StructuredResult | null = error.structured; void accepted; break; }
      }
    }
  }
}
void structured;
