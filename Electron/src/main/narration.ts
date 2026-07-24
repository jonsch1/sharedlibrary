import { createHash, randomUUID } from 'node:crypto';
import { mkdir, rename, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type {
  NarrationSegment,
  NarrationSession,
  NarrationStatus,
  OpenRouterVoice
} from '../shared/contracts.js';
import { BackendClient } from './backend.js';

const model = 'x-ai/grok-voice-tts-1.0';
const maximumSegmentLength = 360;

export class NarrationService {
  constructor(
    private readonly cacheRoot: string,
    private readonly backend: BackendClient,
    private readonly onSegment: (segment: NarrationSegment) => void,
    private readonly onStatus: (status: NarrationStatus) => void
  ) {}

  async start(text: string, voice: OpenRouterVoice): Promise<NarrationSession> {
    const chunks = speechChunks(text);
    if (!chunks.length) throw new Error('This document does not contain narratable text.');
    const sessionID = randomUUID();
    const first = await this.segment(sessionID, 0, chunks, voice);
    void this.generateRemaining(sessionID, chunks, voice);
    return { sessionID, total: chunks.length, first };
  }

  pathForURL(value: string): string | null {
    try {
      const url = new URL(value);
      if (url.protocol !== 'shared-library-audio:') return null;
      const filename = url.pathname.split('/').at(-1) ?? '';
      if (!/^[a-f0-9]{64}\.mp3$/.test(filename)) return null;
      return join(this.cacheRoot, filename);
    } catch {
      return null;
    }
  }

  private async generateRemaining(
    sessionID: string,
    chunks: string[],
    voice: OpenRouterVoice
  ): Promise<void> {
    for (let index = 1; index < chunks.length; index += 1) {
      try {
        this.onSegment(await this.segment(sessionID, index, chunks, voice));
      } catch {
        return;
      }
    }
  }

  private async segment(
    sessionID: string,
    index: number,
    chunks: string[],
    voice: OpenRouterVoice
  ): Promise<NarrationSegment> {
    const hash = fingerprint(chunks[index], voice);
    const path = join(this.cacheRoot, `${hash}.mp3`);
    this.onStatus({ sessionID, index, phase: 'checking' });
    if (!(await isNonemptyFile(path))) {
      this.onStatus({ sessionID, index, phase: 'downloading' });
      const stored = await this.backend.loadAudio(hash);
      if (!stored) this.onStatus({ sessionID, index, phase: 'generating' });
      const bytes = stored ?? (await this.backend.createSpeech(chunks[index], voice));
      await atomicWrite(path, bytes);
      if (!stored) {
        void this.backend.storeAudio(hash, bytes).catch(() => {
          // Playback is local-first; Drive backup can retry later.
        });
      }
    }
    return {
      sessionID,
      index,
      total: chunks.length,
      url: `shared-library-audio://cache/${hash}.mp3`
    };
  }
}

function fingerprint(text: string, voice: OpenRouterVoice): string {
  return createHash('sha256')
    .update(`${model}\n${voice}\n${text}`)
    .digest('hex');
}

export function speechChunks(text: string): string[] {
  const sentences = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [text];
  const chunks: string[] = [];
  let current = '';
  const flush = () => {
    if (current.trim()) chunks.push(current.trim());
    current = '';
  };
  for (const sentence of sentences) {
    const trimmed = sentence.trim();
    if (!trimmed) continue;
    if (trimmed.length > maximumSegmentLength) {
      flush();
      let remaining = trimmed;
      while (remaining.length > maximumSegmentLength) {
        const candidate = remaining.slice(0, maximumSegmentLength + 1);
        const boundary = candidate.lastIndexOf(' ');
        const splitAt =
          boundary >= Math.floor(maximumSegmentLength * 0.6)
            ? boundary
            : maximumSegmentLength;
        chunks.push(remaining.slice(0, splitAt).trim());
        remaining = remaining.slice(splitAt).trim();
      }
      current = remaining;
    } else if (
      current &&
      current.length + trimmed.length + 1 > maximumSegmentLength
    ) {
      flush();
      current = trimmed;
    } else {
      current = current ? `${current} ${trimmed}` : trimmed;
    }
  }
  flush();
  return chunks;
}

async function isNonemptyFile(path: string): Promise<boolean> {
  try {
    const value = await stat(path);
    return value.isFile() && value.size > 0;
  } catch {
    return false;
  }
}

async function atomicWrite(path: string, bytes: Uint8Array): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporary, bytes);
  await rename(temporary, path);
}
