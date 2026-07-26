import { createHash, randomUUID } from 'node:crypto';
import { mkdir, rename, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type {
  NarrationSegment,
  NarrationSession,
  NarrationStatus,
  OpenRouterTTSModel,
  OpenRouterVoice
} from '../shared/contracts.js';
import { BackendClient } from './backend.js';

const maximumSegmentLength = 360;

interface ActiveSpeechStream {
  body: ReadableStream<Uint8Array>;
  contentType: string;
  timeout: NodeJS.Timeout;
}

export class NarrationService {
  private readonly activeStreams = new Map<string, ActiveSpeechStream>();

  constructor(
    private readonly cacheRoot: string,
    private readonly backend: BackendClient,
    private readonly onSegment: (segment: NarrationSegment) => void,
    private readonly onStatus: (status: NarrationStatus) => void
  ) {}

  async start(
    text: string,
    voice: OpenRouterVoice,
    model: OpenRouterTTSModel
  ): Promise<NarrationSession> {
    const chunks = speechChunks(text);
    if (!chunks.length) throw new Error('This document does not contain narratable text.');
    const sessionID = randomUUID();
    const first = await this.segment(sessionID, 0, chunks, voice, model, true);
    setImmediate(() => void this.generateRemaining(sessionID, chunks, voice, model)).unref();
    return { sessionID, total: chunks.length, first };
  }

  responseForURL(value: string): Response | null {
    const hash = hashForAudioURL(value);
    if (!hash) return null;
    const active = this.activeStreams.get(hash);
    if (!active) return null;
    this.activeStreams.delete(hash);
    clearTimeout(active.timeout);
    return new Response(active.body, {
      headers: {
        'Content-Type': active.contentType,
        'Cache-Control': 'private, no-store'
      }
    });
  }

  pathForURL(value: string): string | null {
    const hash = hashForAudioURL(value);
    return hash ? join(this.cacheRoot, `${hash}.mp3`) : null;
  }

  private async generateRemaining(
    sessionID: string,
    chunks: string[],
    voice: OpenRouterVoice,
    model: OpenRouterTTSModel
  ): Promise<void> {
    for (let index = 1; index < chunks.length; index += 1) {
      try {
        this.onSegment(await this.segment(sessionID, index, chunks, voice, model));
      } catch (error) {
        this.onStatus({
          sessionID,
          index,
          phase: 'checking',
          error: error instanceof Error ? error.message : 'Narration could not continue.'
        });
        return;
      }
    }
  }

  private async segment(
    sessionID: string,
    index: number,
    chunks: string[],
    voice: OpenRouterVoice,
    model: OpenRouterTTSModel,
    stream = false
  ): Promise<NarrationSegment> {
    const hash = fingerprint(chunks[index], voice, model);
    const path = join(this.cacheRoot, `${hash}.mp3`);
    this.onStatus({ sessionID, index, phase: 'checking' });
    if (!(await isNonemptyFile(path))) {
      this.onStatus({ sessionID, index, phase: 'downloading' });
      const stored = await this.backend.loadAudio(hash);
      if (stored) {
        await atomicWrite(path, stored);
      } else {
        this.onStatus({ sessionID, index, phase: 'generating' });
        if (stream) {
          const response = await this.backend.createSpeechResponse(
            chunks[index],
            voice,
            model
          );
          if (response.body) {
            this.registerSpeechStream(
              hash,
              path,
              response.body,
              response.headers.get('Content-Type') || 'audio/mpeg'
            );
            return narrationSegment(sessionID, index, chunks.length, hash);
          }
        }
        const bytes = await this.backend.createSpeech(chunks[index], voice, model);
        await atomicWrite(path, bytes);
        void this.backend.storeAudio(hash, bytes).catch(() => {
          // Playback is local-first; Drive backup can retry later.
        });
      }
    }
    return narrationSegment(sessionID, index, chunks.length, hash);
  }

  private registerSpeechStream(
    hash: string,
    path: string,
    body: ReadableStream<Uint8Array>,
    contentType: string
  ): void {
    const [playback, persistence] = body.tee();
    const timeout = setTimeout(() => {
      const active = this.activeStreams.get(hash);
      if (active?.body !== playback) return;
      this.activeStreams.delete(hash);
      void playback.cancel();
    }, 60_000);
    timeout.unref();
    this.activeStreams.set(hash, { body: playback, contentType, timeout });

    void new Response(persistence)
      .arrayBuffer()
      .then(async (buffer) => {
        const bytes = new Uint8Array(buffer);
        if (!bytes.byteLength) throw new Error('Briefly AI voice returned empty narration.');
        await atomicWrite(path, bytes);
        void this.backend.storeAudio(hash, bytes).catch(() => {
          // Playback is local-first; Drive backup can retry later.
        });
      })
      .catch(() => {
        // The renderer still reports stream playback failures to the user.
      });
  }
}

function hashForAudioURL(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== 'shared-library-audio:') return null;
    const filename = url.pathname.split('/').at(-1) ?? '';
    return /^[a-f0-9]{64}\.mp3$/.test(filename)
      ? filename.slice(0, -4)
      : null;
  } catch {
    return null;
  }
}

function narrationSegment(
  sessionID: string,
  index: number,
  total: number,
  hash: string
): NarrationSegment {
  return {
    sessionID,
    index,
    total,
    url: `shared-library-audio://cache/${hash}.mp3`
  };
}

function fingerprint(
  text: string,
  voice: OpenRouterVoice,
  model: OpenRouterTTSModel
): string {
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
