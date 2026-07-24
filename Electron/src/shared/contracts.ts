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
  onLibraryChanged(listener: (snapshot: DesktopLibrarySnapshot) => void): () => void;
}
