import {
  app,
  BrowserWindow,
  clipboard,
  dialog,
  globalShortcut,
  ipcMain,
  Menu,
  nativeImage,
  powerMonitor,
  protocol,
  shell
} from 'electron';
import type { MenuItemConstructorOptions, OpenDialogOptions } from 'electron';
import type { MessageBoxOptions } from 'electron';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { basename, extname, join } from 'node:path';
import { Readable } from 'node:stream';
import { pathToFileURL } from 'node:url';
import electronUpdater from 'electron-updater';
import {
  promptIDs,
  type AICommandPreferences,
  type AICommandPreferencesUpdate,
  type PromptID,
  type PromptPreferences,
  type PromptPreferenceUpdate,
  type AccountProvider,
  type DesktopAudioPreferences,
  type DesktopConnectionStatus,
  type DesktopIngestionStatus,
  type DesktopShortcutPreferences,
  type LibraryVariant,
  type ProcessingPreferences,
  type ProcessingPreferencesUpdate
} from '../shared/contracts.js';
import {
  defaultCaptureShortcut,
  normalizeCaptureShortcut
} from '../shared/shortcuts.js';
import {
  AgentApiServer,
  type BundledAgentSkill
} from './agent-api.js';
import { BackendClient } from './backend.js';
import { ChannelWorkflowService } from './channel-workflows.js';
import {
  ExtractionService,
  type ExtractedContent
} from './extraction.js';
import { LibraryService } from './library.js';
import {
  agentCommandPresets,
  defaultAgentCommand,
  defaultProcessingCommand,
  defaultProcessingPrompt,
  ensureAgentWorkspacePlaceholder,
  ProcessingService,
  processingCommandPresets,
  renderAgentCommand,
  renderAgentURL,
  resolveAgentCommand,
  runAIText
} from './processing.js';
import {
  defaultPodcastPrompt,
  podcastAudioRange,
  PodcastService
} from './podcasts.js';
import { SettingsStore } from './settings.js';
import { isTrustedRendererURL, isWebURL } from './security.js';
import { SyncCoordinator } from './sync.js';

app.setName('Briefly');
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'briefly-podcast-audio',
    privileges: {
      secure: true,
      standard: true,
      stream: true,
      supportFetchAPI: true,
      corsEnabled: true
    }
  },
  {
    scheme: 'briefly-favicon',
    privileges: {
      secure: true,
      standard: true,
      supportFetchAPI: true,
      corsEnabled: true
    }
  }
]);
// Preserve the existing profile so the rebrand keeps settings and sessions.
if (
  !process.env.BRIEFLY_E2E_USER_DATA &&
  !process.env.SHARED_LIBRARY_E2E_USER_DATA
) {
  app.setPath('userData', join(app.getPath('appData'), 'shared-library-electron'));
}

let mainWindow: BrowserWindow | null = null;
let agentApi: AgentApiServer;
let library: LibraryService;
let settings: SettingsStore;
let backend: BackendClient;
let extraction: ExtractionService;
let channelWorkflows: ChannelWorkflowService;
let processing: ProcessingService;
let podcasts: PodcastService;
let sync: SyncCoordinator;
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
  return [
    {
      name: 'briefly-deep-research',
      sourcePath: join(root, 'briefly-deep-research')
    },
    {
      name: 'briefly-input-extension',
      sourcePath: join(root, 'briefly-input-extension')
    },
    {
      name: 'briefly-audio-briefing',
      sourcePath: join(root, 'briefly-audio-briefing')
    }
  ];
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

async function audioPreferences(): Promise<DesktopAudioPreferences> {
  return {
    saveCapturedAudio: (await settings.load()).saveCapturedAudio !== false
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
  const [google, icloud, billing] = account.authenticated
    ? await Promise.all([
        backend.providerStatus('google'),
        backend.providerStatus('icloud'),
        backend.billingStatus()
      ])
    : [
        { configured: true, connected: false },
        { configured: false, connected: false },
        { entitled: false }
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
    sync: sync.currentStatus()
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

async function promptPreferences(): Promise<PromptPreferences> {
  const saved = await settings.load();
  return {
    prompts: [
      {
        id: 'summarization',
        title: 'Summarization',
        description: 'Creates every summary depth and assigns a topic to captured sources.',
        prompt: saved.processingPrompt ?? defaultProcessingPrompt,
        defaultPrompt: defaultProcessingPrompt,
        requiredPlaceholders: ['{{topics}}', '{{source}}']
      },
      {
        id: 'podcast',
        title: 'Audio brief',
        description: 'Turns new channel items into an audio brief script.',
        prompt: saved.podcastPrompt ?? defaultPodcastPrompt,
        defaultPrompt: defaultPodcastPrompt,
        requiredPlaceholders: [
          '{{podcast_title}}',
          '{{requested_length}}',
          '{{source_packets}}'
        ]
      }
    ]
  };
}

async function aiCommandPreferences(): Promise<AICommandPreferences> {
  const saved = await settings.load();
  return {
    defaultProcessingCommand,
    processingCommand: saved.processingCommand ?? defaultProcessingCommand,
    agentCommand: ensureAgentWorkspacePlaceholder(
      resolveAgentCommand(saved.agentCommand)
    ),
    processingPresets: processingCommandPresets,
    agentPresets: agentCommandPresets
  };
}

function normalizeAICommandPreferences(value: unknown): AICommandPreferencesUpdate {
  if (!value || typeof value !== 'object') {
    throw new Error('AI command settings are invalid.');
  }
  const candidate = value as Partial<AICommandPreferencesUpdate>;
  const processingCommand =
    typeof candidate.processingCommand === 'string'
      ? candidate.processingCommand.trim()
      : '';
  const agentCommand =
    typeof candidate.agentCommand === 'string' ? candidate.agentCommand.trim() : '';
  if (!processingCommand || !agentCommand) {
    throw new Error('AI commands cannot be empty.');
  }
  if (processingCommand.length > 4_000 || agentCommand.length > 4_000) {
    throw new Error('AI commands must be 4,000 characters or fewer.');
  }
  return {
    processingCommand,
    agentCommand: ensureAgentWorkspacePlaceholder(agentCommand)
  };
}

function normalizePromptPreferenceUpdate(value: unknown): PromptPreferenceUpdate {
  if (!value || typeof value !== 'object') throw new Error('Prompt settings are invalid.');
  const candidate = value as Partial<PromptPreferenceUpdate>;
  if (!promptIDs.includes(candidate.id as PromptID)) {
    throw new Error('The selected prompt does not exist.');
  }
  const prompt = typeof candidate.prompt === 'string' ? candidate.prompt.trim() : '';
  if (!prompt) throw new Error('The prompt cannot be empty.');
  if (prompt.length > 50_000) throw new Error('Prompts must be 50,000 characters or fewer.');
  const required: Record<PromptID, string[]> = {
    summarization: ['{{topics}}', '{{source}}'],
    podcast: ['{{podcast_title}}', '{{requested_length}}', '{{source_packets}}']
  };
  const missing = required[candidate.id as PromptID].find(
    (placeholder) => !prompt.includes(placeholder)
  );
  if (missing) throw new Error(`The ${candidate.id} prompt must include ${missing}.`);
  return { id: candidate.id as PromptID, prompt };
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
  const rendererEntryURL =
    process.env.ELECTRON_RENDERER_URL ||
    pathToFileURL(join(__dirname, '../renderer/index.html')).toString();
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
    if (isWebURL(url)) void shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (isTrustedRendererURL(url, rendererEntryURL)) return;
    event.preventDefault();
    if (isWebURL(url)) void shell.openExternal(url);
  });

  await mainWindow.loadURL(rendererEntryURL);
  updateIngestionPresentation();
}

function registerIPC(): void {
  const handle: typeof ipcMain.handle = (channel, listener) => {
    ipcMain.handle(channel, (event, ...args) => {
      if (
        !mainWindow ||
        event.sender !== mainWindow.webContents ||
        event.senderFrame !== mainWindow.webContents.mainFrame
      ) {
        throw new Error('This desktop request did not come from the Briefly app.');
      }
      return listener(event, ...args);
    });
  };

  handle('library:get-snapshot', () => library.snapshot());
  handle('library:refresh', () => snapshotAndNotify());
  handle('library:choose-workspace', async () => {
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
    const podcastSnapshot = await podcasts.snapshot();
    const snapshot = await snapshotAndNotify();
    mainWindow?.webContents.send('podcasts:changed', podcastSnapshot);
    podcasts.wake();
    return snapshot;
  });
  handle(
    'library:read-text',
    (_event, entryID: string, variant: LibraryVariant) =>
      library.readText(entryID, variant)
  );
  handle(
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
  handle('library:trash-capture', async (_event, entryID: string) => {
    await library.trashCapture(entryID);
    sync.request('deleted documents');
    return {
      snapshot: await snapshotAndNotify(),
      message: 'The source, its audio, and summaries were moved to Trash.'
    };
  });
  handle('library:capture-clipboard', () => captureClipboard());
  handle('library:capture-pdf', (_event, path: unknown) => capturePDF(path));
  handle('library:open-external', async (_event, value: string) => {
    if (!isWebURL(value)) {
      throw new Error('Only web links can be opened.');
    }
    await shell.openExternal(new URL(value).toString());
  });
  handle('library:open-agent', () => openAgentWorkspace());
  handle('library:reveal-entry', async (_event, entryID: string) => {
    const snapshot = await library.snapshot();
    const entry = snapshot.entries.find((candidate) => candidate.id === entryID);
    if (!entry) throw new Error('The selected item no longer exists.');
    shell.showItemInFolder(join(library.getWorkspacePath(), 'library', entry.filename));
  });
  handle(
    'library:show-entry-context-menu',
    async (
      event,
      entryIDs: unknown,
      variant: LibraryVariant | undefined
    ) => {
      const snapshot = await library.snapshot();
      if (
        !Array.isArray(entryIDs) ||
        entryIDs.length === 0 ||
        entryIDs.some((entryID) => typeof entryID !== 'string')
      ) {
        throw new Error('No valid library items were selected.');
      }
      const selectedIDs = [...new Set(entryIDs as string[])];
      const entries = selectedIDs.map((entryID) =>
        snapshot.entries.find((candidate) => candidate.id === entryID)
      );
      if (entries.some((entry) => !entry)) {
        throw new Error('A selected item no longer exists.');
      }
      const paths = await Promise.all(
        selectedIDs.map((entryID) => library.filePath(entryID, variant))
      );
      const window = BrowserWindow.fromWebContents(event.sender) ?? undefined;
      const menu = Menu.buildFromTemplate([
        {
          label: selectedIDs.length === 1 ? 'Copy Path' : 'Copy Paths',
          click: () => {
            clipboard.writeText(paths.join('\n'));
            sendOperationMessage(selectedIDs.length === 1 ? 'Path copied.' : 'Paths copied.');
          }
        },
        { type: 'separator' },
        {
          label:
            selectedIDs.length === 1
              ? 'Move to Trash…'
              : `Move ${selectedIDs.length} Items to Trash…`,
          click: () =>
            void trashEntriesFromContextMenu(
              selectedIDs,
              entries.map((entry) => entry!.title)
            )
        }
      ]);
      menu.popup({ window });
    }
  );
  handle('services:get-status', () => connectionStatus());
  handle(
    'services:sign-in',
    async (_event, provider: AccountProvider) => {
      if (provider !== 'google' && provider !== 'apple') {
        throw new Error('Unknown account provider.');
      }
      await backend.signIn(provider, mainWindow);
      return connectionStatus();
    }
  );
  handle(
    'services:manage-account',
    async () => {
      await backend.manageAccount(mainWindow);
      await sync.synchronize('account settings');
      return connectionStatus();
    }
  );
  handle('services:sync-now', async () => {
    await sync.synchronize('the library');
    return connectionStatus();
  });
  handle('shortcuts:get-preferences', () => shortcutPreferences());
  handle('shortcuts:set-capture', async (_event, value: unknown) => {
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
  handle('audio:get-preferences', () => audioPreferences());
  handle('audio:set-save-captured', async (_event, value: unknown) => {
    if (typeof value !== 'boolean') throw new Error('Choose whether to save audio.');
    await settings.update({ saveCapturedAudio: value });
    return audioPreferences();
  });
  handle('personalization:get-about-you', async () => {
    const value = (await settings.load()).aboutYou;
    return typeof value === 'string' ? value : '';
  });
  handle('personalization:set-about-you', async (_event, value: unknown) => {
    if (typeof value !== 'string') throw new Error('Personal context is invalid.');
    const aboutYou = value.trim();
    if (aboutYou.length > 10_000) {
      throw new Error('Personal context must be 10,000 characters or fewer.');
    }
    await settings.update({ aboutYou });
    return aboutYou;
  });
  handle('ingestion:get-status', () => ingestionStatus());
  handle('processing:get-preferences', () => processingPreferences());
  handle(
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
  handle('prompts:get', () => promptPreferences());
  handle('prompts:update', async (_event, value: unknown) => {
    const next = normalizePromptPreferenceUpdate(value);
    const key: Record<PromptID, keyof import('./settings.js').DesktopSettings> = {
      summarization: 'processingPrompt',
      podcast: 'podcastPrompt'
    };
    await settings.update({ [key[next.id]]: next.prompt });
    return promptPreferences();
  });
  handle('ai-commands:get', () => aiCommandPreferences());
  handle('ai-commands:update', async (_event, value: unknown) => {
    const next = normalizeAICommandPreferences(value);
    await settings.update(next);
    return aiCommandPreferences();
  });
  handle('ai-commands:test-processing', async (_event, value: unknown) => {
    if (typeof value !== 'string' || !value.trim() || value.length > 4_000) {
      throw new Error('The AI command is invalid.');
    }
    const output = await runAIText(
      'Reply with exactly: Briefly is ready.',
      value,
      (prompt, format) => backend.runManagedAI(prompt, format)
    );
    if (!/Briefly is ready/i.test(output)) {
      throw new Error('The command ran, but returned an unexpected response.');
    }
  });
  handle('podcasts:get', () => podcasts.snapshot());
  handle('podcasts:save', (_event, value) => podcasts.save(value));
  handle('podcasts:remove', (_event, id: string) => podcasts.remove(id));
  handle('podcasts:check', (_event, id: string) => podcasts.check(id));
  handle('podcasts:run', (_event, id: string) => podcasts.run(id));
  handle('podcasts:reveal', async (_event, id: string) => {
    shell.showItemInFolder(await podcasts.filePath(id));
  });
  handle('channels:add', (_event, source: string) =>
    podcasts.addChannel(source)
  );
  handle('channels:check', (_event, source: string) =>
    podcasts.checkChannel(source)
  );
  handle('channels:update', (_event, source: string, retrievalCount: number) =>
    podcasts.updateChannel(source, retrievalCount)
  );
  handle('channels:load-more', (_event, source: string) =>
    podcasts.loadMoreChannel(source)
  );
  handle('channels:remove', (_event, source: string) =>
    podcasts.removeChannel(source)
  );
  handle('channels:login', (_event, url: string) =>
    channelWorkflows.login(mainWindow, url)
  );
  handle('sharing:get', async (_event, entryID: string) => {
    const entry = await entryForID(entryID);
    return backend.shareStatus(entry.captureID);
  });
  handle(
    'sharing:publish',
    async (_event, entryID: string) => {
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
                  if (text.variant === 'source') return [];
                  const markdown = files.get(text.path);
                  return markdown === undefined ? [] : [{ variant: text.variant, markdown }];
                })
              };
            })()
          : undefined;
      let result = await backend.publishShare(
        entry.captureID,
        source
      );
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
  handle('sharing:revoke', async (_event, token: string) => {
    if (!/^[A-Za-z0-9_-]{32}$/.test(token)) throw new Error('Invalid share link.');
    await backend.revokeShare(token);
  });
}

async function openAgentWorkspace(): Promise<void> {
  const workspacePath = library.getWorkspacePath();
  const agentCommand = resolveAgentCommand((await settings.load()).agentCommand);
  const agentURL = renderAgentURL(agentCommand, workspacePath);
  if (agentURL) {
    await shell.openExternal(agentURL);
    return;
  }
  if (process.platform === 'darwin') {
    await new Promise<void>((resolve, reject) => {
      const directChatGPTLaunch = agentCommand === defaultAgentCommand;
      const child = directChatGPTLaunch
        ? spawn('/usr/bin/open', ['-a', 'ChatGPT', workspacePath], {
            detached: true,
            stdio: 'ignore'
          })
        : spawn(
            '/usr/bin/osascript',
            [
              '-e',
              [
                'tell application "Terminal"',
                'activate',
                `do script ${JSON.stringify(renderAgentCommand(agentCommand, workspacePath))}`,
                'end tell'
              ].join('\n')
            ],
            {
              detached: true,
              stdio: 'ignore'
            }
          );
      child.once('error', reject);
      child.once('spawn', () => {
        child.unref();
        resolve();
      });
    });
    return;
  }
  const command = renderAgentCommand(agentCommand, workspacePath);
  const child =
    process.platform === 'win32'
      ? spawn(
          'cmd.exe',
          ['/c', 'start', 'Briefly agent', 'cmd.exe', '/k', command],
          { cwd: workspacePath, detached: true, stdio: 'ignore' }
        )
      : spawn(
          process.env.TERMINAL || 'x-terminal-emulator',
          ['-e', 'sh', '-lc', command],
          { cwd: workspacePath, detached: true, stdio: 'ignore' }
        );
  await new Promise<void>((resolve, reject) => {
    child.once('error', reject);
    child.once('spawn', () => {
      child.unref();
      resolve();
    });
  });
}

async function trashEntriesFromContextMenu(
  entryIDs: string[],
  titles: string[]
): Promise<void> {
  const count = entryIDs.length;
  const options: MessageBoxOptions = {
    type: 'warning',
    buttons: ['Cancel', 'Move to Trash'],
    defaultId: 0,
    cancelId: 0,
    message:
      count === 1
        ? `Move “${titles[0]}” to Trash?`
        : `Move ${count} documents to Trash?`,
    detail:
      count === 1
        ? 'The source document and all of its summaries will be moved together.'
        : 'Each source document and all of its summaries will be moved together.'
  };
  const response = mainWindow
    ? await dialog.showMessageBox(mainWindow, options)
    : await dialog.showMessageBox(options);
  if (response.response !== 1) return;
  try {
    for (const entryID of entryIDs) await library.trashCapture(entryID);
    sync.request('deleted documents');
    await snapshotAndNotify();
    sendOperationMessage(
      count === 1
        ? 'The source and its summaries were moved to Trash.'
        : `${count} documents and their summaries were moved to Trash.`
    );
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
  const text = clipboard.readText();
  const preferences = await audioPreferences();
  return captureText(
    text,
    await extraction.extractClipboard(text, preferences.saveCapturedAudio)
  );
}

async function capturePDF(path: unknown) {
  const extracted = await extraction.extractPDFFile(path);
  return captureText(
    extracted.title ?? basename(typeof path === 'string' ? path : 'PDF'),
    extracted
  );
}

async function captureText(text: string, extracted?: ExtractedContent) {
  const finishIngestion = beginIngestion();
  try {
    const stored =
      extracted && !(await audioPreferences()).saveCapturedAudio
        ? { ...extracted, audio: undefined }
        : extracted;
    const captureID = await library.captureText(text, stored);
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
  if (captureShortcut !== saved.captureShortcut) {
    await settings.update({ captureShortcut });
  }
  library = new LibraryService(
    saved.workspacePath ?? (await defaultWorkspacePath()),
    process.platform,
    (path) => shell.trashItem(path)
  );
  protocol.handle('briefly-podcast-audio', async (request) => {
    try {
      const filename = new URL(request.url).pathname.split('/').at(-1) ?? '';
      if (!filename.endsWith('.wav')) throw new Error('Invalid audio path.');
      const entryID = decodeURIComponent(filename.slice(0, -4));
      const audioPath = await library.podcastAudioPath(entryID);
      const contentTypes: Record<string, string> = {
        '.aac': 'audio/aac',
        '.flac': 'audio/flac',
        '.m4a': 'audio/mp4',
        '.mp3': 'audio/mpeg',
        '.ogg': 'audio/ogg',
        '.opus': 'audio/ogg',
        '.wav': 'audio/wav',
        '.webm': 'audio/webm'
      };
      const contentType = contentTypes[extname(audioPath).toLowerCase()];
      if (!contentType) throw new Error('Unsupported audio type.');
      const size = (await stat(audioPath)).size;
      const rangeHeader = request.headers.get('range')?.trim() || null;
      const range = podcastAudioRange(rangeHeader, size);
      if (!range) {
        return new Response(null, {
          status: 416,
          headers: {
            'Accept-Ranges': 'bytes',
            'Content-Range': `bytes */${size}`
          }
        });
      }
      const partial = rangeHeader !== null;
      return new Response(
        Readable.toWeb(
          createReadStream(audioPath, { start: range.start, end: range.end })
        ) as unknown as BodyInit,
        {
          status: partial ? 206 : 200,
          headers: {
            'Accept-Ranges': 'bytes',
            'Content-Length': String(range.end - range.start + 1),
            'Content-Type': contentType,
            ...(partial
              ? { 'Content-Range': `bytes ${range.start}-${range.end}/${size}` }
              : {})
          }
        }
      );
    } catch {
      return new Response('Not found.', { status: 404 });
    }
  });
  protocol.handle('briefly-favicon', async (request) => {
    try {
      const filename = new URL(request.url).pathname.split('/').at(-1) ?? '';
      const extension = filename.split('.').at(-1) ?? '';
      const contentTypes: Record<string, string> = {
        gif: 'image/gif',
        ico: 'image/x-icon',
        jpg: 'image/jpeg',
        png: 'image/png',
        webp: 'image/webp'
      };
      const contentType = contentTypes[extension];
      if (!contentType) throw new Error('Invalid favicon path.');
      return new Response(await readFile(await library.faviconPath(filename)), {
        headers: {
          'Cache-Control': 'public, max-age=31536000, immutable',
          'Content-Type': contentType
        }
      });
    } catch {
      return new Response('Not found.', { status: 404 });
    }
  });
  backend = new BackendClient();
  extraction = new ExtractionService(
    () => library.getWorkspacePath(),
    () => backend.transcriptCredentials(),
    () => backend.firecrawlCredentials()
  );
  processing = new ProcessingService(
    async () => {
      const current = await settings.load();
      return current.processingPrompt ?? defaultProcessingPrompt;
    },
    async () =>
      (await settings.load()).processingCommand ?? defaultProcessingCommand,
    (prompt, format) => backend.runManagedAI(prompt, format)
  );
  channelWorkflows = new ChannelWorkflowService(extraction);
  podcasts = new PodcastService(
    () => library.getWorkspacePath(),
    library,
    channelWorkflows,
    (text) => backend.generatePodcastAudio(text),
    (path) => shell.trashItem(path),
    (snapshot) => mainWindow?.webContents.send('podcasts:changed', snapshot),
    async () => {
      await snapshotAndNotify();
    },
    (reason) => sync.request(reason),
    sendOperationMessage,
    beginIngestion,
    async () => (await settings.load()).podcastPrompt ?? defaultPodcastPrompt,
    async () =>
      (await settings.load()).processingCommand ?? defaultProcessingCommand,
    (prompt, format) => backend.runManagedAI(prompt, format),
    async () => {
      const value = (await settings.load()).aboutYou;
      return typeof value === 'string' ? value : '';
    }
  );
  sync = new SyncCoordinator(
    backend,
    library,
    (status) => mainWindow?.webContents.send('sync:status', status),
    async () => {
      await snapshotAndNotify();
      podcasts?.wake();
    }
  );
  agentApi = new AgentApiServer(
    {
      library,
      extractURL: (url) => extraction.extractURL(url),
      processEntry: (entryID, topicID) =>
        processing.process(entryID, library, topicID),
      podcastSnapshot: () => podcasts.snapshot(),
      createPodcastEpisode: (podcastID, script, sources) =>
        podcasts.createAgentEpisode(podcastID, script, sources),
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
  podcasts.start();
  powerMonitor.on('resume', () => podcasts.wake());
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
  podcasts?.stop();
  if (!agentApi || agentApiStopping) return;
  event.preventDefault();
  agentApiStopping = true;
  void agentApi.stop().finally(() => app.quit());
});
app.on('will-quit', () => globalShortcut.unregisterAll());
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
