import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

import type { OpenRouterVoice } from '../shared/contracts.js';

export interface DesktopSettings {
  workspacePath?: string;
  voice?: OpenRouterVoice;
  processingPrompt?: string;
}

export class SettingsStore {
  readonly filePath: string;

  constructor(userDataPath: string) {
    this.filePath = join(userDataPath, 'settings.json');
  }

  async load(): Promise<DesktopSettings> {
    try {
      return JSON.parse(await readFile(this.filePath, 'utf8')) as DesktopSettings;
    } catch {
      return {};
    }
  }

  async save(settings: DesktopSettings): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(settings, null, 2)}\n`, 'utf8');
    await rename(temporaryPath, this.filePath);
  }

  async update(patch: Partial<DesktopSettings>): Promise<DesktopSettings> {
    const next = { ...(await this.load()), ...patch };
    await this.save(next);
    return next;
  }
}
