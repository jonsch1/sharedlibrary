import type {
  DesktopOperationResult,
  SharedLibraryDesktopAPI
} from './contracts.js';

export type BrieflyAppCapabilities = {
  capture: boolean;
  channels: boolean;
  channelManagement: boolean;
  briefs: boolean;
  briefAuthoring: boolean;
  agents: boolean;
  nativeSettings: boolean;
  contextMenus: boolean;
};

export type BrieflyDesktopEvents = {
  onChooseWorkspace(listener: () => void): () => void;
  onOperationMessage(
    listener: (result: Partial<DesktopOperationResult>) => void
  ): () => void;
};

export const desktopCapabilities: BrieflyAppCapabilities = {
  capture: true,
  channels: true,
  channelManagement: true,
  briefs: true,
  briefAuthoring: true,
  agents: true,
  nativeSettings: true,
  contextMenus: true
};

export const webCapabilities: BrieflyAppCapabilities = {
  capture: false,
  channels: true,
  channelManagement: false,
  briefs: true,
  briefAuthoring: false,
  agents: false,
  nativeSettings: false,
  contextMenus: false
};

export const noDesktopEvents: BrieflyDesktopEvents = {
  onChooseWorkspace: () => () => {},
  onOperationMessage: () => () => {}
};

export type BrieflyAppProps = {
  api: SharedLibraryDesktopAPI;
  capabilities?: BrieflyAppCapabilities;
  desktopEvents?: BrieflyDesktopEvents;
  appIcon?: string;
  loadDemo?: () => Promise<import('./contracts.js').DesktopLibrarySnapshot>;
};
