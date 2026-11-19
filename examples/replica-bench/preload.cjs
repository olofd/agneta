// The renderer's only way into the app: named actions and the view. No ACP, tokens or bearers cross this bridge.
const { contextBridge, ipcRenderer } = require('electron');

const action = (name) => (value) => ipcRenderer.invoke(`bench:${name}`, value);

contextBridge.exposeInMainWorld('replicaBench', {
  state: action('state'),
  agnetas: action('agnetas'),
  use: action('use'),
  connect: action('connect'),
  disconnect: action('disconnect'),
  pairAgain: action('pairAgain'),
  choose: action('choose'),
  configure: action('configure'),
  runScenario: action('runScenario'),
  send: action('send'),
  stop: action('stop'),
  newRun: action('newRun'),
  runMatrix: action('runMatrix'),
  checkModes: action('checkModes'),
  loadReports: action('loadReports'),
  showWorkspace: action('showWorkspace'),
  openReport: action('openReport'),
  showReport: action('showReport'),
  showResults: action('showResults'),
  onChange(listener) {
    ipcRenderer.on('bench:state-changed', (_event, state) => listener(state));
  }
});
