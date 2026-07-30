import { contextBridge, ipcRenderer, webUtils } from 'electron';
import type {
  DesktopLibrarySnapshot,
  DesktopIngestionStatus,
  DesktopOperationResult,
  DesktopSyncStatus,
  AICommandPreferencesUpdate,
  LibraryVariant,
  VoiceBriefDraft,
  VoiceBriefSnapshot,
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
  capturePDF: (file: File) =>
    ipcRenderer.invoke('library:capture-pdf', webUtils.getPathForFile(file)),
  openExternal: (url: string) => ipcRenderer.invoke('library:open-external', url),
  openAgent: () => ipcRenderer.invoke('library:open-agent'),
  revealEntry: (entryID: string) => ipcRenderer.invoke('library:reveal-entry', entryID),
  showEntryContextMenu: (entryIDs: string[], variant?: LibraryVariant) =>
    ipcRenderer.invoke('library:show-entry-context-menu', entryIDs, variant),
  getConnectionStatus: () => ipcRenderer.invoke('services:get-status'),
  signIn: (provider) => ipcRenderer.invoke('services:sign-in', provider),
  manageAccount: () => ipcRenderer.invoke('services:manage-account'),
  syncNow: () => ipcRenderer.invoke('services:sync-now'),
  getShortcutPreferences: () => ipcRenderer.invoke('shortcuts:get-preferences'),
  setCaptureShortcut: (accelerator: string) =>
    ipcRenderer.invoke('shortcuts:set-capture', accelerator),
  getAudioPreferences: () => ipcRenderer.invoke('audio:get-preferences'),
  setSaveCapturedAudio: (enabled: boolean) =>
    ipcRenderer.invoke('audio:set-save-captured', enabled),
  getAboutYou: () => ipcRenderer.invoke('personalization:get-about-you'),
  setAboutYou: (value: string) =>
    ipcRenderer.invoke('personalization:set-about-you', value),
  getIngestionStatus: () => ipcRenderer.invoke('ingestion:get-status'),
  getProcessingPreferences: () => ipcRenderer.invoke('processing:get-preferences'),
  updateProcessingPreferences: (preferences: ProcessingPreferencesUpdate) =>
    ipcRenderer.invoke('processing:update-preferences', preferences),
  getPromptPreferences: () => ipcRenderer.invoke('prompts:get'),
  updatePromptPreference: (preference: PromptPreferenceUpdate) =>
    ipcRenderer.invoke('prompts:update', preference),
  getAICommandPreferences: () => ipcRenderer.invoke('ai-commands:get'),
  updateAICommandPreferences: (preferences: AICommandPreferencesUpdate) =>
    ipcRenderer.invoke('ai-commands:update', preferences),
  testAIProcessingCommand: (command: string) =>
    ipcRenderer.invoke('ai-commands:test-processing', command),
  getVoiceBriefs: () => ipcRenderer.invoke('voice-briefs:get'),
  saveVoiceBrief: (voiceBrief: VoiceBriefDraft) =>
    ipcRenderer.invoke('voice-briefs:save', voiceBrief),
  removeVoiceBrief: (id: string) => ipcRenderer.invoke('voice-briefs:remove', id),
  checkVoiceBrief: (id: string) => ipcRenderer.invoke('voice-briefs:check', id),
  runVoiceBrief: (id: string) => ipcRenderer.invoke('voice-briefs:run', id),
  revealVoiceBrief: (id: string) => ipcRenderer.invoke('voice-briefs:reveal', id),
  addChannel: (source: string) => ipcRenderer.invoke('channels:add', source),
  checkChannel: (source: string) => ipcRenderer.invoke('channels:check', source),
  updateChannel: (source: string, retrievalCount: number) =>
    ipcRenderer.invoke('channels:update', source, retrievalCount),
  loadMoreChannel: (source: string) =>
    ipcRenderer.invoke('channels:load-more', source),
  removeChannel: (source: string) => ipcRenderer.invoke('channels:remove', source),
  loginChannel: (url: string) => ipcRenderer.invoke('channels:login', url),
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
  onVoiceBriefsChanged: (listener: (snapshot: VoiceBriefSnapshot) => void) => {
    const callback = (_event: Electron.IpcRendererEvent, snapshot: VoiceBriefSnapshot) =>
      listener(snapshot);
    ipcRenderer.on('voice-briefs:changed', callback);
    return () => ipcRenderer.removeListener('voice-briefs:changed', callback);
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
