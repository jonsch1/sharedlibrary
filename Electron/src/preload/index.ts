import { contextBridge, ipcRenderer } from 'electron';
import type {
  DesktopLibrarySnapshot,
  DesktopIngestionStatus,
  DesktopOperationResult,
  DesktopSyncStatus,
  LibraryVariant,
  PodcastDraft,
  PodcastSnapshot,
  PromptPreferenceUpdate,
  ProcessingPreferencesUpdate,
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
  openAgent: () => ipcRenderer.invoke('library:open-agent'),
  revealEntry: (entryID: string) => ipcRenderer.invoke('library:reveal-entry', entryID),
  showEntryContextMenu: (entryID: string, variant?: LibraryVariant) =>
    ipcRenderer.invoke('library:show-entry-context-menu', entryID, variant),
  getConnectionStatus: () => ipcRenderer.invoke('services:get-status'),
  signIn: (provider) => ipcRenderer.invoke('services:sign-in', provider),
  manageAccount: () => ipcRenderer.invoke('services:manage-account'),
  syncNow: () => ipcRenderer.invoke('services:sync-now'),
  getShortcutPreferences: () => ipcRenderer.invoke('shortcuts:get-preferences'),
  setCaptureShortcut: (accelerator: string) =>
    ipcRenderer.invoke('shortcuts:set-capture', accelerator),
  getIngestionStatus: () => ipcRenderer.invoke('ingestion:get-status'),
  getProcessingPreferences: () => ipcRenderer.invoke('processing:get-preferences'),
  updateProcessingPreferences: (preferences: ProcessingPreferencesUpdate) =>
    ipcRenderer.invoke('processing:update-preferences', preferences),
  getPromptPreferences: () => ipcRenderer.invoke('prompts:get'),
  updatePromptPreference: (preference: PromptPreferenceUpdate) =>
    ipcRenderer.invoke('prompts:update', preference),
  getPodcasts: () => ipcRenderer.invoke('podcasts:get'),
  savePodcast: (podcast: PodcastDraft) =>
    ipcRenderer.invoke('podcasts:save', podcast),
  removePodcast: (id: string) => ipcRenderer.invoke('podcasts:remove', id),
  checkPodcast: (id: string) => ipcRenderer.invoke('podcasts:check', id),
  runPodcast: (id: string) => ipcRenderer.invoke('podcasts:run', id),
  revealPodcast: (id: string) => ipcRenderer.invoke('podcasts:reveal', id),
  getShareLink: (entryID: string) => ipcRenderer.invoke('sharing:get', entryID),
  publishShareLink: (entryID: string) => ipcRenderer.invoke('sharing:publish', entryID),
  revokeShareLink: (token: string) => ipcRenderer.invoke('sharing:revoke', token),
  onLibraryChanged: (listener: (snapshot: DesktopLibrarySnapshot) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, snapshot: DesktopLibrarySnapshot) =>
      listener(snapshot);
    ipcRenderer.on('library:changed', callback);
    return () => ipcRenderer.removeListener('library:changed', callback);
  },
  onIngestionStatus: (listener: (status: DesktopIngestionStatus) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, status: DesktopIngestionStatus) =>
      listener(status);
    ipcRenderer.on('ingestion:status', callback);
    return () => ipcRenderer.removeListener('ingestion:status', callback);
  },
  onSyncStatus: (listener: (status: DesktopSyncStatus) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, status: DesktopSyncStatus) =>
      listener(status);
    ipcRenderer.on('sync:status', callback);
    return () => ipcRenderer.removeListener('sync:status', callback);
  },
  onPodcastsChanged: (listener: (snapshot: PodcastSnapshot) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, snapshot: PodcastSnapshot) =>
      listener(snapshot);
    ipcRenderer.on('podcasts:changed', callback);
    return () => ipcRenderer.removeListener('podcasts:changed', callback);
  },
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
