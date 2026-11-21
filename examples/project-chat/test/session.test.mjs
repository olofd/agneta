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

test('streaming a reply sends just the appended text between view changes', async (t) => {
  const piece = 'Text 🌱 '.repeat(8);
  const count = 160;
  const behaviour = agnetaLike({ handlers: {
    'session/prompt': (request, peer) => {
      for (let n = 0; n < count; n++) {
        peer.notify('session/update', { sessionId: request.params.sessionId,
          update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: piece } } });
      }
      return { result: { stopReason: 'end_turn' } };
    }
  } });
  const server = await standIn(behaviour.answer);
  const chat = new ProjectChat(server.port);
  t.after(async () => { chat.disconnect(); await server.close(); });
  await chat.connect();
  await chat.send('An earlier conversation');
  let bytes = 0, deltas = 0, displayed = [];
  chat.on('change', (state, append) => {
    bytes += Buffer.byteLength(JSON.stringify(append ?? state));
    if (append) {
      const message = displayed[append.index];
      assert.equal(message.text.length, append.offset);
      message.text += append.text;
      deltas++;
    } else {
      displayed = structuredClone(state.messages);
    }
  });
  await chat.send('Continue');
  assert.equal(displayed.at(-1).text, piece.repeat(count));
  const budget = 10 * Buffer.byteLength(JSON.stringify(chat.view));
  t.diagnostic(`View updates used ${bytes} JSON bytes for a ${budget / 10}-byte final view.`);
  assert.ok(bytes < budget, `sent ${bytes} bytes for a final view of ${budget / 10} bytes`);
  assert.equal(deltas, count - 1);
});
