import assert from 'node:assert/strict';
import test from 'node:test';
import { agnetaLike, standIn } from '../../../clients/typescript/test/stand-in.mjs';
import { ProjectChat } from '../chat.mjs';

test('a stopped session explains why in the status and conversation', async (t) => {
  let stop;
  const behaviour = agnetaLike({ handlers: {
    'session/prompt': (request, peer) => {
      peer.notify('agneta/sessionStopped', { sessionId: request.params.sessionId, ...stop });
      return { result: { stopReason: 'cancelled' } };
    }
  } });
  const server = await standIn(behaviour.answer);
  const chat = new ProjectChat(server.port, { name: 'Agneta Dev' });
  t.after(async () => { chat.disconnect(); await server.close(); });
  await chat.connect();
  for (const [stoppedBy, reason, expected] of [
    ['user', null, /Stopped in Agneta Dev/], ['engine', null, /engine stopped/i],
    ['limit', null, /limit/i], ['reach', 'Port 41000 is no longer served.', /Port 41000 is no longer served/]
  ]) {
    stop = { stoppedBy, reason };
    await chat.send('hello');
    assert.match(chat.view.status, expected);
    assert.match(chat.view.messages.at(-1).text, expected);
    assert.equal(chat.view.phase, 'ready');
  }
});
