import assert from 'node:assert/strict';
import test from 'node:test';
import { startProjectTools } from '../project-tools.mjs';

async function post(tools, message, headers) {
  return fetch(tools.registration.url, {
    method: 'POST',
    headers: headers ?? Object.fromEntries(tools.registration.headers.map(({ name, value }) => [name, value])),
    body: JSON.stringify({ jsonrpc: '2.0', ...message })
  });
}

test('each tool server requires its own bearer and rejects browser origins', async (t) => {
  const callbacks = { readBrief() {}, stageNote() { return false; } };
  const first = await startProjectTools(callbacks);
  const second = await startProjectTools(callbacks);
  t.after(() => { first.close(); second.close(); });

  const list = { id: 1, method: 'tools/list' };
  assert.equal((await post(first, list, {})).status, 401);
  const firstBearer = first.registration.headers[0].value;
  assert.equal((await post(second, list, { Authorization: firstBearer })).status, 401);
  assert.equal((await post(first, list, { Authorization: firstBearer, Origin: 'https://example.org' })).status, 403);
  const { result } = await (await post(first, list)).json();
  assert.deepEqual(result.tools.map(({ name }) => name), ['read_project_brief', 'propose_note']);
});

test('tools return the project brief and stage a note through the app callback', async (t) => {
  let briefReads = 0;
  let draft;
  const tools = await startProjectTools({
    readBrief: () => briefReads++,
    stageNote(text) {
      if (draft) return false;
      draft = text;
      return true;
    }
  });
  t.after(() => tools.close());

  const call = async (name, args = {}) => {
    const response = await post(tools, { id: 'call', method: 'tools/call', params: { name, arguments: args } });
    return (await response.json()).result;
  };
  const brief = await call('read_project_brief');
  assert.match(brief.content[0].text, /Offline search and PDF export/);
  assert.equal(briefReads, 1);
  assert.equal((await call('propose_note', { text: 'x'.repeat(601) })).isError, true);
  assert.equal(draft, undefined);

  const result = await call('propose_note', { text: '  PDF export is ready.  ' });
  assert.match(result.content[0].text, /has not been saved/);
  assert.equal(draft, 'PDF export is ready.');
  assert.equal((await call('propose_note', { text: 'Overwritten' })).isError, true);
  assert.equal(draft, 'PDF export is ready.');
});
