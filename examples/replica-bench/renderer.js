// The window: draws the view main.mjs sends and calls its fixed actions. Everything is built with textContent, so
// nothing an agent writes is ever read as markup.
const bench = window.replicaBench;
const element = (id) => document.getElementById(id);
const thread = element('thread');
const messages = element('messages');
const prompt = element('prompt');
const status = element('status');
let state = null;
let phase = 'disconnected';
let tab = 'run';
let selectedReport = null;
let agnetas = { use: '', choices: [] };

const outcomes = {
  pass: ['Pass', 'good'],
  'expected-fail': ['Expected fail', 'muted'],
  unexpected: ['Unexpected', 'warn'],
  'not exercised': ['Not exercised', 'muted'],
  refused: ['Refused', 'warn'],
  error: ['Error', 'warn']
};

function pill(node, outcome, extra = '') {
  const [label, tone] = outcomes[outcome] ?? [outcome ?? '', 'muted'];
  node.hidden = !outcome;
  node.className = `pill ${tone}`;
  node.textContent = extra ? `${label} · ${extra}` : label;
}

function expectedText(expected) {
  if (!expected) return '';
  if (expected.outcome === 'pass') return 'Expected to pass';
  return expected.boundary ? `Must fail: ${expected.why}` : expected.why ? `Expected to fail: ${expected.why}` : 'Must fail';
}

/** Sets a select's options ([value, label] pairs) and choice, touching the DOM only when they changed. */
function fill(select, options, value) {
  const key = JSON.stringify(options);
  if (select.dataset.options !== key) {
    select.replaceChildren(...options.map(([id, label]) => new Option(label, id)));
    select.dataset.options = key;
  }
  if (value !== undefined && select.value !== value) select.value = value;
}

function list(node, items, empty) {
  node.replaceChildren(...(items.length ? items : empty ? [Object.assign(document.createElement('li'), { className: 'hint', textContent: empty })] : []));
}

function item(text, className = '') {
  const entry = document.createElement('li');
  entry.textContent = text;
  if (className) entry.className = className;
  return entry;
}

const time = (at) => new Date(at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });

function render(next) {
  state = next;
  phase = state.phase;
  const connected = !['disconnected', 'connecting', 'guide', 'pairing'].includes(phase);
  showGuide(state.guide);
  const ready = phase === 'ready';
  const running = phase === 'running';

  // The header: provider, engine and the sandbox mode the next run asks for, beside the grant's ceiling.
  const provider = state.providers.find((entry) => entry.id === state.account);
  fill(element('provider'), state.providers.map((entry) => [entry.id, entry.paused ? `${entry.label} (paused)` : entry.label]), state.account);
  fill(element('engine'), (provider?.engines ?? []).map((entry) => [entry.id, [entry.name, entry.state === 'ready' ? null : entry.state, entry.uncontained ? 'uncontained' : null].filter(Boolean).join(' · ')]), state.engine);
  element('provider-picker').hidden = !connected || !state.providers.length;
  element('engine-picker').hidden = !connected || !provider;
  element('sandbox-picker').hidden = !connected;
  for (const button of element('sandbox-picker').querySelectorAll('button')) {
    button.setAttribute('aria-checked', String(button.dataset.sandbox === state.sandbox));
    button.disabled = !ready;
  }
  element('grant-pill').hidden = !connected;
  element('grant-pill').textContent = `Grant: ${state.grant ?? 'not reported'}`;
  element('grant-pill').className = `pill ${state.grant === 'developer' ? 'warn' : 'good'}`;
  element('provider').disabled = element('engine').disabled = !ready;
  const using = agnetas.choices.find((entry) => entry.id === agnetas.use);
  fill(element('agneta'), agnetas.choices.map((entry) => [entry.id, entry.name]), agnetas.use);
  element('agneta-picker').hidden = phase !== 'disconnected' || agnetas.choices.length < 2;
  const connection = element('connection-button');
  connection.textContent = phase === 'disconnected' ? `Connect to ${using?.name ?? 'Agneta'}` : connected ? 'Disconnect' : 'Cancel';
  connection.classList.toggle('quiet', phase !== 'disconnected');

  // A choice Agneta will refuse is said before running it, with why: the run then shows the refusal itself.
  const refusal = connected && state.prediction?.outcome === 'refused';
  element('notice').hidden = !refusal;
  element('notice-text').textContent = refusal ? `Asking for ${state.sandbox} here will be refused: ${state.prediction.why}. Run it to see Agneta's own reason, or pick another mode or engine.` : '';

  element('pairing').hidden = !state.code;
  element('pairing-code').textContent = state.code;
  if (status.textContent !== state.status) status.textContent = state.status;

  renderScenarios(ready);
  renderRun(state.run, { ready, running, connected });
  renderSandbox(ready, connected);
  renderResults(ready);
}

/** The Sandbox tab: the grant and what it means, the ladder, each engine's levels, and the modes check. */
function renderSandbox(ready, connected) {
  const { meaning, whoDecides, uncontained } = state.explain;
  element('grant-mode').textContent = !connected ? 'Not connected' : state.grant === 'developer' ? 'Developer access' : state.grant === 'contained' ? 'Contained' : 'Not reported';
  element('grant-meaning').textContent = connected && state.grant ? meaning[state.grant] : 'Connect to see the mode the user granted this app.';
  element('grant-who').textContent = whoDecides;
  element('pair-again').disabled = !ready;
  for (const mode of ['contained', 'developer']) {
    element(`meaning-${mode}`).textContent = meaning[mode];
    const above = state.grant === 'contained' && mode === 'developer';
    const node = element(`ladder-${mode}-state`);
    node.hidden = !connected || !state.grant;
    node.textContent = mode === state.grant ? 'This app\'s grant' : above ? 'Above the grant: refused' : 'Within the grant';
    node.className = `pill ${above ? 'warn' : mode === state.grant ? 'good' : ''}`;
    element(`ladder-${mode}`).classList.toggle('current', mode === state.grant);
  }
  const yes = (engine, mode) => !engine.levels ? 'not reported' : engine.levels.includes(mode) ? 'yes' : 'no';
  const rows = state.providers.flatMap((provider) => provider.engines.map((engine) => [
    provider.label, engine.uncontained ? `${engine.name} (uncontained)` : engine.name, engine.state, yes(engine, 'contained'), yes(engine, 'developer')
  ]));
  element('engine-levels').replaceChildren(...rows.map((cells) => tableRow(cells)));
  const loose = state.providers.flatMap((provider) => provider.engines.filter((engine) => engine.uncontained).map((engine) => `${engine.name} on ${provider.label}`));
  element('uncontained-note').hidden = !loose.length;
  element('uncontained-note').textContent = loose.length ? `Uncontained: ${loose.join(', ')}. ${uncontained}` : '';

  const modes = state.modes;
  element('modes-run').disabled = !ready;
  element('modes-run').textContent = modes.running ? 'Checking…' : 'Check Modes';
  element('modes-table').hidden = !modes.rows.length;
  element('modes-rows').replaceChildren(...modes.rows.map(modeRow));
  const log = element('modes-log');
  // The log while it runs; the table says it all once done.
  log.hidden = !modes.log.length || (!modes.running && modes.rows.length > 0);
  log.textContent = modes.log.join('\n');
}

/** A modes-check row: provider, engine, asked, got (or refused with Agneta's reason), as declared. */
function modeRow(row) {
  const got = row.error ? `error: ${row.error}` : row.refused ? `refused: ${row.refused.reason}` : row.got ?? 'not reported';
  return tableRow([row.provider, row.uncontained ? `${row.engine} (uncontained)` : row.engine, row.sandbox, got, row.verdict === 'as declared' ? 'yes' : row.verdict], row.verdict === 'as declared' ? '' : 'no');
}

function tableRow(cells, className = '') {
  const tr = document.createElement('tr');
  if (className) tr.className = className;
  tr.append(...cells.map((value) => {
    const td = document.createElement('td');
    if (value instanceof Node) td.append(value); else td.textContent = String(value);
    return td;
  }));
  return tr;
}

function renderScenarios(ready) {
  const ol = element('scenario-list');
  if (ol.children.length !== state.scenarios.length) {
    ol.replaceChildren(...state.scenarios.map((entry) => {
      const row = document.createElement('li');
      row.dataset.name = entry.name;
      const text = document.createElement('div');
      text.className = 'scenario-text';
      const title = document.createElement('strong');
      const about = document.createElement('p');
      const meta = document.createElement('span');
      meta.className = 'scenario-meta';
      text.append(title, about, meta);
      const run = document.createElement('button');
      run.className = 'quiet small';
      run.textContent = 'Run';
      run.addEventListener('click', () => act(bench.runScenario(entry.name)));
      const last = document.createElement('span');
      last.className = 'pill';
      const side = document.createElement('div');
      side.className = 'scenario-side';
      side.append(run, last);
      row.append(text, side);
      return row;
    }));
  }
  state.scenarios.forEach((entry, index) => {
    const row = ol.children[index];
    const [title, about, meta] = row.querySelector('.scenario-text').children;
    title.textContent = entry.title;
    about.textContent = entry.about;
    meta.textContent = `${expectedText(entry.expected)} · up to ${entry.minutes} min`;
    meta.title = entry.expected?.why ?? '';
    const [run, last] = row.querySelector('.scenario-side').children;
    run.disabled = !ready;
    pill(last, entry.last);
    row.classList.toggle('current', state.run?.scenario === entry.name);
  });
}

function renderRun(run, { ready, running, connected }) {
  element('run-title').textContent = run ? run.title : 'No run yet';
  // Asked and got: what the run's policy asked for, and what Agneta says the task got, or its refusal and reason.
  const asked = run?.sandbox ?? state.sandbox;
  element('run-sandbox').textContent = !connected ? 'Not connected.'
    : run?.refused ? `Asked ${asked}: refused by Agneta.`
    : run?.got ? `Asked ${asked}, got ${run.got}.`
    : `Will ask for ${asked}.`;
  element('run-sandbox').className = run?.refused ? 'no' : '';
  element('run-sandbox-why').textContent = run?.refused ? `Agneta's reason: ${run.refused.reason}`
    : run?.got ? state.explain.meaning[run.got] ?? ''
    : state.prediction?.outcome === 'refused' ? `Expected refusal: ${state.prediction.why}.` : connected ? state.explain.meaning[asked] ?? '' : '';
  pill(element('run-outcome'), run?.outcome, run?.outcome === 'expected-fail' && run.expected?.why && !run.expected?.boundary ? 'a known gap' : '');

  const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 56;
  const transcript = run?.transcript ?? [];
  element('empty').hidden = transcript.length > 0;
  while (messages.children.length > transcript.length) messages.lastChild.remove();
  transcript.forEach((entry, index) => {
    let row = messages.children[index];
    if (!row) {
      row = document.createElement('article');
      row.append(document.createElement('strong'), document.createElement('p'));
      messages.append(row);
    }
    const label = entry.role === 'tool' ? (entry.kind ?? 'tool') : { user: 'You', assistant: 'Agent', refusal: 'Agneta' }[entry.role];
    row.className = entry.role === 'tool' ? `tool ${entry.status ?? 'pending'}` : entry.role;
    if (row.firstChild.textContent !== label) row.firstChild.textContent = label;
    const text = entry.role === 'tool' ? entry.title : entry.text;
    if (row.lastChild.textContent !== text) row.lastChild.textContent = text;
  });
  if (nearBottom) thread.scrollTop = thread.scrollHeight;

  fill(element('model'), state.models.map((entry) => [entry.value, entry.name]), state.model);
  fill(element('effort'), state.efforts.map((entry) => [entry.value, entry.name]), state.effort);
  element('model-picker').hidden = !connected || state.models.length < 2;
  element('effort-picker').hidden = !connected || state.efforts.length < 2;
  element('model').disabled = element('effort').disabled = !ready;
  element('new-run').hidden = !connected;
  element('new-run').disabled = !ready || !run || transcript.length === 0;
  element('send').disabled = !ready;
  element('send').hidden = running;
  element('stop').hidden = !running;
  const usage = run?.usage;
  element('usage').textContent = [
    usage?.time && usage.time !== '0:00' ? usage.time : null,
    Number.isInteger(usage?.modelCalls) ? `${usage.modelCalls} model ${usage.modelCalls === 1 ? 'call' : 'calls'}` : null,
    Number.isFinite(usage?.cost) ? `$${usage.cost.toFixed(2)}${usage.costKind === 'plan-equivalent' ? ' plan-equivalent' : ''}` : null
  ].filter(Boolean).join(' · ');

  // The evidence: what the app itself saw.
  element('workspace').textContent = run?.workspace ?? 'None yet';
  element('show-workspace').disabled = !run?.workspace;
  element('expected').textContent = run?.refused ? 'Not judged: the session never opened.' : run?.expected ? `${expectedText(run.expected)}${run.expected.why ? `: ${run.expected.why}` : ''}.` : run?.scenario ? 'Judged when the turn ends.' : '';
  list(element('checks'), (run?.checks ?? []).map(({ name, ok, detail }) => item(`${name}${detail ? ` (${detail})` : ''}`, ok === null ? 'na' : ok ? 'yes' : 'no')), run?.scenario ? '' : 'Free runs have no checks.');
  list(element('scores'), (run?.scores ?? []).map(({ ok, db, message, at }) => item(`${time(at)} · ${ok ? `${typeof db === 'number' ? db.toFixed(1) : db} dB` : message}`, ok ? '' : 'no')), 'No candidate scored.');
  element('gateway-count').textContent = run?.gateway.count ?? 0;
  list(element('gateway'), (run?.gateway.recent ?? []).map(({ op, ok, samples, at }) => item(`${time(at)} · ${op}${samples ? ` · ${samples} samples` : ''}${ok ? '' : ' · refused'}`, ok ? '' : 'no')), 'No probe has called the gateway.');
  element('mcp-count').textContent = run?.mcp.length ?? 0;
  list(element('mcp'), (run?.mcp ?? []).slice(-8).reverse().map(({ tool, ok, summary, at }) => item(`${time(at)} · ${tool}${summary ? ` · ${summary}` : ''}`, ok ? '' : 'no')), 'No app tool called.');
  element('command-count').textContent = run?.commands ?? 0;
  list(element('refusals'), (run?.refusals ?? []).map(({ what, why }) => item(`Refused ${what}: ${why}`, 'no')), 'Nothing refused.');
}

function renderResults(ready) {
  for (const name of ['run', 'sandbox', 'results']) {
    element(`${name}-view`).hidden = tab !== name;
    element(`tab-${name}`).setAttribute('aria-selected', String(tab === name));
  }
  const matrix = state.matrix;
  fill(element('matrix-scenario'), [['all', 'All scenarios'], ...state.scenarios.map(({ name, title }) => [name, title])]);
  element('matrix-run').disabled = !ready;
  element('matrix-run').hidden = matrix.running;
  element('matrix-stop').hidden = !matrix.running;
  const log = element('matrix-log');
  const text = matrix.log.join('\n');
  if (log.textContent !== text) {
    log.textContent = text;
    log.scrollTop = log.scrollHeight;
  }
  log.hidden = !matrix.log.length;

  element('no-reports').hidden = state.reports.length > 0;
  const reports = element('report-list');
  if (!selectedReport || !state.reports.some(({ id }) => id === selectedReport)) selectedReport = state.reports[0]?.id ?? null;
  const key = JSON.stringify(state.reports.map(({ id }) => id));
  if (reports.dataset.key !== key) {
    reports.replaceChildren(...state.reports.map(({ id, generated }) => {
      const button = document.createElement('button');
      button.className = 'report-item';
      button.dataset.id = id;
      button.textContent = generated ? new Date(generated).toLocaleString() : id;
      button.addEventListener('click', () => { selectedReport = id; render(state); });
      const entry = document.createElement('li');
      entry.append(button);
      return entry;
    }));
    reports.dataset.key = key;
  }
  for (const button of reports.querySelectorAll('button')) button.classList.toggle('selected', button.dataset.id === selectedReport);
  const report = state.reports.find(({ id }) => id === selectedReport);
  element('report').hidden = !report;
  if (report) {
    element('report-summary').textContent = report.summary;
    element('report-rows').parentElement.hidden = !report.rows.length;
    element('report-rows').replaceChildren(...report.rows.map((row) => {
      const outcome = document.createElement('span');
      pill(outcome, row.outcome, row.outcome === 'expected-fail' && row.why && !row.boundary ? 'a known gap' : row.outcome === 'unexpected' ? (row.achieved ? 'succeeded' : 'failed') : '');
      const got = document.createElement('span');
      got.textContent = row.got;
      if (row.reason) got.title = `Agneta's reason: ${row.reason}`;
      return tableRow([row.scenario, row.engine, row.sandbox ?? '—', got, outcome, row.time, row.modelCalls ?? '—', Number.isFinite(row.cost) ? `$${row.cost.toFixed(2)}` : '—']);
    }));
    element('report-modes').hidden = !report.modes.length;
    element('report-modes-rows').replaceChildren(...report.modes.map((row) => modeRow({ ...row, refused: row.got === 'refused' ? { reason: row.reason } : null, error: row.got === 'error' ? row.reason : null })));
  }
}

function act(action) {
  action.catch(() => { status.textContent = 'Replica Bench could not complete this action.'; });
}

element('tab-run').addEventListener('click', () => { tab = 'run'; render(state); });
element('tab-sandbox').addEventListener('click', () => { tab = 'sandbox'; render(state); });
element('modes-run').addEventListener('click', () => act(bench.checkModes()));
element('tab-results').addEventListener('click', () => { tab = 'results'; act(bench.loadReports()); render(state); });
/**
 * Getting Agneta: the panel shows the step, the question when there is one (its own buttons), Homebrew's command with
 * Copy, Open the page again while the user installs, and Keep Waiting when Agneta is slow to open.
 */
function showGuide(guide) {
  element('guide').hidden = !guide;
  if (!guide) return;
  element('guide-title').textContent = guide.title;
  element('guide-detail').textContent = guide.detail;
  element('guide-homebrew').hidden = !guide.homebrew;
  element('guide-homebrew-command').textContent = guide.homebrew ?? '';
  const question = guide.question;
  element('guide-confirm').hidden = !question;
  element('guide-confirm').textContent = question?.confirm ?? '';
  element('guide-cancel').textContent = question?.cancel ?? 'Cancel';
  element('guide-reopen').hidden = !['installing', 'onDiskImage'].includes(guide.step);
  element('guide-wait').hidden = !guide.keepWaiting;
}

element('guide-confirm').addEventListener('click', () => act(bench.answer('yes')));
// Cancel answers no to a question, or ends the wait for Agneta.
element('guide-cancel').addEventListener('click', () => act(phase === 'guide' && !element('guide-confirm').hidden ? bench.answer('no') : bench.disconnect()));
element('guide-wait').addEventListener('click', () => act(bench.answer('wait')));
element('guide-reopen').addEventListener('click', () => act(bench.openInstallPage()));
element('guide-copy').addEventListener('click', () => act(bench.copyHomebrew().then(() => { element('guide-copy').textContent = 'Copied'; })));
element('connection-button').addEventListener('click', () => act(phase === 'disconnected' ? bench.connect() : bench.disconnect()));
element('agneta').addEventListener('change', (event) => act(bench.use(event.target.value).then(loadAgnetas)));
element('provider').addEventListener('change', (event) => act(bench.choose({ account: event.target.value })));
element('engine').addEventListener('change', (event) => act(bench.choose({ account: element('provider').value, engine: event.target.value })));
for (const button of element('sandbox-picker').querySelectorAll('button')) {
  button.addEventListener('click', () => act(bench.choose({ sandbox: button.dataset.sandbox })));
}
element('pair-again').addEventListener('click', () => act(bench.pairAgain()));
element('model').addEventListener('change', (event) => act(bench.configure({ model: event.target.value })));
element('effort').addEventListener('change', (event) => act(bench.configure({ effort: event.target.value })));
element('new-run').addEventListener('click', () => act(bench.newRun()));
element('stop').addEventListener('click', () => act(bench.stop()));
element('show-workspace').addEventListener('click', () => act(bench.showWorkspace()));
element('matrix-run').addEventListener('click', () => act(bench.runMatrix({
  scenario: element('matrix-scenario').value, engines: element('matrix-engines').value, sandbox: element('matrix-sandbox').value
})));
element('matrix-stop').addEventListener('click', () => act(bench.stop()));
element('show-results').addEventListener('click', () => act(bench.showResults()));
element('open-report').addEventListener('click', () => { if (selectedReport) act(bench.openReport(selectedReport)); });
element('show-report').addEventListener('click', () => { if (selectedReport) act(bench.showReport(selectedReport)); });
element('form').addEventListener('submit', (event) => {
  event.preventDefault();
  const text = prompt.value.trim();
  if (phase !== 'ready' || !text) return;
  prompt.value = '';
  act(bench.send(text));
});
// Return sends, Shift-Return makes a new line.
prompt.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    element('form').requestSubmit();
  }
});

async function loadAgnetas() {
  agnetas = await bench.agnetas();
  render(await bench.state());
}

bench.onChange(render);
act(loadAgnetas());
