import { app, BrowserWindow, clipboard, ipcMain, net, protocol, safeStorage, shell } from 'electron';
import { readFileSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { electronEnvironment, isListening, safeStorageTokenStore } from '@agneta/client/node';
import { ProjectChat } from './chat.mjs';

// Which Agneta to use: the release (port 47321, opened by agneta://) or a development build (47331, agneta-dev://),
// as the user picks next to Connect, remembered. AGNETA_PORT, or the port a bundle was made for (scripts/bundle.mjs),
// fixes it instead: an isolated instance on another port has no URL to open it by.
// Read synchronously: the scheme below must be registered before Electron is ready.
const agnetas = [
  { id: 'release', name: 'Agneta', port: 47321 },
  { id: 'dev', name: 'Agneta Dev', port: 47331 }
];
let bundled = null;
try { bundled = readFileSync(new URL('./port', import.meta.url), 'utf8'); } catch {}
const fixed = process.env.AGNETA_PORT ?? bundled?.trim();
if (fixed !== undefined) {
  const port = Number(fixed);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('AGNETA_PORT must be a valid TCP port.');
  const known = agnetas.find((choice) => choice.port === port);
  agnetas.splice(0, agnetas.length, known ?? { id: 'fixed', name: `Agneta on port ${port}`, port });
}
/** The Agneta in use now. */
let agneta = agnetas[0];

const scheme = 'project-chat';
const entry = `${scheme}://app/`;
const assets = new Map([
  [entry, new URL('./index.html', import.meta.url)],
  [`${entry}styles.css`, new URL('./styles.css', import.meta.url)],
  [`${entry}renderer.js`, new URL('./renderer.js', import.meta.url)]
]);

protocol.registerSchemesAsPrivileged([{ scheme, privileges: { standard: true, secure: true } }]);
app.setName('Project Chat');
// macOS: closing the window leaves the app running in the Dock, and clicking it opens the window again.
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
app.on('activate', () => {
  if (app.isReady() && !window) openWindow().catch((error) => console.error('Project Chat could not open:', error));
});

// Electron finishes loading this module before it emits ready.
app.whenReady().then(() => {
  setUp();
  return openWindow();
}).catch((error) => {
  console.error('Project Chat could not open:', error);
  app.exit(1);
});

/**
 * Where the token from Always Allow is kept: encrypted with Electron's safeStorage, whose key is in the login Keychain,
 * one file per Agneta (port), so each keeps its own access. Nothing is kept where encryption isn't available.
 */
function tokensFor(port) {
  return safeStorageTokenStore(safeStorage, join(app.getPath('userData'), `agneta-token-${port}`));
}

/** The user's pick, kept between launches. */
const choiceFile = () => join(app.getPath('userData'), 'agneta.json');

/** The Agneta to start with: the one picked last, else the one running (the release when both or neither are). */
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

/**
 * How the client finds and opens Agneta on this Mac: LaunchServices through Electron, and Electron's shell to open
 * (docs/APP_PROTOCOL.md, Getting Agneta). It opens nothing by itself: the window's panel asks the user first.
 */
const environment = electronEnvironment({ app, shell });

/** The open window, if any: IPC answers only its main frame. */
let window;
/** The chat of the open window; a new window starts a new one. */
let chat;

/** Once per launch: the app's own scheme and the renderer's actions. */
function setUp() {
  protocol.handle(scheme, (request) => {
    const file = assets.get(request.url);
    if (request.method !== 'GET' || !file) return new Response(null, { status: 404 });
    return net.fetch(file.href);
  });

  // The renderer gets a fixed set of actions. The WebSocket, pairing token and
  // MCP credentials stay in the main process.
  const actions = {
    state: () => chat.view,
    agnetas: () => ({ use: agneta.id, choices: agnetas.map(({ id, name }) => ({ id, name })) }),
    use: (id) => useAgneta(id),
    connect: () => chat.connect(),
    answer: (choice) => chat.answer(choice),
    openInstallPage: () => chat.openInstallPage(),
    copyHomebrew: () => { if (chat.homebrew) clipboard.writeText(chat.homebrew); },
    send: (text) => chat.send(text),
    stop: () => chat.stop(),
    newChat: () => chat.newChat(),
    choose: (value) => chat.choose(value),
    configure: (value) => chat.configure(value),
    disconnect: () => chat.disconnect(),
    save: () => chat.review(true),
    dismiss: () => chat.review(false)
  };
  for (const [name, action] of Object.entries(actions)) {
    ipcMain.handle(`chat:${name}`, (event, value) => {
      if (!window || window.isDestroyed() || event.sender !== window.webContents || event.senderFrame?.url !== entry ||
          event.senderFrame !== window.webContents.mainFrame) {
        throw new Error('Unexpected IPC sender.');
      }
      return action(value);
    });
  }
}

/** A chat with the Agneta in use, showing in `opened`. */
function startChat(opened) {
  const current = new ProjectChat(agneta.port, { tokens: tokensFor(agneta.port), environment, name: agneta.name });
  current.on('change', (state) => {
    if (!opened.isDestroyed()) opened.webContents.send('chat:state-changed', state);
  });
  chat = current;
  return current;
}

/** Switches to another Agneta: the chat with the current one ends, and one with the new one connects as at launch. */
async function useAgneta(id) {
  const next = agnetas.find((choice) => choice.id === id);
  if (!next || next === agneta || !window) return;
  agneta = next;
  await writeFile(choiceFile(), JSON.stringify({ use: id })).catch(() => {});
  chat.removeAllListeners('change');
  chat.disconnect();
  const current = startChat(window);
  window.webContents.send('chat:state-changed', current.view);
  current.connect({ quiet: true });
}

async function openWindow() {
  agneta = await initialAgneta();
  const opened = new BrowserWindow({
    title: 'Project Chat',
    width: 980,
    height: 710,
    minWidth: 740,
    minHeight: 560,
    backgroundColor: '#f7f6f2',
    webPreferences: {
      preload: fileURLToPath(new URL('./preload.cjs', import.meta.url)),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  window = opened;
  startChat(opened);

  opened.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  opened.webContents.on('will-navigate', (event) => event.preventDefault());
  opened.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  // Closing the window ends its chat (and an Allow Once grant with it).
  opened.once('close', () => {
    chat.removeAllListeners('change');
    chat.disconnect();
  });
  opened.once('closed', () => {
    if (window === opened) window = undefined;
  });
  await opened.loadURL(entry);
  // With access kept from an earlier Always Allow, it connects by itself; otherwise Connect asks Agneta.
  chat.connect({ quiet: true });
}
