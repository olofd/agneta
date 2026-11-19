// Compile-time checks (`npm run typecheck`): the unions narrow, the method map types requests, and mistakes don't compile.
import {
  AgnetaClient, Connection, isAgnetaError, type Access, type AccessEngine, type SessionUpdate, type TraceRecord, type TurnEvent
} from '../src/index.js';
import { fileTokenStore, safeStorageTokenStore } from '../src/node.js';

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

const store = fileTokenStore('/tmp/token');
const electron = safeStorageTokenStore({ isEncryptionAvailable: () => true, encryptString: (text) => Buffer.from(text), decryptString: (data) => data.toString() }, '/tmp/t');
void narrowing; void store; void electron;
