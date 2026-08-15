const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  synthesize: (options) => ipcRenderer.invoke('synthesize', options)
});
