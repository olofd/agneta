const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('projectChat', {
  state: () => ipcRenderer.invoke('chat:state'),
  connect: () => ipcRenderer.invoke('chat:connect'),
  send: (text) => ipcRenderer.invoke('chat:send', text),
  stop: () => ipcRenderer.invoke('chat:stop'),
  newChat: () => ipcRenderer.invoke('chat:newChat'),
  disconnect: () => ipcRenderer.invoke('chat:disconnect'),
  save: () => ipcRenderer.invoke('chat:save'),
  dismiss: () => ipcRenderer.invoke('chat:dismiss'),
  onChange(listener) {
    ipcRenderer.on('chat:state-changed', (_event, state) => listener(state));
  }
});
