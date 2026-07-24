import { BrowserWindow, session } from 'electron';
import type {
  ConnectionProvider,
  OpenRouterVoice,
  ShareLinkStatus
} from '../shared/contracts.js';
import type {
  DriveLibraryFile,
  DriveLibraryIndex,
  DriveLibraryMirror
} from './library.js';

const backendOrigin = 'https://shared-library-jschaul.schauljonathan.chatgpt.site';

interface AccountStatus {
  authenticated: boolean;
  email?: string;
  google?: {
    configured?: boolean;
    connected?: boolean;
    connectedAt?: string;
    folderID?: string;
  };
  openrouter?: {
    connected?: boolean;
    connectedAt?: string;
    userID?: string;
  };
}

export class BackendClient {
  async accountStatus(): Promise<AccountStatus> {
    const response = await this.fetch('/api/auth/status');
    if (!response.ok) return { authenticated: false };
    return response.json() as Promise<AccountStatus>;
  }

  async providerStatus(provider: ConnectionProvider): Promise<Record<string, unknown>> {
    const path =
      provider === 'google' ? '/api/google/status' : '/api/openrouter/status';
    const response = await this.fetch(path);
    if (response.status === 401) return { connected: false };
    return this.json(response, `Could not read the ${provider} connection.`);
  }

  async connect(provider: ConnectionProvider, parent: BrowserWindow | null): Promise<void> {
    if (provider === 'openrouter') {
      const status = await this.accountStatus();
      if (!status.authenticated) {
        await this.openConnectionWindow('google', parent);
      }
    }
    await this.openConnectionWindow(provider, parent);
  }

  async disconnect(provider: ConnectionProvider): Promise<void> {
    const path =
      provider === 'google'
        ? '/api/google/disconnect'
        : '/api/openrouter/disconnect';
    const response = await this.fetch(path, { method: 'POST' });
    await this.json(response, `Could not disconnect ${provider}.`);
  }

  async signOut(): Promise<void> {
    const response = await this.fetch('/api/auth/logout', { method: 'POST' });
    await this.json(response, 'Could not sign out.');
  }

  async fetchLibraryIndex(): Promise<DriveLibraryIndex | null> {
    const response = await this.fetch('/api/library', {
      headers: { Accept: 'application/json' }
    });
    if (response.status === 404) return null;
    return this.json(response, 'Could not read the library from Google Drive.');
  }

  async fetchLibraryFile(file: DriveLibraryFile): Promise<string> {
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

  async uploadLibrary(mirror: DriveLibraryMirror): Promise<{
    changed: number;
    syncedAt: string;
  }> {
    const response = await this.fetch('/api/library/sync', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        schemaVersion: 1,
        index: mirror.index,
        files: mirror.files
      })
    });
    return this.json(response, 'Could not synchronize the library with Google Drive.');
  }

  async loadAudio(hash: string): Promise<Uint8Array | null> {
    const response = await this.fetch(`/api/media/audio/${hash}`);
    if (response.status === 401 || response.status === 404) return null;
    if (!response.ok) return null;
    return new Uint8Array(await response.arrayBuffer());
  }

  async storeAudio(hash: string, bytes: Uint8Array): Promise<void> {
    const response = await this.fetch(`/api/media/audio/${hash}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'audio/mpeg' },
      body: bytes.buffer.slice(
        bytes.byteOffset,
        bytes.byteOffset + bytes.byteLength
      ) as ArrayBuffer
    });
    if (response.status === 401 || response.status === 404) return;
    await this.json(response, 'Could not back up narration to Google Drive.');
  }

  async createSpeech(
    text: string,
    voice: OpenRouterVoice,
    model: string
  ): Promise<Uint8Array> {
    const response = await this.fetch('/api/tts', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'audio/mpeg'
      },
      body: JSON.stringify({ input: text, voice, model })
    });
    if (!response.ok) {
      throw new Error(await this.errorMessage(response, 'Narration could not be generated.'));
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.byteLength) throw new Error('OpenRouter returned empty narration.');
    return bytes;
  }

  async shareStatus(captureID: string): Promise<ShareLinkStatus> {
    const response = await this.fetch(
      `/api/share-links?captureID=${encodeURIComponent(captureID)}`
    );
    return this.json(response, 'Could not read the share link.');
  }

  async publishShare(
    captureID: string,
    voice: OpenRouterVoice,
    model: string
  ): Promise<ShareLinkStatus> {
    const response = await this.fetch('/api/share-links', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ captureID, voice, model })
    });
    return this.json(response, 'Could not create the share link.');
  }

  async revokeShare(token: string): Promise<void> {
    const response = await this.fetch(`/api/share-links/${encodeURIComponent(token)}`, {
      method: 'DELETE'
    });
    await this.json(response, 'Could not revoke the share link.');
  }

  private async openConnectionWindow(
    provider: ConnectionProvider,
    parent: BrowserWindow | null
  ): Promise<void> {
    const parameter = provider === 'google' ? 'google' : 'openrouter';
    const path =
      provider === 'google'
        ? '/api/auth/google/start?return_to=%2F%3Fdesktop%3D1'
        : '/api/openrouter/connect/start';
    const window = new BrowserWindow({
      parent: parent ?? undefined,
      modal: Boolean(parent),
      title: provider === 'google' ? 'Sign in with Google' : 'Connect OpenRouter',
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
          const result = url.searchParams.get(parameter);
          if (!result) return;
          if (result === 'connected') finish();
          else if (result === 'expired') {
            finish(new Error(`${provider === 'google' ? 'Google' : 'OpenRouter'} sign-in expired.`));
          } else {
            finish(new Error(`${provider === 'google' ? 'Google' : 'OpenRouter'} sign-in failed.`));
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
        finish(error instanceof Error ? error : new Error('The sign-in page could not be opened.'));
      });
    });
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
