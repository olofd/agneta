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
  element('account').textContent = state.account;
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

function run(action) {
  action.catch(() => { status.textContent = 'The app could not complete this action.'; });
}

connectionButton.addEventListener('click', () => run(phase === 'disconnected' ? chat.connect() : chat.disconnect()));
element('new-chat').addEventListener('click', () => run(chat.newChat()));
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
