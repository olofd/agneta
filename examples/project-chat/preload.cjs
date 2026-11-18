const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('projectChat', {
  state: () => ipcRenderer.invoke('chat:state'),
  agnetas: () => ipcRenderer.invoke('chat:agnetas'),
  use: (id) => ipcRenderer.invoke('chat:use', id),
  connect: () => ipcRenderer.invoke('chat:connect'),
  send: (text) => ipcRenderer.invoke('chat:send', text),
  stop: () => ipcRenderer.invoke('chat:stop'),
  newChat: () => ipcRenderer.invoke('chat:newChat'),
  choose: (choice) => ipcRenderer.invoke('chat:choose', choice),
  configure: (settings) => ipcRenderer.invoke('chat:configure', settings),
  disconnect: () => ipcRenderer.invoke('chat:disconnect'),
  save: () => ipcRenderer.invoke('chat:save'),
  dismiss: () => ipcRenderer.invoke('chat:dismiss'),
  onChange(listener) {
    ipcRenderer.on('chat:state-changed', (_event, state) => listener(state));
  }
});
