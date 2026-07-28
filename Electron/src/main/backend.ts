import { BrowserWindow, session } from 'electron';
import type {
  AccountProvider,
  ConnectionProvider,
  LibraryVariant,
  ShareLinkStatus
} from '../shared/contracts.js';
import type {
  DriveLibraryFile,
  DriveLibraryIndex,
  DriveLibraryMedia,
  DriveLibraryMirror
} from './library.js';
import type { LibraryMedia } from '../../../Shared/library.js';

const backendOrigin = 'https://www.readbriefly.fyi';
const podcastSpeechEndpoint = 'https://jonsch1--briefly-kokoro-speech.modal.run';
const transcriptEndpoint = 'https://jonsch1--briefly-whisper-transcribe.modal.run';
const firecrawlEndpoint = `${backendOrigin}/api/extraction/firecrawl`;

interface AccountStatus {
  authenticated: boolean;
  email?: string;
  syncProvider?: ConnectionProvider | null;
  providers?: {
    google?: boolean;
    apple?: boolean;
  };
  google?: {
    configured?: boolean;
    connected?: boolean;
    connectedAt?: string;
    folderID?: string;
  };
  icloud?: {
    configured?: boolean;
    connected?: boolean;
  };
}

export interface ShareLinkSource {
  filename: string;
  title: string;
  excerpt: string;
  topicIDs: string[];
  topicNames: string[];
  tags: string[];
  sourceURL?: string;
  createdAt?: string;
  updatedAt?: string;
  texts: Array<{ variant: LibraryVariant; markdown: string }>;
}

export class BackendClient {
  private bridgeWindow: BrowserWindow | null = null;
  private activeSyncProvider: ConnectionProvider | null = null;

  async accountStatus(): Promise<AccountStatus> {
    const response = await this.fetch('/api/auth/status');
    if (!response.ok) return { authenticated: false };
    const value = (await response.json()) as AccountStatus;
    this.activeSyncProvider = value.syncProvider ?? null;
    return value;
  }

  currentSyncProvider(): ConnectionProvider | null {
    return this.activeSyncProvider;
  }

  async providerStatus(provider: ConnectionProvider): Promise<Record<string, unknown>> {
    if (provider === 'icloud') {
      const account = await this.accountStatus();
      const configured = account.icloud?.configured === true;
      const connected =
        configured &&
        account.syncProvider === 'icloud' &&
        (await this.callICloud<boolean>('status').catch(() => false));
      return { configured, connected };
    }
    const response = await this.fetch('/api/google/status');
    if (response.status === 401) return { connected: false };
    return this.json(response, 'Could not read the Google connection.');
  }

  async billingStatus(): Promise<Record<string, unknown>> {
    const response = await this.fetch('/api/billing/status');
    return this.json(response, 'Could not read the Briefly account.');
  }

  async runManagedAI(prompt: string, format: 'json' | 'text'): Promise<string> {
    const response = await this.fetch('/api/ai/process', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt, format })
    });
    const value = await this.json<{ output?: unknown }>(
      response,
      'Briefly AI could not process this request.'
    );
    if (typeof value.output !== 'string' || !value.output.trim()) {
      throw new Error('Briefly AI returned no output.');
    }
    return value.output;
  }

  async generatePodcastAudio(text: string): Promise<Uint8Array> {
    const [cookie] = await session.defaultSession.cookies.get({
      url: backendOrigin,
      name: 'shared_library_session'
    });
    if (!cookie?.value) throw new Error('Sign in to Briefly to generate podcast audio.');
    const response = await session.defaultSession.fetch(podcastSpeechEndpoint, {
      method: 'POST',
      headers: {
        Accept: 'audio/wav',
        Authorization: `Bearer ${cookie.value}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ text })
    });
    if (!response.ok) {
      throw new Error(
        await this.errorMessage(response, 'Podcast audio could not be generated.')
      );
    }
    const audio = new Uint8Array(await response.arrayBuffer());
    if (
      audio.length < 44 ||
      new TextDecoder().decode(audio.subarray(0, 4)) !== 'RIFF' ||
      new TextDecoder().decode(audio.subarray(8, 12)) !== 'WAVE'
    ) {
      throw new Error('Podcast audio service returned an invalid WAV file.');
    }
    return audio;
  }

  async transcriptCredentials(): Promise<
    { endpoint: string; token: string } | undefined
  > {
    const [cookie] = await session.defaultSession.cookies.get({
      url: backendOrigin,
      name: 'shared_library_session'
    });
    return cookie?.value
      ? { endpoint: transcriptEndpoint, token: cookie.value }
      : undefined;
  }

  async firecrawlCredentials(): Promise<
    { endpoint: string; token: string } | undefined
  > {
    const [cookie] = await session.defaultSession.cookies.get({
      url: backendOrigin,
      name: 'shared_library_session'
    });
    return cookie?.value
      ? { endpoint: firecrawlEndpoint, token: cookie.value }
      : undefined;
  }

  async signIn(provider: AccountProvider, parent: BrowserWindow | null): Promise<void> {
    await this.openProviderWindow(
      `/api/auth/${provider}/start?return_to=%2F%3Fdesktop%3D1`,
      provider,
      'signed-in',
      `Sign in with ${provider === 'apple' ? 'Apple' : 'Google'}`,
      parent
    );
  }

  async manageAccount(parent: BrowserWindow | null): Promise<void> {
    const window = new BrowserWindow({
      parent: parent ?? undefined,
      modal: Boolean(parent),
      title: 'Briefly account',
      width: 860,
      height: 760,
      minWidth: 560,
      minHeight: 600,
      backgroundColor: '#f3f1e9',
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true
      }
    });
    window.webContents.setWindowOpenHandler(() => ({
      action: 'allow',
      overrideBrowserWindowOptions: {
        parent: window,
        modal: true,
        width: 560,
        height: 720,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true
        }
      }
    }));
    try {
      await window.loadURL(`${backendOrigin}/account?desktop=1#sync`);
      await new Promise<void>((resolve) => window.once('closed', resolve));
    } catch (error) {
      if (!window.isDestroyed()) window.destroy();
      throw error;
    } finally {
      this.destroyBridgeWindow();
    }
  }

  async signOut(): Promise<void> {
    const response = await this.fetch('/api/auth/logout', { method: 'POST' });
    await this.json(response, 'Could not sign out.');
    this.activeSyncProvider = null;
    this.destroyBridgeWindow();
  }

  async fetchLibraryIndex(
    provider: ConnectionProvider
  ): Promise<DriveLibraryIndex | null> {
    if (provider === 'icloud') {
      return this.callICloud<DriveLibraryIndex | null>('fetchLibraryIndex');
    }
    const response = await this.fetch('/api/library', {
      headers: { Accept: 'application/json' }
    });
    if (response.status === 404) return null;
    return this.json(response, 'Could not read the library from Google Drive.');
  }

  async fetchLibraryFile(
    file: DriveLibraryFile,
    provider: ConnectionProvider
  ): Promise<string> {
    if (provider === 'icloud') {
      return this.callICloud<string>('fetchLibraryFile', [file]);
    }
    const parameters = new URLSearchParams({
      path: file.path,
      hash: file.contentHash
    });
    const response = await this.fetch(`/api/library/file?${parameters.toString()}`, {
      headers: { Accept: 'text/markdown, text/plain' }
    });
    if (!response.ok) {
      throw new Error(await this.errorMessage(response, `Could not download ${file.path}.`));
    }
    return response.text();
  }

  async fetchLibraryMedia(
    media: LibraryMedia,
    provider: ConnectionProvider
  ): Promise<Uint8Array> {
    if (provider === 'icloud') {
      const content = await this.callICloud<string>('fetchLibraryMedia', [media]);
      return new Uint8Array(Buffer.from(content, 'base64'));
    }
    const response = await this.fetch(
      `/api/media/${media.kind}/${media.contentHash}`,
      { headers: { Accept: media.contentType } }
    );
    if (!response.ok) {
      throw new Error(await this.errorMessage(response, `Could not download ${media.path}.`));
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  async uploadLibrary(mirror: DriveLibraryMirror, provider: ConnectionProvider): Promise<{
    changed: number;
    syncedAt: string;
  }> {
    if (provider === 'icloud') {
      return this.callICloud<{ changed: number; syncedAt: string }>('uploadLibrary', [mirror]);
    }
    let uploadedMedia = 0;
    for (const media of mirror.media) {
      const result = await this.uploadMedia(media);
      if (!result.existed) uploadedMedia += 1;
    }
    const response = await this.fetch('/api/library/sync', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        schemaVersion: 2,
        index: mirror.index,
        files: mirror.files,
        media: mirror.media.map(({ content: _, ...media }) => media)
      })
    });
    const result = await this.json<{ changed: number; syncedAt: string }>(
      response,
      'Could not synchronize the library with Google Drive.'
    );
    return { ...result, changed: result.changed + uploadedMedia };
  }

  async shareStatus(captureID: string): Promise<ShareLinkStatus> {
    const response = await this.fetch(
      `/api/share-links?captureID=${encodeURIComponent(captureID)}`
    );
    return this.json(response, 'Could not read the share link.');
  }

  async publishShare(
    captureID: string,
    source?: ShareLinkSource
  ): Promise<ShareLinkStatus> {
    const response = await this.fetch('/api/share-links', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ captureID, source })
    });
    return this.json(response, 'Could not create the share link.');
  }

  async revokeShare(token: string): Promise<void> {
    const response = await this.fetch(`/api/share-links/${encodeURIComponent(token)}`, {
      method: 'DELETE'
    });
    await this.json(response, 'Could not revoke the share link.');
  }

  private async uploadMedia(media: DriveLibraryMedia): Promise<{ existed: boolean }> {
    const response = await this.fetch(
      `/api/media/${media.kind}/${media.contentHash}`,
      {
        method: 'PUT',
        headers: { 'Content-Type': media.contentType },
        body: Buffer.from(media.content, 'base64')
      }
    );
    return this.json(response, `Could not upload ${media.path}.`);
  }

  private async openProviderWindow(
    path: string,
    resultParameter: 'google' | 'apple' | 'icloud',
    successfulResult: 'signed-in' | 'connected',
    title: string,
    parent: BrowserWindow | null
  ): Promise<void> {
    const window = new BrowserWindow({
      parent: parent ?? undefined,
      modal: Boolean(parent),
      title,
      width: 560,
      height: 720,
      minWidth: 420,
      minHeight: 560,
      backgroundColor: '#f3f1e9',
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true
      }
    });
    window.webContents.setWindowOpenHandler(() => ({
      action: 'allow',
      overrideBrowserWindowOptions: {
        parent: window,
        modal: true,
        width: 560,
        height: 720,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true
        }
      }
    }));

    await new Promise<void>((resolve, reject) => {
      let completed = false;
      const finish = (error?: Error) => {
        if (completed) return;
        completed = true;
        if (!window.isDestroyed()) window.close();
        if (error) reject(error);
        else resolve();
      };
      const inspect = (value: string) => {
        try {
          const url = new URL(value);
          if (url.origin !== backendOrigin) return;
          const result = url.searchParams.get(resultParameter);
          if (!result) return;
          if (result === successfulResult) finish();
          else if (result === 'expired') {
            finish(new Error(`${title} expired.`));
          } else {
            finish(new Error(`${title} failed.`));
          }
        } catch {
          // OAuth navigates across several unrelated origins.
        }
      };
      window.webContents.on('will-redirect', (_event, url) => inspect(url));
      window.webContents.on('did-navigate', (_event, url) => inspect(url));
      window.webContents.on('did-navigate-in-page', (_event, url) => inspect(url));
      window.on('closed', () => {
        if (!completed) finish(new Error('Sign-in was cancelled.'));
      });
      void window.loadURL(`${backendOrigin}${path}`).catch((error) => {
        finish(error instanceof Error ? error : new Error(`${title} could not be opened.`));
      });
    });
  }

  private async iCloudBridge(): Promise<BrowserWindow> {
    if (this.bridgeWindow && !this.bridgeWindow.isDestroyed()) return this.bridgeWindow;
    const window = new BrowserWindow({
      show: false,
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        backgroundThrottling: false
      }
    });
    this.bridgeWindow = window;
    window.on('closed', () => {
      if (this.bridgeWindow === window) this.bridgeWindow = null;
    });
    await window.loadURL(`${backendOrigin}/icloud?bridge=1`);
    await window.webContents.executeJavaScript(`
      new Promise((resolve, reject) => {
        const started = Date.now();
        const timer = setInterval(() => {
          if (window.brieflyICloud) {
            clearInterval(timer);
            resolve(true);
          } else if (Date.now() - started > 10000) {
            clearInterval(timer);
            reject(new Error('The iCloud bridge did not start.'));
          }
        }, 25);
      })
    `);
    return window;
  }

  private async callICloud<T>(method: string, arguments_: unknown[] = []): Promise<T> {
    const window = await this.iCloudBridge();
    return window.webContents.executeJavaScript(
      `window.brieflyICloud.${method}(...${JSON.stringify(arguments_)})`,
      true
    ) as Promise<T>;
  }

  private destroyBridgeWindow(): void {
    if (this.bridgeWindow && !this.bridgeWindow.isDestroyed()) this.bridgeWindow.destroy();
    this.bridgeWindow = null;
  }

  private fetch(path: string, init: RequestInit = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set('Accept', headers.get('Accept') ?? 'application/json');
    headers.set('Origin', backendOrigin);
    return session.defaultSession.fetch(`${backendOrigin}${path}`, {
      ...init,
      headers,
      credentials: 'include',
      cache: 'no-store'
    });
  }

  private async json<T>(response: Response, fallback: string): Promise<T> {
    if (!response.ok) throw new Error(await this.errorMessage(response, fallback));
    return response.json() as Promise<T>;
  }

  private async errorMessage(response: Response, fallback: string): Promise<string> {
    try {
      const value = (await response.json()) as {
        error?: string | { message?: string };
        message?: string;
      };
      if (typeof value.error === 'string') return value.error;
      if (typeof value.error?.message === 'string') return value.error.message;
      if (typeof value.message === 'string') return value.message;
    } catch {
      // The response was not JSON.
    }
    return `${fallback} (${response.status})`;
  }
}

export { backendOrigin };
