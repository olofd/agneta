import { app, BrowserWindow, dialog, ipcMain, net, protocol, safeStorage, shell } from 'electron';
import { readFileSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isListening, safeStorageTokenStore } from '@agneta/client/node';
import { agnetas as known, memoryTokens } from './agneta.mjs';
import { BenchApp } from './app.mjs';
import { resultsFolder } from './bench.mjs';
import { benchHome } from './workspace.mjs';

// The window for manual experiments, with Project Chat's security model: ACP, pairing tokens, MCP bearers and the
// gateway token stay in this main process; the renderer gets the view and a fixed set of actions (preload.cjs).
// Which Agneta: the release (47321) or a development build (47331), picked next to Connect and remembered, or
// AGNETA_PORT for an isolated instance. Read synchronously: the scheme below must be registered before Electron is ready.
const agnetas = known.map((entry) => ({ ...entry }));
let bundled = null;
try { bundled = readFileSync(new URL('./port', import.meta.url), 'utf8'); } catch {}
const fixed = process.env.AGNETA_PORT ?? bundled?.trim();
if (fixed !== undefined) {
  const port = Number(fixed);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('AGNETA_PORT must be a valid TCP port.');
  const match = agnetas.find((choice) => choice.port === port);
  agnetas.splice(0, agnetas.length, match ?? { id: 'fixed', name: `Agneta on port ${port}`, port, url: null });
}
let agneta = agnetas[0];
/**
 * Set by `npm run snapshot`: render the window hidden, connect (pairing if need be), ask for the sandbox mode
 * REPLICA_BENCH_SNAPSHOT_SANDBOX, run the scenario REPLICA_BENCH_SNAPSHOT_SCENARIO, show REPLICA_BENCH_SNAPSHOT_TAB
 * (each when given), save a picture of the window to this path, and quit. It keeps no token, so it never touches the
 * window's kept access.
 */
const snapshot = process.env.REPLICA_BENCH_SNAPSHOT;

const scheme = 'replica-bench';
const entry = `${scheme}://app/`;
const assets = new Map([
  [entry, new URL('./index.html', import.meta.url)],
  [`${entry}styles.css`, new URL('./styles.css', import.meta.url)],
  [`${entry}renderer.js`, new URL('./renderer.js', import.meta.url)]
]);

protocol.registerSchemesAsPrivileged([{ scheme, privileges: { standard: true, secure: true } }]);
app.setName('Replica Bench');
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin' || snapshot) app.quit();
});
app.on('activate', () => {
  if (app.isReady() && !window) openWindow().catch((error) => console.error('Replica Bench could not open:', error));
});
app.whenReady().then(async () => {
  try {
    home = await benchHome();
  } catch (error) {
    dialog.showErrorBox('Replica Bench can\'t use its data folder', error.message);
    app.exit(1);
    return;
  }
  setUp();
  return openWindow();
}).catch((error) => {
  console.error('Replica Bench could not open:', error);
  app.exit(1);
});

/** Always Allow's token, encrypted with safeStorage (its key is in the login Keychain), one file per Agneta. */
function tokensFor(port) {
  return safeStorageTokenStore(safeStorage, join(app.getPath('userData'), `agneta-token-${port}`));
}

const choiceFile = () => join(app.getPath('userData'), 'agneta.json');

async function initialAgneta() {
  if (agnetas.length === 1) return agnetas[0];
  try {
    const { use } = JSON.parse(await readFile(choiceFile(), 'utf8'));
    const picked = agnetas.find((choice) => choice.id === use);
    if (picked) return picked;
  } catch {}
  const [release, dev] = await Promise.all(agnetas.map((choice) => isListening(choice.port)));
  return dev && !release ? agnetas[1] : agnetas[0];
}

/** Asks whether to open Agneta, and opens it when the user says so (docs/APP_PROTOCOL.md, Connecting). */
async function openAgneta() {
  if (!agneta.url || snapshot) return false;
  const { response } = await dialog.showMessageBox(window, {
    type: 'info',
    message: `${agneta.name} isn't running`,
    detail: `Replica Bench runs its agents through ${agneta.name}, on the plan or API key you allow. Open ${agneta.name} now?`,
    buttons: [`Open ${agneta.name}`, 'Not Now'],
    defaultId: 0,
    cancelId: 1
  });
  if (response !== 0) return false;
  try {
    await shell.openExternal(agneta.url);
    return true;
  } catch {
    await dialog.showMessageBox(window, { type: 'warning', message: `${agneta.name} couldn't be opened`, detail: `Is ${agneta.name} installed? Open it, then connect.` });
    return false;
  }
}

let window;
let bench;
let home;

function setUp() {
  protocol.handle(scheme, (request) => {
    const file = assets.get(request.url);
    if (request.method !== 'GET' || !file) return new Response(null, { status: 404 });
    return net.fetch(file.href);
  });

  const reportPath = (id) => bench.view.reports.find((report) => report.id === id)?.md;
  const actions = {
    state: () => bench.view,
    agnetas: () => ({ use: agneta.id, choices: agnetas.map(({ id, name }) => ({ id, name })) }),
    use: (id) => useAgneta(id),
    connect: () => bench.connect(),
    disconnect: () => bench.disconnect(),
    pairAgain: () => bench.pairAgain(),
    choose: (value) => bench.choose(value),
    configure: (value) => bench.configure(value),
    runScenario: (name) => bench.runScenario(name),
    send: (text) => bench.send(text),
    stop: () => bench.stop(),
    newRun: () => bench.newRun(),
    runMatrix: (value) => bench.runMatrix(value),
    checkModes: () => bench.checkModes(),
    loadReports: () => bench.loadReports(),
    showWorkspace: () => { if (bench.workspace) shell.showItemInFolder(bench.workspace); },
    openReport: (id) => { const path = reportPath(id); if (path) return shell.openPath(path); },
    showReport: (id) => { const path = reportPath(id); if (path) shell.showItemInFolder(path); },
    showResults: () => mkdir(resultsFolder, { recursive: true }).then(() => shell.openPath(resultsFolder))
  };
  for (const [name, action] of Object.entries(actions)) {
    ipcMain.handle(`bench:${name}`, (event, value) => {
      if (!window || window.isDestroyed() || event.sender !== window.webContents || event.senderFrame?.url !== entry ||
          event.senderFrame !== window.webContents.mainFrame) {
        throw new Error('Unexpected IPC sender.');
      }
      return action(value);
    });
  }
}

/** The bench for the Agneta in use, showing in `opened`; its view reaches the window at most ten times a second. */
function startBench(opened) {
  const current = new BenchApp(agneta.port, { home, tokens: snapshot ? memoryTokens() : tokensFor(agneta.port), openAgneta, name: agneta.name });
  let pending = false;
  current.on('change', () => {
    if (pending) return;
    pending = true;
    setTimeout(() => {
      pending = false;
      if (!opened.isDestroyed() && bench === current) opened.webContents.send('bench:state-changed', current.view);
    }, 100);
  });
  bench = current;
  return current;
}

async function useAgneta(id) {
  const next = agnetas.find((choice) => choice.id === id);
  if (!next || next === agneta || !window) return;
  agneta = next;
  await writeFile(choiceFile(), JSON.stringify({ use: id })).catch(() => {});
  bench.removeAllListeners('change');
  bench.disconnect();
  const current = startBench(window);
  window.webContents.send('bench:state-changed', current.view);
  current.connect({ quiet: true });
}

async function openWindow() {
  agneta = await initialAgneta();
  const opened = new BrowserWindow({
    title: 'Replica Bench',
    width: 1280,
    height: 820,
    minWidth: 980,
    minHeight: 620,
    show: !snapshot,
    backgroundColor: '#f7f6f2',
    webPreferences: {
      preload: fileURLToPath(new URL('./preload.cjs', import.meta.url)),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  window = opened;
  startBench(opened);

  opened.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  opened.webContents.on('will-navigate', (event) => event.preventDefault());
  opened.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  opened.once('close', () => {
    bench.removeAllListeners('change');
    bench.disconnect();
  });
  opened.once('closed', () => {
    if (window === opened) window = undefined;
  });
  await opened.loadURL(entry);
  bench.loadReports();
  await bench.connect({ quiet: !snapshot });
  if (snapshot) {
    // Long enough for the prepared run's session to open and the renderer to draw it.
    await new Promise((resolve) => setTimeout(resolve, 4000));
    if (process.env.REPLICA_BENCH_SNAPSHOT_SANDBOX) {
      await bench.choose({ sandbox: process.env.REPLICA_BENCH_SNAPSHOT_SANDBOX });
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
    if (process.env.REPLICA_BENCH_SNAPSHOT_SCENARIO) await bench.runScenario(process.env.REPLICA_BENCH_SNAPSHOT_SCENARIO);
    // REPLICA_BENCH_SNAPSHOT_TAB=sandbox (after running the modes check) or results pictures that tab instead.
    const tab = process.env.REPLICA_BENCH_SNAPSHOT_TAB;
    if (tab === 'sandbox') await bench.checkModes();
    if (['sandbox', 'results'].includes(tab)) await opened.webContents.executeJavaScript(`document.getElementById('tab-${tab}').click()`);
    await new Promise((resolve) => setTimeout(resolve, 600));
    await writeFile(snapshot, (await opened.webContents.capturePage()).toPNG());
    app.quit();
  }
}
