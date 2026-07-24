export const libraryVariants = [
  'brief',
  'concise',
  'detailed',
  'comprehensive',
  'source'
] as const;

export type LibraryVariant = (typeof libraryVariants)[number];

export type DesktopPlatform = 'aix' | 'android' | 'darwin' | 'freebsd' | 'haiku' |
  'linux' | 'openbsd' | 'sunos' | 'win32' | 'cygwin' | 'netbsd';

export interface DesktopLibraryEntry {
  id: string;
  captureID: string;
  filename: string;
  title: string;
  excerpt: string;
  topicIDs: string[];
  topicNames: string[];
  tags: string[];
  sourceURL?: string;
  createdAt?: string;
  updatedAt?: string;
  availableVariants: LibraryVariant[];
}

export interface DesktopLibrarySnapshot {
  workspacePath: string;
  platform: DesktopPlatform;
  generatedAt: string;
  topics: string[];
  entries: DesktopLibraryEntry[];
}

export interface DesktopOperationResult {
  snapshot: DesktopLibrarySnapshot;
  message: string;
  selectedEntryID?: string;
}

export type ConnectionProvider = 'google' | 'openrouter';
export type OpenRouterVoice = 'eve' | 'ara' | 'leo' | 'rex' | 'sal';

export interface DesktopConnectionStatus {
  authenticated: boolean;
  google: {
    configured: boolean;
    connected: boolean;
    connectedAt?: string;
  };
  openrouter: {
    connected: boolean;
    connectedAt?: string;
    userID?: string;
  };
  sync: DesktopSyncStatus;
  voice: OpenRouterVoice;
}

export interface DesktopSyncStatus {
  phase: 'idle' | 'checking' | 'downloading' | 'uploading' | 'up-to-date' | 'error';
  message: string;
  updatedAt?: string;
}

export interface NarrationSegment {
  sessionID: string;
  index: number;
  total: number;
  url: string;
}

export interface NarrationSession {
  sessionID: string;
  total: number;
  first: NarrationSegment;
}

export interface ShareLinkStatus {
  shared: boolean;
  token?: string;
  url?: string;
  status?: 'preparing' | 'ready' | 'failed';
  revision?: number;
  error?: string;
  voice?: OpenRouterVoice;
  updatedAt?: string;
}

export interface SharedLibraryDesktopAPI {
  getSnapshot(): Promise<DesktopLibrarySnapshot>;
  chooseWorkspace(): Promise<DesktopLibrarySnapshot | null>;
  refresh(): Promise<DesktopLibrarySnapshot>;
  readText(entryID: string, variant: LibraryVariant): Promise<string>;
  writeText(entryID: string, variant: LibraryVariant, text: string): Promise<DesktopOperationResult>;
  trashCapture(entryID: string): Promise<DesktopOperationResult>;
  captureClipboard(): Promise<DesktopOperationResult>;
  openExternal(url: string): Promise<void>;
  revealEntry(entryID: string): Promise<void>;
  getConnectionStatus(): Promise<DesktopConnectionStatus>;
  connect(provider: ConnectionProvider): Promise<DesktopConnectionStatus>;
  disconnect(provider: ConnectionProvider): Promise<DesktopConnectionStatus>;
  syncNow(): Promise<DesktopConnectionStatus>;
  setVoice(voice: OpenRouterVoice): Promise<DesktopConnectionStatus>;
  startNarration(
    entryID: string,
    variant: LibraryVariant,
    voice: OpenRouterVoice
  ): Promise<NarrationSession>;
  getShareLink(entryID: string): Promise<ShareLinkStatus>;
  publishShareLink(entryID: string, voice: OpenRouterVoice): Promise<ShareLinkStatus>;
  revokeShareLink(token: string): Promise<void>;
  onLibraryChanged(listener: (snapshot: DesktopLibrarySnapshot) => void): () => void;
  onSyncStatus(listener: (status: DesktopSyncStatus) => void): () => void;
  onNarrationSegment(listener: (segment: NarrationSegment) => void): () => void;
}
