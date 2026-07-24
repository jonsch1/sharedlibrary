import {
  app,
  BrowserWindow,
  clipboard,
  dialog,
  globalShortcut,
  ipcMain,
  Menu,
  shell
} from 'electron';
import type { MenuItemConstructorOptions, OpenDialogOptions } from 'electron';
import { join } from 'node:path';
import type { LibraryVariant } from '../shared/contracts.js';
import { LibraryService } from './library.js';
import { SettingsStore } from './settings.js';

let mainWindow: BrowserWindow | null = null;
let library: LibraryService;
let settings: SettingsStore;

function defaultWorkspacePath(): string {
  return join(app.getPath('documents'), 'Shared Library');
}

async function snapshotAndNotify() {
  const snapshot = await library.snapshot();
  mainWindow?.webContents.send('library:changed', snapshot);
  return snapshot;
}

async function createWindow(): Promise<void> {
  mainWindow = new BrowserWindow({
    title: 'Shared Library',
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
  mainWindow.once('ready-to-show', () => mainWindow?.show());
  mainWindow.on('closed', () => {
    mainWindow = null;
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
}

function registerIPC(): void {
  ipcMain.handle('library:get-snapshot', () => library.snapshot());
  ipcMain.handle('library:refresh', () => snapshotAndNotify());
  ipcMain.handle('library:choose-workspace', async () => {
    const options: OpenDialogOptions = {
      title: 'Choose your Shared Library workspace',
      properties: ['openDirectory', 'createDirectory']
    };
    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);
    const path = result.filePaths[0];
    if (result.canceled || !path) return null;
    library.setWorkspacePath(path);
    await settings.save({ workspacePath: path });
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
      return {
        snapshot: await snapshotAndNotify(),
        message: 'Document saved.',
        selectedEntryID: entryID
      };
    }
  );
  ipcMain.handle('library:trash-capture', async (_event, entryID: string) => {
    await library.trashCapture(entryID);
    return {
      snapshot: await snapshotAndNotify(),
      message: 'The source and its summaries were moved to Trash.'
    };
  });
  ipcMain.handle('library:capture-clipboard', async () => {
    const captureID = await library.captureText(clipboard.readText());
    const snapshot = await snapshotAndNotify();
    return {
      snapshot,
      message: 'Clipboard captured. Extraction and summary processing will be ported next.',
      selectedEntryID: snapshot.entries.find((entry) => entry.captureID === captureID)?.id
    };
  });
  ipcMain.handle('library:open-external', async (_event, value: string) => {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw new Error('Only web links can be opened.');
    }
    await shell.openExternal(url.toString());
  });
  ipcMain.handle('library:reveal-entry', async (_event, entryID: string) => {
    const snapshot = await library.snapshot();
    const entry = snapshot.entries.find((candidate) => candidate.id === entryID);
    if (!entry) throw new Error('The selected item no longer exists.');
    shell.showItemInFolder(join(library.getWorkspacePath(), 'library', entry.filename));
  });
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
          accelerator: 'CommandOrControl+G',
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
    const captureID = await library.captureText(clipboard.readText());
    const snapshot = await snapshotAndNotify();
    mainWindow?.show();
    mainWindow?.focus();
    mainWindow?.webContents.send('desktop:operation-message', {
      message: 'Clipboard captured.',
      selectedEntryID: snapshot.entries.find((entry) => entry.captureID === captureID)?.id
    });
  } catch (error) {
    mainWindow?.webContents.send('desktop:operation-message', {
      message: error instanceof Error ? error.message : 'Clipboard capture failed.'
    });
  }
}

app.whenReady().then(async () => {
  settings = new SettingsStore(app.getPath('userData'));
  const saved = await settings.load();
  library = new LibraryService(
    saved.workspacePath ?? defaultWorkspacePath(),
    process.platform,
    (path) => shell.trashItem(path)
  );
  registerIPC();
  installMenu();
  await createWindow();
  globalShortcut.register('CommandOrControl+G', () => void captureFromMenu());
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) void createWindow();
  });
});

app.on('will-quit', () => globalShortcut.unregisterAll());
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
