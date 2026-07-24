import type {
  DesktopOperationResult,
  SharedLibraryDesktopAPI
} from '../shared/contracts';

declare global {
  interface Window {
    sharedLibrary: SharedLibraryDesktopAPI;
    sharedLibraryDesktopEvents: {
      onChooseWorkspace(listener: () => void): () => void;
      onOperationMessage(
        listener: (result: Partial<DesktopOperationResult>) => void
      ): () => void;
    };
  }
}

export {};
