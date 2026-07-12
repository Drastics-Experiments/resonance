const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("likedSongs", {
  loadLibrary: () => ipcRenderer.invoke("library:load"),
  saveLibrary: (state) => ipcRenderer.invoke("library:save", state),
  importAudio: () => ipcRenderer.invoke("library:import"),
  deleteAudio: (filePath) => ipcRenderer.invoke("library:delete", filePath),
  storageSummary: () => ipcRenderer.invoke("library:storage"),
  fetchCatalog: (settings) => ipcRenderer.invoke("server:catalog", settings),
  fetchPlaylists: (settings) => ipcRenderer.invoke("server:playlists:get", settings),
  putPlaylists: (settings) => ipcRenderer.invoke("server:playlists:put", settings),
  syncServer: (settings) => ipcRenderer.invoke("server:sync", settings),
  uploadServer: (settings) => ipcRenderer.invoke("server:upload", settings),
  deleteServerSong: (settings) => ipcRenderer.invoke("server:delete", settings),
  loadServerCredentials: () => ipcRenderer.invoke("server:credentials:load"),
  saveServerCredentials: (credentials) => ipcRenderer.invoke("server:credentials:save", credentials),
  onTransferProgress: (callback) => ipcRenderer.on("server:transfer-progress", (_event, value) => callback(value)),
  openAdmin: (baseURL) => ipcRenderer.invoke("server:open-admin", baseURL),
  checkForUpdates: () => ipcRenderer.invoke("update:check"),
  installUpdate: () => ipcRenderer.invoke("update:install"),
  onUpdateStatus: (callback) => ipcRenderer.on("update:status", (_event, value) => callback(value)),
});
