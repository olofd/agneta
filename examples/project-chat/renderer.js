const chat = window.projectChat;
const element = (id) => document.getElementById(id);
const thread = element('thread');
const messages = element('messages');
const connectionButton = element('connection-button');
const prompt = element('prompt');
const status = element('status');
let phase = 'disconnected';
let briefLoaded = false;

function render(state) {
  if (!briefLoaded) {
    for (const fact of state.project.facts) {
      const item = document.createElement('li');
      item.textContent = fact;
      element('brief').append(item);
    }
    briefLoaded = true;
  }
  phase = state.phase;
  const connected = !['disconnected', 'connecting', 'pairing'].includes(phase);
  const canSend = phase === 'ready';
  // The provider and engine of the next chat: only pairs Agneta says this app may use.
  const provider = state.providers.find((entry) => entry.id === state.account);
  fill(element('provider'), state.providers.map((entry) => [entry.id, entry.paused ? `${entry.label} (paused)` : entry.label]), state.account);
  fill(element('engine'), (provider?.engines ?? []).map((entry) => [entry.id, entry.name]), state.engine);
  element('provider-picker').hidden = !connected || state.providers.length === 0;
  element('engine-picker').hidden = !connected || !provider;
  element('provider').disabled = element('engine').disabled = !canSend;
  // The engine's own models and reasoning efforts, once the chat's session is open; changeable between turns.
  fill(element('model'), state.models.map((entry) => [entry.value, entry.name]), state.model);
  fill(element('effort'), state.efforts.map((entry) => [entry.value, entry.name]), state.effort);
  element('model-picker').hidden = !connected || state.models.length === 0;
  element('effort-picker').hidden = !connected || state.efforts.length === 0;
  element('model').disabled = element('effort').disabled = !canSend;
  if (status.textContent !== state.status) status.textContent = state.status;
  element('pairing').hidden = !state.code;
  element('pairing-code').textContent = state.code;
  connectionButton.textContent = phase === 'disconnected' ? 'Connect to Agneta'
    : connected ? 'Disconnect' : 'Cancel connection';
  connectionButton.classList.toggle('quiet', phase !== 'disconnected');
  element('new-chat').hidden = !connected;
  element('new-chat').disabled = !canSend || state.messages.length === 0;
  element('send').disabled = !canSend;
  element('send').hidden = ['running', 'stopping'].includes(phase);
  element('stop').hidden = !element('send').hidden;
  element('stop').disabled = phase !== 'running';

  const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 56;
  element('empty').hidden = state.messages.length > 0;
  while (messages.children.length > state.messages.length) messages.lastChild.remove();
  state.messages.forEach((message, index) => {
    let row = messages.children[index];
    if (!row) {
      row = document.createElement('article');
      row.append(document.createElement('strong'), document.createElement('p'));
      messages.append(row);
    }
    row.className = message.role;
    const label = { user: 'You', assistant: 'Agent', tool: 'Project tool', notice: 'Session' }[message.role];
    if (row.firstChild.textContent !== label) row.firstChild.textContent = label;
    if (row.lastChild.textContent !== message.text) row.lastChild.textContent = message.text;
  });
  if (nearBottom) thread.scrollTop = thread.scrollHeight;

  element('proposal').hidden = state.draft === null;
  element('draft').textContent = state.draft ?? '';
  element('no-notes').hidden = state.notes.length > 0;
  const notes = state.notes.map((note) => {
    const item = document.createElement('li');
    item.textContent = note;
    return item;
  });
  element('notes').replaceChildren(...notes);

  const calls = state.usage?.modelCalls;
  const tokens = state.usage?.outputTokens;
  element('usage').textContent = [
    Number.isInteger(calls) && calls > 0 ? `${calls} model ${calls === 1 ? 'call' : 'calls'}` : null,
    Number.isInteger(tokens) && tokens > 0 ? `${tokens} output tokens` : null
  ].filter(Boolean).join(' · ');
}

/** Sets a select's options ([value, label] pairs) and choice, touching the DOM only when they changed. */
function fill(select, options, value) {
  const key = JSON.stringify(options);
  if (select.dataset.options !== key) {
    select.replaceChildren(...options.map(([id, label]) => new Option(label, id)));
    select.dataset.options = key;
  }
  if (select.value !== value) select.value = value;
}

function run(action) {
  action.catch(() => { status.textContent = 'The app could not complete this action.'; });
}

connectionButton.addEventListener('click', () => run(phase === 'disconnected' ? chat.connect() : chat.disconnect()));
element('new-chat').addEventListener('click', () => run(chat.newChat()));
element('provider').addEventListener('change', (event) => run(chat.choose({ account: event.target.value })));
element('engine').addEventListener('change', (event) => run(chat.choose({ account: element('provider').value, engine: event.target.value })));
element('model').addEventListener('change', (event) => run(chat.configure({ model: event.target.value })));
element('effort').addEventListener('change', (event) => run(chat.configure({ effort: event.target.value })));
element('stop').addEventListener('click', () => run(chat.stop()));
element('save').addEventListener('click', () => run(chat.save()));
element('dismiss').addEventListener('click', () => run(chat.dismiss()));
document.querySelectorAll('[data-prompt]').forEach((button) => {
  button.addEventListener('click', () => {
    prompt.value = button.dataset.prompt;
    prompt.focus();
  });
});
element('form').addEventListener('submit', (event) => {
  event.preventDefault();
  const text = prompt.value.trim();
  if (phase !== 'ready' || !text) return;
  prompt.value = '';
  run(chat.send(text));
});
chat.onChange(render);
run(chat.state().then(render));
