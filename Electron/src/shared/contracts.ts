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

export interface DesktopShortcutPreferences {
  captureShortcut: string;
  defaultCaptureShortcut: string;
  registered: boolean;
}

export interface DesktopIngestionStatus {
  phase: 'idle' | 'processing';
  activeCount: number;
  message: string;
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

export type AccountProvider = 'google' | 'apple';
export type ConnectionProvider = 'google' | 'icloud';
export type OpenRouterVoice = string;
export const defaultOpenRouterTTSModel = 'hexgrad/kokoro-82m';
export const grokVoiceTTSModel = 'x-ai/grok-voice-tts-1.0';
export const orpheusVoiceTTSModel = 'canopylabs/orpheus-3b-0.1-ft';
export const openRouterTTSModels = [
  {
    id: defaultOpenRouterTTSModel,
    quality: 'Low',
    name: 'Kokoro 82M',
    hoursPerEuro: 10,
    retailCentsPerMillionCharacters: 75,
    description: 'Fast, clear narration at the lowest cost.',
    voices: [
      'af_heart', 'af_alloy', 'af_aoede', 'af_bella', 'af_jessica', 'af_kore',
      'af_nicole', 'af_nova', 'af_river', 'af_sarah', 'af_sky', 'am_adam',
      'am_echo', 'am_eric', 'am_fenrir', 'am_liam', 'am_michael', 'am_onyx',
      'am_puck', 'am_santa', 'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily',
      'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis', 'ef_dora', 'em_alex',
      'em_santa', 'ff_siwis', 'hf_alpha', 'hf_beta', 'hm_omega', 'hm_psi',
      'if_sara', 'im_nicola', 'jf_alpha', 'jf_gongitsune', 'jf_nezumi',
      'jf_tebukuro', 'jm_kumo', 'pf_dora', 'pm_alex', 'pm_santa', 'zf_xiaobei',
      'zf_xiaoni', 'zf_xiaoxiao', 'zf_xiaoyi', 'zm_yunjian', 'zm_yunxi',
      'zm_yunxia', 'zm_yunyang'
    ]
  },
  {
    id: orpheusVoiceTTSModel,
    quality: 'Medium',
    name: 'Orpheus 3B',
    hoursPerEuro: 2,
    retailCentsPerMillionCharacters: 840,
    description: 'More expressive delivery at a mid-range price.',
    voices: ['tara', 'leah', 'jess', 'leo', 'dan', 'mia', 'zac']
  },
  {
    id: grokVoiceTTSModel,
    quality: 'High',
    name: 'Grok Voice',
    hoursPerEuro: 1,
    retailCentsPerMillionCharacters: 1800,
    description: 'The most natural, polished narration.',
    voices: ['eve', 'ara', 'rex', 'sal', 'leo']
  }
] as const;
export type OpenRouterTTSModel = (typeof openRouterTTSModels)[number]['id'];

const openRouterVoicePattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;

export function normalizeOpenRouterTTSModel(value: unknown): OpenRouterTTSModel | null {
  if (typeof value !== 'string') return null;
  const model = value.trim();
  return openRouterTTSModels.some((option) => option.id === model)
    ? model as OpenRouterTTSModel
    : null;
}

export function recommendedVoiceForTTSModel(model: OpenRouterTTSModel): OpenRouterVoice {
  if (model === defaultOpenRouterTTSModel) return 'af_heart';
  if (model === orpheusVoiceTTSModel) return 'tara';
  return 'eve';
}

export function voicesForTTSModel(model: OpenRouterTTSModel): readonly string[] {
  return openRouterTTSModels.find((option) => option.id === model)?.voices ?? [];
}

export function openRouterVoiceName(voice: OpenRouterVoice): string {
  return voice
    .replace(/^[a-z]{2}_/, '')
    .split('_')
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join(' ');
}

export function isVoiceForTTSModel(
  model: OpenRouterTTSModel,
  value: unknown
): value is OpenRouterVoice {
  const voice = normalizeOpenRouterVoice(value);
  return voice !== null && voicesForTTSModel(model).includes(voice);
}

export function normalizeOpenRouterVoice(value: unknown): OpenRouterVoice | null {
  if (typeof value !== 'string') return null;
  const voice = value.trim();
  return openRouterVoicePattern.test(voice) ? voice : null;
}

export function migrateVoiceForTTSModel(
  model: OpenRouterTTSModel,
  value: unknown
): OpenRouterVoice {
  const voice = normalizeOpenRouterVoice(value);
  const recommended = recommendedVoiceForTTSModel(model);
  return voice && isVoiceForTTSModel(model, voice) ? voice : recommended;
}

export interface DesktopConnectionStatus {
  authenticated: boolean;
  entitled: boolean;
  syncProvider: ConnectionProvider | null;
  google: {
    configured: boolean;
    connected: boolean;
    connectedAt?: string;
  };
  icloud: {
    configured: boolean;
    connected: boolean;
  };
  tts: {
    configured: boolean;
    checkoutConfigured: boolean;
    balanceMicros: number;
  };
  sync: DesktopSyncStatus;
  voice: OpenRouterVoice;
  ttsModel: OpenRouterTTSModel;
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
  error?: string;
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
  signIn(provider: AccountProvider): Promise<DesktopConnectionStatus>;
  manageAccount(): Promise<DesktopConnectionStatus>;
  syncNow(): Promise<DesktopConnectionStatus>;
  setVoice(voice: OpenRouterVoice): Promise<DesktopConnectionStatus>;
  setTTSModel(model: OpenRouterTTSModel): Promise<DesktopConnectionStatus>;
  getShortcutPreferences(): Promise<DesktopShortcutPreferences>;
  setCaptureShortcut(accelerator: string): Promise<DesktopShortcutPreferences>;
  getIngestionStatus(): Promise<DesktopIngestionStatus>;
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
  onIngestionStatus(listener: (status: DesktopIngestionStatus) => void): () => void;
  onSyncStatus(listener: (status: DesktopSyncStatus) => void): () => void;
  onNarrationStatus(listener: (status: NarrationStatus) => void): () => void;
  onNarrationSegment(listener: (segment: NarrationSegment) => void): () => void;
}
