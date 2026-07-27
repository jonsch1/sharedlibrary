import {
  app,
  BrowserWindow,
  clipboard,
  dialog,
  globalShortcut,
  ipcMain,
  Menu,
  net,
  nativeImage,
  protocol,
  shell
} from 'electron';
import type { MenuItemConstructorOptions, OpenDialogOptions } from 'electron';
import type { MessageBoxOptions } from 'electron';
import { spawn } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import electronUpdater from 'electron-updater';
import type {
  AccountProvider,
  DesktopConnectionStatus,
  DesktopIngestionStatus,
  DesktopShortcutPreferences,
  LibraryVariant,
  OpenRouterTTSModel,
  OpenRouterVoice,
  ProcessingPreferences,
  ProcessingPreferencesUpdate
} from '../shared/contracts.js';
import {
  defaultCaptureShortcut,
  normalizeCaptureShortcut
} from '../shared/shortcuts.js';
import {
  defaultOpenRouterTTSModel,
  isVoiceForTTSModel,
  migrateVoiceForTTSModel,
  normalizeOpenRouterVoice,
  normalizeOpenRouterTTSModel,
  recommendedVoiceForTTSModel
} from '../shared/contracts.js';
import {
  AgentApiServer,
  type BundledAgentSkill
} from './agent-api.js';
import { BackendClient } from './backend.js';
import { ExtractionService } from './extraction.js';
import { LibraryService } from './library.js';
import { NarrationService } from './narration.js';
import {
  defaultProcessingPrompt,
  ProcessingService
} from './processing.js';
import { SettingsStore } from './settings.js';
import { SyncCoordinator } from './sync.js';

protocol.registerSchemesAsPrivileged([
  {
    scheme: 'shared-library-audio',
    privileges: {
      secure: true,
      standard: true,
      stream: true,
      supportFetchAPI: true
    }
  }
]);
app.setName('Briefly');
// Preserve the existing profile so the rebrand keeps settings, sessions, and audio.
if (
  !process.env.BRIEFLY_E2E_USER_DATA &&
  !process.env.SHARED_LIBRARY_E2E_USER_DATA
) {
  app.setPath('userData', join(app.getPath('appData'), 'shared-library-electron'));
}
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

let mainWindow: BrowserWindow | null = null;
let agentApi: AgentApiServer;
let library: LibraryService;
let settings: SettingsStore;
let backend: BackendClient;
let extraction: ExtractionService;
let processing: ProcessingService;
let narration: NarrationService;
let sync: SyncCoordinator;
let voice: OpenRouterVoice = 'af_heart';
let ttsModel: OpenRouterTTSModel = defaultOpenRouterTTSModel;
let captureShortcut = defaultCaptureShortcut;
let activeIngestionCount = 0;

async function defaultWorkspacePath(): Promise<string> {
  const preferred = join(app.getPath('documents'), 'Briefly');
  const legacy = join(app.getPath('documents'), 'Shared Library');
  try {
    if ((await stat(legacy)).isDirectory()) return legacy;
  } catch {
    // New installations use the Briefly workspace name.
  }
  return preferred;
}

function applicationIconPath(): string {
  return app.isPackaged
    ? join(process.resourcesPath, 'icon.png')
    : join(app.getAppPath(), 'build', 'icon.png');
}

function bundledAgentSkills(): BundledAgentSkill[] {
  const root = app.isPackaged
    ? join(process.resourcesPath, 'skills')
    : join(app.getAppPath(), 'resources', 'skills');
  return ['briefly-deep-research', 'briefly-input-extension'].map((name) => ({
    name,
    sourcePath: join(root, name)
  }));
}

async function snapshotAndNotify() {
  const snapshot = await library.snapshot();
  mainWindow?.webContents.send('library:changed', snapshot);
  return snapshot;
}

function sendOperationMessage(message: string, selectedEntryID?: string): void {
  mainWindow?.webContents.send('desktop:operation-message', {
    message,
    selectedEntryID
  });
}

function ingestionStatus(): DesktopIngestionStatus {
  return activeIngestionCount > 0
    ? {
        phase: 'processing',
        activeCount: activeIngestionCount,
        message:
          activeIngestionCount === 1
            ? 'Ingesting 1 source…'
            : `Ingesting ${activeIngestionCount} sources…`
      }
    : {
        phase: 'idle',
        activeCount: 0,
        message: 'All sources are ready.'
      };
}

function updateIngestionPresentation(): void {
  const status = ingestionStatus();
  mainWindow?.setProgressBar(
    status.phase === 'processing' ? 2 : -1,
    status.phase === 'processing' ? { mode: 'indeterminate' } : undefined
  );
  if (process.platform === 'darwin') {
    app.dock?.setBadge(status.activeCount > 0 ? String(status.activeCount) : '');
  }
  mainWindow?.webContents.send('ingestion:status', status);
}

function beginIngestion(): () => void {
  activeIngestionCount += 1;
  updateIngestionPresentation();
  let finished = false;
  return () => {
    if (finished) return;
    finished = true;
    activeIngestionCount = Math.max(0, activeIngestionCount - 1);
    updateIngestionPresentation();
  };
}

function shortcutPreferences(): DesktopShortcutPreferences {
  return {
    captureShortcut,
    defaultCaptureShortcut,
    registered: globalShortcut.isRegistered(captureShortcut)
  };
}

function activateCaptureShortcut(next: string): boolean {
  const previous = captureShortcut;
  if (next === previous && globalShortcut.isRegistered(next)) return true;
  if (next !== previous && globalShortcut.isRegistered(previous)) {
    globalShortcut.unregister(previous);
  }

  let registered = false;
  try {
    registered = globalShortcut.register(next, () => void captureFromMenu());
  } catch {
    registered = false;
  }
  if (registered) {
    captureShortcut = next;
    return true;
  }

  if (next !== previous) {
    try {
      globalShortcut.register(previous, () => void captureFromMenu());
    } catch {
      // The menu command remains available if the OS will not restore the shortcut.
    }
  }
  return false;
}

async function connectionStatus(): Promise<DesktopConnectionStatus> {
  const account = await backend.accountStatus();
  const [google, icloud, billing, tts] = account.authenticated
    ? await Promise.all([
        backend.providerStatus('google'),
        backend.providerStatus('icloud'),
        backend.billingStatus(),
        backend.ttsStatus()
      ])
    : [
        { configured: true, connected: false },
        { configured: false, connected: false },
        { entitled: false },
        { configured: false, checkoutConfigured: false, balanceMicros: 0 }
      ];
  return {
    authenticated: account.authenticated,
    entitled: billing.entitled === true,
    syncProvider: account.syncProvider ?? null,
    google: {
      configured: google.configured !== false,
      connected: google.connected === true,
      connectedAt:
        typeof google.connectedAt === 'string' ? google.connectedAt : undefined
    },
    icloud: {
      configured: icloud.configured === true,
      connected: icloud.connected === true
    },
    tts: {
      configured: tts.configured === true,
      checkoutConfigured: tts.checkoutConfigured === true,
      balanceMicros:
        typeof tts.balanceMicros === 'number' && Number.isSafeInteger(tts.balanceMicros)
          ? Math.max(0, tts.balanceMicros)
          : 0
    },
    sync: sync.currentStatus(),
    voice,
    ttsModel
  };
}

async function processingPreferences(): Promise<ProcessingPreferences> {
  const saved = await settings.load();
  return {
    topics: await library.topicDefinitions(),
    prompt: saved.processingPrompt ?? defaultProcessingPrompt,
    defaultPrompt: defaultProcessingPrompt
  };
}

function normalizeProcessingPreferences(value: unknown): ProcessingPreferencesUpdate {
  if (!value || typeof value !== 'object') {
    throw new Error('Processing settings are invalid.');
  }
  const candidate = value as Partial<ProcessingPreferencesUpdate>;
  const prompt = typeof candidate.prompt === 'string' ? candidate.prompt.trim() : '';
  if (!prompt) throw new Error('The processing prompt cannot be empty.');
  if (prompt.length > 50_000) {
    throw new Error('The processing prompt must be 50,000 characters or fewer.');
  }
  if (!prompt.includes('{{topics}}') || !prompt.includes('{{source}}')) {
    throw new Error('The processing prompt must include {{topics}} and {{source}}.');
  }
  if (!Array.isArray(candidate.topics)) {
    throw new Error('The topic list is invalid.');
  }
  const topics = candidate.topics.map((topic) => {
    if (
      !topic ||
      typeof topic !== 'object' ||
      typeof topic.id !== 'string' ||
      typeof topic.title !== 'string'
    ) {
      throw new Error('The topic list is invalid.');
    }
    return { id: topic.id, title: topic.title };
  });
  return { topics, prompt };
}

async function createWindow(): Promise<void> {
  mainWindow = new BrowserWindow({
    title: 'Briefly',
    icon: applicationIconPath(),
    width: 1280,
    height: 780,
    minWidth: 920,
    minHeight: 620,
    backgroundColor: '#dadbd4',
    show: false,
    webPreferences: {
      preload: join(__dirname, '../preload/index.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  mainWindow.on('closed', () => {
    mainWindow = null;
  });
  mainWindow.once('ready-to-show', () => {
    mainWindow?.show();
  });
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) void shell.openExternal(url);
    return { action: 'deny' };
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    await mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    await mainWindow.loadFile(join(__dirname, '../renderer/index.html'));
  }
  updateIngestionPresentation();
}

function registerIPC(): void {
  ipcMain.handle('library:get-snapshot', () => library.snapshot());
  ipcMain.handle('library:refresh', () => snapshotAndNotify());
  ipcMain.handle('library:choose-workspace', async () => {
    const options: OpenDialogOptions = {
      title: 'Choose your Briefly workspace',
      properties: ['openDirectory', 'createDirectory']
    };
    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);
    const path = result.filePaths[0];
    if (result.canceled || !path) return null;
    const previousWorkspacePath = library.getWorkspacePath();
    library.setWorkspacePath(path);
    await settings.update({ workspacePath: path });
    await agentApi.refreshWorkspace(previousWorkspacePath);
    return snapshotAndNotify();
  });
  ipcMain.handle(
    'library:read-text',
    (_event, entryID: string, variant: LibraryVariant) =>
      library.readText(entryID, variant)
  );
  ipcMain.handle(
    'library:write-text',
    async (_event, entryID: string, variant: LibraryVariant, text: string) => {
      await library.writeText(entryID, variant, text);
      sync.request('document edits');
      return {
        snapshot: await snapshotAndNotify(),
        message: 'Document saved.',
        selectedEntryID: entryID
      };
    }
  );
  ipcMain.handle('library:trash-capture', async (_event, entryID: string) => {
    await library.trashCapture(entryID);
    sync.request('deleted documents');
    return {
      snapshot: await snapshotAndNotify(),
      message: 'The source and its summaries were moved to Trash.'
    };
  });
  ipcMain.handle('library:capture-clipboard', () => captureClipboard());
  ipcMain.handle('library:open-external', async (_event, value: string) => {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw new Error('Only web links can be opened.');
    }
    await shell.openExternal(url.toString());
  });
  ipcMain.handle('library:open-agent', () => openAgentWorkspace());
  ipcMain.handle('library:reveal-entry', async (_event, entryID: string) => {
    const snapshot = await library.snapshot();
    const entry = snapshot.entries.find((candidate) => candidate.id === entryID);
    if (!entry) throw new Error('The selected item no longer exists.');
    shell.showItemInFolder(join(library.getWorkspacePath(), 'library', entry.filename));
  });
  ipcMain.handle(
    'library:show-entry-context-menu',
    async (
      event,
      entryID: string,
      variant: LibraryVariant | undefined
    ) => {
      const snapshot = await library.snapshot();
      const entry = snapshot.entries.find((candidate) => candidate.id === entryID);
      if (!entry) throw new Error('The selected item no longer exists.');
      const path = await library.filePath(entryID, variant);
      const window = BrowserWindow.fromWebContents(event.sender) ?? undefined;
      const menu = Menu.buildFromTemplate([
        {
          label: 'Copy Path',
          click: () => {
            clipboard.writeText(path);
            sendOperationMessage('Path copied.');
          }
        },
        { type: 'separator' },
        {
          label: 'Move to Trash…',
          click: () => void trashEntryFromContextMenu(entryID, entry.title)
        }
      ]);
      menu.popup({ window });
    }
  );
  ipcMain.handle('services:get-status', () => connectionStatus());
  ipcMain.handle(
    'services:sign-in',
    async (_event, provider: AccountProvider) => {
      if (provider !== 'google' && provider !== 'apple') {
        throw new Error('Unknown account provider.');
      }
      await backend.signIn(provider, mainWindow);
      return connectionStatus();
    }
  );
  ipcMain.handle(
    'services:manage-account',
    async () => {
      await backend.manageAccount(mainWindow);
      await sync.synchronize('account settings');
      return connectionStatus();
    }
  );
  ipcMain.handle('services:sync-now', async () => {
    await sync.synchronize('the library');
    return connectionStatus();
  });
  ipcMain.handle('services:set-voice', async (_event, nextVoice: OpenRouterVoice) => {
    const normalizedVoice = normalizeOpenRouterVoice(nextVoice);
    if (!normalizedVoice || !isVoiceForTTSModel(ttsModel, normalizedVoice)) {
      throw new Error('Choose a voice supported by the selected narration quality.');
    }
    voice = normalizedVoice;
    await settings.update({ voice });
    return connectionStatus();
  });
  ipcMain.handle('services:set-tts-model', async (_event, value: unknown) => {
    const nextModel = normalizeOpenRouterTTSModel(value);
    if (!nextModel) {
      throw new Error('Choose Low, Medium, or High narration quality.');
    }
    const changed = nextModel !== ttsModel;
    ttsModel = nextModel;
    const recommendedVoice = changed ? recommendedVoiceForTTSModel(nextModel) : null;
    if (recommendedVoice) voice = recommendedVoice;
    await settings.update({ ttsModel, voice });
    return connectionStatus();
  });
  ipcMain.handle('shortcuts:get-preferences', () => shortcutPreferences());
  ipcMain.handle('shortcuts:set-capture', async (_event, value: unknown) => {
    const next = normalizeCaptureShortcut(value);
    if (!next) {
      throw new Error('Choose a shortcut with Ctrl, Command, or Alt plus another key.');
    }
    const previous = captureShortcut;
    if (!activateCaptureShortcut(next)) {
      throw new Error('That shortcut is already in use by the operating system or another app.');
    }
    try {
      await settings.update({ captureShortcut: next });
    } catch (error) {
      activateCaptureShortcut(previous);
      throw error;
    }
    installMenu();
    return shortcutPreferences();
  });
  ipcMain.handle('ingestion:get-status', () => ingestionStatus());
  ipcMain.handle('processing:get-preferences', () => processingPreferences());
  ipcMain.handle(
    'processing:update-preferences',
    async (_event, value: unknown) => {
      const next = normalizeProcessingPreferences(value);
      await library.replaceTopicDefinitions(next.topics);
      await settings.update({ processingPrompt: next.prompt });
      await snapshotAndNotify();
      sync.request('processing settings');
      return processingPreferences();
    }
  );
  ipcMain.handle(
    'narration:start',
    async (_event, entryID: string, variant: LibraryVariant, selectedVoice: OpenRouterVoice) => {
      const text = await library.readText(entryID, variant);
      return narration.start(text, selectedVoice, ttsModel);
    }
  );
  ipcMain.handle('sharing:get', async (_event, entryID: string) => {
    const entry = await entryForID(entryID);
    return backend.shareStatus(entry.captureID);
  });
  ipcMain.handle(
    'sharing:publish',
    async (_event, entryID: string, selectedVoice: OpenRouterVoice) => {
      const entry = await entryForID(entryID);
      const syncStatus = await sync.synchronize('the document');
      if (syncStatus.phase === 'error') throw new Error(syncStatus.message);
      const source =
        backend.currentSyncProvider() === 'icloud'
          ? await (async () => {
              const mirror = await library.buildDriveMirror();
              const indexed = mirror.index.entries.find(
                (candidate) => candidate.captureID === entry.captureID
              );
              if (!indexed) throw new Error('The selected document is unavailable.');
              const files = new Map(mirror.files.map((file) => [file.path, file.content]));
              return {
                filename: entry.filename,
                title: entry.title,
                excerpt: entry.excerpt,
                topicIDs: entry.topicIDs,
                topicNames: entry.topicNames,
                tags: entry.tags,
                sourceURL: entry.sourceURL,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                texts: indexed.texts.flatMap((text) => {
                  const markdown = files.get(text.path);
                  return markdown === undefined ? [] : [{ variant: text.variant, markdown }];
                })
              };
            })()
          : undefined;
      let result = await backend.publishShare(
        entry.captureID,
        selectedVoice,
        ttsModel,
        source
      );
      if (source) {
        for (const variant of entry.availableVariants) {
          const segments = await narration.storedSegments(
            await library.readText(entry.id, variant),
            selectedVoice,
            ttsModel
          );
          if (!segments) continue;
          for (let index = 0; index < segments.length; index += 1) {
            await backend.uploadShareAudio(
              result,
              variant,
              index,
              segments[index].hash,
              selectedVoice,
              segments[index].bytes
            );
          }
        }
      }
      for (let attempt = 0; result.status === 'preparing' && attempt < 30; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        result = await backend.shareStatus(entry.captureID);
      }
      if (result.status === 'failed') {
        throw new Error(result.error || 'The share link could not be prepared.');
      }
      if (result.url) clipboard.writeText(result.url);
      return result;
    }
  );
  ipcMain.handle('sharing:revoke', async (_event, token: string) => {
    if (!/^[A-Za-z0-9_-]{32}$/.test(token)) throw new Error('Invalid share link.');
    await backend.revokeShare(token);
  });
}

async function openAgentWorkspace(): Promise<void> {
  const workspacePath = library.getWorkspacePath();
  if (process.platform === 'darwin') {
    await new Promise<void>((resolve, reject) => {
      const child = spawn('/usr/bin/open', ['-a', 'ChatGPT', workspacePath], {
        detached: true,
        stdio: 'ignore'
      });
      child.once('error', reject);
      child.once('spawn', () => {
        child.unref();
        resolve();
      });
    });
    return;
  }
  const error = await shell.openPath(workspacePath);
  if (error) throw new Error(error);
}

async function trashEntryFromContextMenu(
  entryID: string,
  title: string
): Promise<void> {
  const options: MessageBoxOptions = {
    type: 'warning',
    buttons: ['Cancel', 'Move to Trash'],
    defaultId: 0,
    cancelId: 0,
    message: `Move “${title}” to Trash?`,
    detail: 'The source document and all of its summaries will be moved together.'
  };
  const response = mainWindow
    ? await dialog.showMessageBox(mainWindow, options)
    : await dialog.showMessageBox(options);
  if (response.response !== 1) return;
  try {
    await library.trashCapture(entryID);
    sync.request('deleted documents');
    await snapshotAndNotify();
    sendOperationMessage('The source and its summaries were moved to Trash.');
  } catch (error) {
    sendOperationMessage(
      error instanceof Error ? error.message : 'The document could not be moved to Trash.'
    );
  }
}

async function entryForID(entryID: string) {
  const snapshot = await library.snapshot();
  const entry = snapshot.entries.find((candidate) => candidate.id === entryID);
  if (!entry) throw new Error('The selected library item no longer exists.');
  return entry;
}

function installMenu(): void {
  const template: MenuItemConstructorOptions[] = [
    ...(process.platform === 'darwin'
      ? [
          {
            label: app.name,
            submenu: [
              { role: 'about' as const },
              { type: 'separator' as const },
              { role: 'hide' as const },
              { role: 'hideOthers' as const },
              { type: 'separator' as const },
              { role: 'quit' as const }
            ]
          }
        ]
      : []),
    {
      label: 'File',
      submenu: [
        {
          label: 'Capture Clipboard',
          accelerator: captureShortcut,
          click: () => void captureFromMenu()
        },
        {
          label: 'Choose Workspace…',
          click: () => mainWindow?.webContents.send('desktop:choose-workspace')
        },
        { type: 'separator' },
        process.platform === 'darwin' ? { role: 'close' } : { role: 'quit' }
      ]
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' }
      ]
    },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' }
      ]
    },
    {
      label: 'Window',
      submenu: [{ role: 'minimize' }, { role: 'zoom' }, { role: 'front' }]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

async function captureFromMenu(): Promise<void> {
  try {
    const result = await captureClipboard();
    mainWindow?.show();
    mainWindow?.focus();
    sendOperationMessage(result.message, result.selectedEntryID);
  } catch (error) {
    sendOperationMessage(error instanceof Error ? error.message : 'Clipboard capture failed.');
  }
}

async function captureClipboard() {
  const finishIngestion = beginIngestion();
  try {
    const text = clipboard.readText();
    const extracted = await extraction.extractClipboard(text);
    const captureID = await library.captureText(text, extracted);
    const entryID = `personal:${captureID}`;
    const snapshot = await snapshotAndNotify();
    sync.request('the new capture');
    void processCapture(entryID).finally(finishIngestion);
    return {
      snapshot,
      message: 'Captured. Summaries are being prepared in the background.',
      selectedEntryID: entryID
    };
  } catch (error) {
    finishIngestion();
    throw error;
  }
}

async function processCapture(entryID: string): Promise<void> {
  try {
    sendOperationMessage('Processing the new capture…', entryID);
    const processedID = await processing.process(entryID, library);
    await snapshotAndNotify();
    sendOperationMessage('Capture processed and added to the library.', processedID);
    sync.request('processed summaries');
  } catch (error) {
    sendOperationMessage(
      error instanceof Error ? error.message : 'The capture could not be processed.',
      entryID
    );
  }
}

app.whenReady().then(async () => {
  if (process.platform === 'darwin') {
    const dockIcon = nativeImage.createFromPath(applicationIconPath());
    if (!dockIcon.isEmpty()) app.dock?.setIcon(dockIcon);
  }
  settings = new SettingsStore(app.getPath('userData'));
  const saved = await settings.load();
  const savedCaptureShortcut =
    normalizeCaptureShortcut(saved.captureShortcut) ?? defaultCaptureShortcut;
  captureShortcut = savedCaptureShortcut;
  if (!activateCaptureShortcut(savedCaptureShortcut)) {
    captureShortcut = defaultCaptureShortcut;
    activateCaptureShortcut(defaultCaptureShortcut);
  }
  const savedModel = normalizeOpenRouterTTSModel(saved.ttsModel);
  ttsModel = savedModel ?? defaultOpenRouterTTSModel;
  voice = migrateVoiceForTTSModel(ttsModel, savedModel ? saved.voice : undefined);
  if (
    !savedModel ||
    voice !== saved.voice ||
    captureShortcut !== saved.captureShortcut
  ) {
    await settings.update({ ttsModel, voice, captureShortcut });
  }
  library = new LibraryService(
    saved.workspacePath ?? (await defaultWorkspacePath()),
    process.platform,
    (path) => shell.trashItem(path)
  );
  backend = new BackendClient();
  extraction = new ExtractionService(() => library.getWorkspacePath());
  processing = new ProcessingService(async () => {
    const current = await settings.load();
    return current.processingPrompt ?? defaultProcessingPrompt;
  });
  narration = new NarrationService(
    join(app.getPath('userData'), 'audio'),
    backend,
    (segment) => mainWindow?.webContents.send('narration:segment', segment),
    (status) => mainWindow?.webContents.send('narration:status', status)
  );
  protocol.handle('shared-library-audio', (request) => {
    const streamingResponse = narration.responseForURL(request.url);
    if (streamingResponse) return Promise.resolve(streamingResponse);
    const path = narration.pathForURL(request.url);
    return path
      ? net.fetch(pathToFileURL(path).toString())
      : Promise.resolve(new Response('Not found.', { status: 404 }));
  });
  sync = new SyncCoordinator(
    backend,
    library,
    (status) => mainWindow?.webContents.send('sync:status', status),
    async () => {
      await snapshotAndNotify();
    }
  );
  agentApi = new AgentApiServer(
    {
      library,
      extractURL: (url) => extraction.extractClipboard(url),
      processEntry: (entryID, topicID) =>
        processing.process(entryID, library, topicID),
      onLibraryChanged: async () => {
        await snapshotAndNotify();
      },
      onSyncRequested: (reason) => sync.request(reason),
      onOperationMessage: sendOperationMessage,
      onIngestionStarted: beginIngestion
    },
    bundledAgentSkills()
  );
  await agentApi.start();
  registerIPC();
  installMenu();
  await createWindow();
  if (app.isPackaged && !process.windowsStore) {
    void electronUpdater.autoUpdater.checkForUpdatesAndNotify().catch((error) => {
      console.error('Desktop update check failed:', error);
    });
  }
  sync.request('the library', 1500);
  setInterval(() => sync.request('background changes', 100), 5 * 60 * 1000).unref();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) void createWindow();
  });
});

let agentApiStopping = false;
app.on('before-quit', (event) => {
  if (!agentApi || agentApiStopping) return;
  event.preventDefault();
  agentApiStopping = true;
  void agentApi.stop().finally(() => app.quit());
});
app.on('will-quit', () => globalShortcut.unregisterAll());
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
