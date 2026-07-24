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

export interface TopicDefinition {
  id: string;
  title: string;
}

export interface ProcessingPreferences {
  topics: TopicDefinition[];
  prompt: string;
  defaultPrompt: string;
}

export interface ProcessingPreferencesUpdate {
  topics: TopicDefinition[];
  prompt: string;
}

export type ConnectionProvider = 'google' | 'openrouter';
export type OpenRouterVoice = string;
export const defaultOpenRouterTTSModel = 'hexgrad/kokoro-82m';
export const grokVoiceTTSModel = 'x-ai/grok-voice-tts-1.0';
export const orpheusVoiceTTSModel = 'canopylabs/orpheus-3b-0.1-ft';

const openRouterModelPattern =
  /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const openRouterVoicePattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;

export function normalizeOpenRouterTTSModel(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const model = value.trim();
  return openRouterModelPattern.test(model) ? model : null;
}

export function recommendedVoiceForTTSModel(model: string): OpenRouterVoice | null {
  if (model === defaultOpenRouterTTSModel) return 'af_heart';
  if (model === orpheusVoiceTTSModel) return 'tara';
  if (model === grokVoiceTTSModel) return 'eve';
  return null;
}

export function normalizeOpenRouterVoice(value: unknown): OpenRouterVoice | null {
  if (typeof value !== 'string') return null;
  const voice = value.trim();
  return openRouterVoicePattern.test(voice) ? voice : null;
}

export function migrateVoiceForTTSModel(
  model: string,
  value: unknown
): OpenRouterVoice {
  const voice = normalizeOpenRouterVoice(value);
  const recommended = recommendedVoiceForTTSModel(model);
  if (!voice) return recommended ?? 'af_heart';
  if (
    model === defaultOpenRouterTTSModel &&
    ['alloy', 'eve', 'ara', 'leo', 'rex', 'sal'].includes(voice)
  ) {
    return recommended ?? voice;
  }
  if (model === orpheusVoiceTTSModel && voice === 'alloy') {
    return recommended ?? voice;
  }
  return voice;
}

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
  ttsModel: string;
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

export type NarrationLoadingPhase = 'checking' | 'downloading' | 'generating';

export interface NarrationStatus {
  sessionID: string;
  index: number;
  phase: NarrationLoadingPhase;
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
  openAgent(): Promise<void>;
  revealEntry(entryID: string): Promise<void>;
  showEntryContextMenu(entryID: string, variant?: LibraryVariant): Promise<void>;
  getConnectionStatus(): Promise<DesktopConnectionStatus>;
  connect(provider: ConnectionProvider): Promise<DesktopConnectionStatus>;
  disconnect(provider: ConnectionProvider): Promise<DesktopConnectionStatus>;
  syncNow(): Promise<DesktopConnectionStatus>;
  setVoice(voice: OpenRouterVoice): Promise<DesktopConnectionStatus>;
  setTTSModel(model: string): Promise<DesktopConnectionStatus>;
  getProcessingPreferences(): Promise<ProcessingPreferences>;
  updateProcessingPreferences(
    preferences: ProcessingPreferencesUpdate
  ): Promise<ProcessingPreferences>;
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
  onNarrationStatus(listener: (status: NarrationStatus) => void): () => void;
  onNarrationSegment(listener: (segment: NarrationSegment) => void): () => void;
}
