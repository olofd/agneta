import { app, BrowserWindow, dialog, ipcMain, net, protocol, safeStorage, shell } from 'electron';
import { readFileSync } from 'node:fs';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ProjectChat } from './chat.mjs';

// AGNETA_PORT, else the port a bundle was made for (scripts/bundle.mjs), else a development Agneta's.
// Read synchronously: the scheme below must be registered before Electron is ready.
let bundled = null;
try { bundled = readFileSync(new URL('./port', import.meta.url), 'utf8'); } catch {}
const port = Number(process.env.AGNETA_PORT ?? bundled?.trim() ?? 47331);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('AGNETA_PORT must be a valid TCP port.');
}

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
 * one file per Agneta (port). Nothing is kept where encryption isn't available.
 */
const tokens = {
  file: () => join(app.getPath('userData'), `agneta-token-${port}`),
  async load() {
    try { return safeStorage.decryptString(await readFile(tokens.file())); } catch { return null; }
  },
  async save(token) {
    if (!safeStorage.isEncryptionAvailable()) return;
    await mkdir(dirname(tokens.file()), { recursive: true });
    await writeFile(tokens.file(), safeStorage.encryptString(token), { mode: 0o600 });
  },
  async clear() { await rm(tokens.file(), { force: true }); }
};

/** The Agneta on this port, to open when it isn't running: a release on 47321, a development build on 47331. An
 * isolated instance (any other port) has no URL to open it by. */
const agneta = port === 47321 ? { name: 'Agneta', url: 'agneta://open' } : port === 47331 ? { name: 'Agneta Dev', url: 'agneta-dev://open' } : null;

/** Asks whether to open Agneta, and opens it when the user says so (docs/APP_PROTOCOL.md, Connecting). */
async function openAgneta() {
  if (!agneta) return false;
  const { response } = await dialog.showMessageBox(window, {
    type: 'info',
    message: `${agneta.name} isn't running`,
    detail: `Project Chat runs its AI tasks through ${agneta.name}, on the plan or API key you allow. Open ${agneta.name} now?`,
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
    connect: () => chat.connect(),
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

async function openWindow() {
  const current = new ProjectChat(port, { tokens, openAgneta });
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
  chat = current;

  opened.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  opened.webContents.on('will-navigate', (event) => event.preventDefault());
  opened.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  current.on('change', (state) => {
    if (!opened.isDestroyed()) opened.webContents.send('chat:state-changed', state);
  });
  // Closing the window ends its chat (and an Allow Once grant with it).
  opened.once('close', () => {
    current.removeAllListeners('change');
    current.disconnect();
  });
  opened.once('closed', () => {
    if (window === opened) window = undefined;
  });
  await opened.loadURL(entry);
  // With access kept from an earlier Always Allow, it connects by itself; otherwise Connect asks Agneta.
  current.connect({ quiet: true });
}
