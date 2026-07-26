import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { defaultOpenRouterTTSModel } from '../shared/contracts.js';
import type { BackendClient } from './backend.js';
import { NarrationService, speechChunks } from './narration.js';

test('narration starts with short playable segments and preserves the text', () => {
  const text =
    'First sentence is short. ' +
    `${'A longer passage with several words '.repeat(30)}ends here. ` +
    'Last sentence.';
  const chunks = speechChunks(text);
  assert.ok(chunks.length > 2);
  assert.ok(chunks.every((chunk) => chunk.length <= 360));
  assert.equal(
    chunks.join(' ').replace(/\s+/g, ' ').trim(),
    text.replace(/\s+/g, ' ').trim()
  );
});

test('the first generated segment is exposed as a progressive audio stream', async () => {
  const cacheRoot = await mkdtemp(join(tmpdir(), 'briefly-narration-'));
  const firstBytes = new Uint8Array([1, 2, 3]);
  const lastBytes = new Uint8Array([4, 5]);
  const stream = {
    controller: undefined as ReadableStreamDefaultController<Uint8Array> | undefined
  };
  let stored: (() => void) | undefined;
  const storedPromise = new Promise<void>((resolve) => {
    stored = resolve;
  });
  const backend = {
    loadAudio: async () => null,
    createSpeechResponse: async () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            stream.controller = controller;
            controller.enqueue(firstBytes);
          }
        }),
        { headers: { 'Content-Type': 'audio/mpeg' } }
      ),
    storeAudio: async () => stored?.()
  } as unknown as BackendClient;
  const service = new NarrationService(cacheRoot, backend, () => {}, () => {});

  try {
    const session = await service.start(
      'Streaming begins before synthesis finishes.',
      'af_heart',
      defaultOpenRouterTTSModel
    );
    const response = service.responseForURL(session.first.url);
    assert.ok(response?.body);
    const reader = response.body.getReader();
    assert.deepEqual(await reader.read(), { done: false, value: firstBytes });

    const controller = stream.controller;
    assert.ok(controller);
    controller.enqueue(lastBytes);
    controller.close();
    assert.deepEqual(await reader.read(), { done: false, value: lastBytes });
    assert.deepEqual(await reader.read(), { done: true, value: undefined });
    await storedPromise;
  } finally {
    await rm(cacheRoot, { recursive: true, force: true });
  }
});
