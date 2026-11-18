import { app, BrowserWindow, ipcMain, net, protocol } from 'electron';
import { fileURLToPath } from 'node:url';
import { ProjectChat } from './chat.mjs';

const port = Number(process.env.AGNETA_PORT ?? 47331);
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
app.on('window-all-closed', () => app.quit());

// Electron finishes loading this module before it emits ready.
app.whenReady().then(openWindow).catch((error) => {
  console.error('Project Chat could not open:', error);
  app.exit(1);
});

async function openWindow() {
  protocol.handle(scheme, (request) => {
    const file = assets.get(request.url);
    if (request.method !== 'GET' || !file) return new Response(null, { status: 404 });
    return net.fetch(file.href);
  });

  const chat = new ProjectChat(port);
  const window = new BrowserWindow({
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

  // The renderer gets a fixed set of actions. The WebSocket, pairing token and
  // MCP credentials stay in the main process.
  const actions = {
    state: () => chat.view,
    connect: () => chat.connect(),
    send: (text) => chat.send(text),
    stop: () => chat.stop(),
    newChat: () => chat.newChat(),
    choose: (value) => chat.choose(value),
    disconnect: () => chat.disconnect(),
    save: () => chat.review(true),
    dismiss: () => chat.review(false)
  };
  for (const [name, action] of Object.entries(actions)) {
    ipcMain.handle(`chat:${name}`, (event, value) => {
      if (event.sender !== window.webContents || event.senderFrame?.url !== entry ||
          event.senderFrame !== window.webContents.mainFrame) {
        throw new Error('Unexpected IPC sender.');
      }
      return action(value);
    });
  }

  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event) => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  chat.on('change', (state) => {
    if (!window.isDestroyed()) window.webContents.send('chat:state-changed', state);
  });
  window.once('close', () => {
    chat.removeAllListeners('change');
    chat.disconnect();
  });
  await window.loadURL(entry);
}
