import { contextBridge, ipcRenderer } from 'electron';
import type {
  DesktopLibrarySnapshot,
  DesktopOperationResult,
  DesktopSyncStatus,
  LibraryVariant,
  NarrationSegment,
  OpenRouterVoice,
  SharedLibraryDesktopAPI
} from '../shared/contracts.js';

const api: SharedLibraryDesktopAPI = {
  getSnapshot: () => ipcRenderer.invoke('library:get-snapshot'),
  chooseWorkspace: () => ipcRenderer.invoke('library:choose-workspace'),
  refresh: () => ipcRenderer.invoke('library:refresh'),
  readText: (entryID: string, variant: LibraryVariant) =>
    ipcRenderer.invoke('library:read-text', entryID, variant),
  writeText: (entryID: string, variant: LibraryVariant, text: string) =>
    ipcRenderer.invoke('library:write-text', entryID, variant, text),
  trashCapture: (entryID: string) =>
    ipcRenderer.invoke('library:trash-capture', entryID),
  captureClipboard: () => ipcRenderer.invoke('library:capture-clipboard'),
  openExternal: (url: string) => ipcRenderer.invoke('library:open-external', url),
  revealEntry: (entryID: string) => ipcRenderer.invoke('library:reveal-entry', entryID),
  getConnectionStatus: () => ipcRenderer.invoke('services:get-status'),
  connect: (provider) => ipcRenderer.invoke('services:connect', provider),
  disconnect: (provider) => ipcRenderer.invoke('services:disconnect', provider),
  syncNow: () => ipcRenderer.invoke('services:sync-now'),
  setVoice: (voice: OpenRouterVoice) => ipcRenderer.invoke('services:set-voice', voice),
  startNarration: (
    entryID: string,
    variant: LibraryVariant,
    voice: OpenRouterVoice
  ) => ipcRenderer.invoke('narration:start', entryID, variant, voice),
  getShareLink: (entryID: string) => ipcRenderer.invoke('sharing:get', entryID),
  publishShareLink: (
    entryID: string,
    voice: OpenRouterVoice
  ) => ipcRenderer.invoke('sharing:publish', entryID, voice),
  revokeShareLink: (token: string) => ipcRenderer.invoke('sharing:revoke', token),
  onLibraryChanged: (listener: (snapshot: DesktopLibrarySnapshot) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, snapshot: DesktopLibrarySnapshot) =>
      listener(snapshot);
    ipcRenderer.on('library:changed', callback);
    return () => ipcRenderer.removeListener('library:changed', callback);
  },
  onSyncStatus: (listener: (status: DesktopSyncStatus) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, status: DesktopSyncStatus) =>
      listener(status);
    ipcRenderer.on('sync:status', callback);
    return () => ipcRenderer.removeListener('sync:status', callback);
  },
  onNarrationSegment: (listener: (segment: NarrationSegment) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, segment: NarrationSegment) =>
      listener(segment);
    ipcRenderer.on('narration:segment', callback);
    return () => ipcRenderer.removeListener('narration:segment', callback);
  }
};

contextBridge.exposeInMainWorld('sharedLibrary', api);

contextBridge.exposeInMainWorld('sharedLibraryDesktopEvents', {
  onChooseWorkspace(listener: () => void) {
    const callback = () => listener();
    ipcRenderer.on('desktop:choose-workspace', callback);
    return () => ipcRenderer.removeListener('desktop:choose-workspace', callback);
  },
  onOperationMessage(listener: (result: Partial<DesktopOperationResult>) => void) {
    const callback = (
      _event: Electron.IpcRendererEvent,
      result: Partial<DesktopOperationResult>
    ) => listener(result);
    ipcRenderer.on('desktop:operation-message', callback);
    return () => ipcRenderer.removeListener('desktop:operation-message', callback);
  }
});
