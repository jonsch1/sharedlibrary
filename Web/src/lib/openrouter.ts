import {
	listGoogleDriveAudio,
	loadGoogleDriveAudio,
	storeGoogleDriveAudio
} from '$lib/google-drive.js';
import { loadICloudAudio, storeICloudAudio, type SyncProvider } from '$lib/icloud.js';
import { ttsModels } from '../../tts-pricing.js';

export const defaultOpenRouterModel = 'hexgrad/kokoro-82m';
export const grokVoiceModel = 'x-ai/grok-voice-tts-1.0';
export const orpheusVoiceModel = 'canopylabs/orpheus-3b-0.1-ft';

export type OpenRouterVoice = string;
export type OpenRouterTTSModel =
	| typeof defaultOpenRouterModel
	| typeof orpheusVoiceModel
	| typeof grokVoiceModel;
export const openRouterTTSOptions = ttsModels as ReadonlyArray<{
	model: OpenRouterTTSModel;
	quality: string;
	name: string;
	hoursPerEuro: number;
	retailCentsPerMillionCharacters: number;
	description: string;
	voices: readonly string[];
}>;
export type SpeechLoadingPhase = 'checking' | 'downloading' | 'generating';

export interface OpenRouterCredential {
	connected: true;
}

export interface ManagedTTSUsage {
	model: string;
	characterCount: number;
	amountMicros: number;
	generationID: string | null;
	createdAt: number;
}

export interface ManagedTTSStatus {
	configured: boolean;
	checkoutConfigured: boolean;
	authenticated: boolean;
	balanceMicros: number;
	topUpAmounts: number[];
	prices: Array<{ model: string; retailCentsPerMillionCharacters: number }>;
	usage: ManagedTTSUsage[];
}

export function formatTTSMicros(micros: number): string {
	return new Intl.NumberFormat(undefined, {
		style: 'currency',
		currency: 'EUR',
		minimumFractionDigits: 2,
		maximumFractionDigits: 4
	}).format(micros / 100_000_000);
}

const audioCacheName = 'shared-library-openrouter-audio-v1';
const voicePreferenceKey = 'shared-library-openrouter-voice';
const modelPreferenceKey = 'shared-library-openrouter-model';
const maximumSpeechSegmentLength = 360;
const voiceIdentifierPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
let durableAudioProvider: SyncProvider | null = null;

export interface OpenRouterSpeechSource {
	url: string;
	release: () => void;
}

export function setDurableAudioProvider(provider: SyncProvider | null): void {
	durableAudioProvider = provider;
}

async function errorMessage(response: Response, fallback: string): Promise<string> {
	try {
		const value = (await response.json()) as {
			error?: { message?: string } | string;
			message?: string;
		};
		if (typeof value.error === 'string') return value.error;
		if (typeof value.error?.message === 'string') return value.error.message;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The response was not JSON.
	}
	return fallback;
}

export async function loadManagedTTSStatus(): Promise<ManagedTTSStatus> {
	const response = await fetch('/api/tts/status', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, `Could not read the AI voice balance (${response.status}).`)
		);
	}
	return (await response.json()) as ManagedTTSStatus;
}

export async function beginManagedTTSTopUp(amountCents: number): Promise<void> {
	const response = await fetch('/api/tts/checkout', {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		body: JSON.stringify({ amountCents, checkoutID: crypto.randomUUID() })
	});
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, `Could not open the top-up checkout (${response.status}).`)
		);
	}
	const value = (await response.json()) as { url?: unknown };
	if (typeof value.url !== 'string') throw new Error('Stripe did not return a Checkout URL.');
	window.location.assign(value.url);
}

export function consumeManagedTTSResult(): string | null {
	const url = new URL(window.location.href);
	const result = url.searchParams.get('tts');
	if (!result) return null;
	url.searchParams.delete('tts');
	window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
	return result;
}

export function normalizeOpenRouterModel(value: unknown): OpenRouterTTSModel | null {
	if (typeof value !== 'string') return null;
	const model = value.trim();
	return openRouterTTSOptions.some((option) => option.model === model)
		? (model as OpenRouterTTSModel)
		: null;
}

export function recommendedVoiceForModel(model: OpenRouterTTSModel): OpenRouterVoice {
	if (model === defaultOpenRouterModel) return 'af_heart';
	if (model === orpheusVoiceModel) return 'tara';
	return 'eve';
}

export function voicesForModel(model: OpenRouterTTSModel): readonly OpenRouterVoice[] {
	return openRouterTTSOptions.find((option) => option.model === model)?.voices ?? [];
}

export function voiceName(voice: OpenRouterVoice): string {
	return voice
		.replace(/^[a-z]{2}_/, '')
		.split('_')
		.map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
		.join(' ');
}

export function normalizeOpenRouterVoice(value: unknown): OpenRouterVoice | null {
	if (typeof value !== 'string') return null;
	const voice = value.trim();
	return voiceIdentifierPattern.test(voice) ? voice : null;
}

function migrateVoiceForModel(
	model: OpenRouterTTSModel,
	voice: OpenRouterVoice | null
): OpenRouterVoice {
	const recommended = recommendedVoiceForModel(model);
	return voice && voicesForModel(model).includes(voice) ? voice : recommended;
}

export function loadOpenRouterPreferences(): {
	model: OpenRouterTTSModel;
	voice: OpenRouterVoice;
} {
	const storedModel = localStorage.getItem(modelPreferenceKey);
	const model = normalizeOpenRouterModel(storedModel) ?? defaultOpenRouterModel;
	const storedVoice = localStorage.getItem(voicePreferenceKey);
	const voice = migrateVoiceForModel(model, normalizeOpenRouterVoice(storedVoice));

	// Existing installations did not store a model and used Grok-only voice names.
	// Start the new Kokoro default with its broadly supported example voice.
	return {
		model,
		voice: storedModel ? voice : recommendedVoiceForModel(model)
	};
}

export function saveVoicePreference(voice: OpenRouterVoice): void {
	localStorage.setItem(voicePreferenceKey, voice);
}

export function saveModelPreference(model: OpenRouterTTSModel): void {
	localStorage.setItem(modelPreferenceKey, model);
}

function splitSentences(text: string): string[] {
	return text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [text];
}

export function openRouterSpeechChunks(text: string): string[] {
	const sentences = splitSentences(text);
	const chunks: string[] = [];
	let current = '';

	const flush = (): void => {
		if (current.trim()) chunks.push(current.trim());
		current = '';
	};

	for (const sentence of sentences) {
		const trimmed = sentence.trim();
		if (!trimmed) continue;
		if (trimmed.length > maximumSpeechSegmentLength) {
			flush();
			let remaining = trimmed;
			while (remaining.length > maximumSpeechSegmentLength) {
				const candidate = remaining.slice(0, maximumSpeechSegmentLength + 1);
				const wordBoundary = candidate.lastIndexOf(' ');
				const splitAt =
					wordBoundary >= Math.floor(maximumSpeechSegmentLength * 0.6)
						? wordBoundary
						: maximumSpeechSegmentLength;
				chunks.push(remaining.slice(0, splitAt).trim());
				remaining = remaining.slice(splitAt).trim();
			}
			if (remaining) current = remaining;
		} else if (
			current &&
			current.length + trimmed.length + 1 > maximumSpeechSegmentLength
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

export async function audioFingerprint(
	text: string,
	voice: OpenRouterVoice,
	model: OpenRouterTTSModel
): Promise<string> {
	const fingerprint = await crypto.subtle.digest(
		'SHA-256',
		new TextEncoder().encode(`${model}\n${voice}\n${text}`)
	);
	return Array.from(new Uint8Array(fingerprint), (byte) =>
		byte.toString(16).padStart(2, '0')
	).join('');
}

function audioCacheRequest(hash: string): Request {
	return new Request(`${window.location.origin}/__openrouter-audio-cache/${hash}.mp3`);
}

export async function loadCachedSpeech(
	text: string,
	voice: OpenRouterVoice,
	model: OpenRouterTTSModel,
	onLoadingPhase?: (phase: SpeechLoadingPhase) => void
): Promise<Blob | null> {
	onLoadingPhase?.('checking');
	const hash = await audioFingerprint(text, voice, model);
	try {
		if ('caches' in globalThis) {
			const cache = await caches.open(audioCacheName);
			const response = await cache.match(audioCacheRequest(hash));
			if (response) return response.blob();
		}
	} catch {
		// Fall through to the durable Google Drive copy.
	}
	onLoadingPhase?.('downloading');
	const cloudAudio =
		durableAudioProvider === 'icloud'
			? await loadICloudAudio(hash)
			: durableAudioProvider === 'google'
				? await loadGoogleDriveAudio(hash)
				: null;
	if (!cloudAudio) return null;
	try {
		await cacheSpeech(hash, cloudAudio);
	} catch {
		// Playback can continue when local storage is unavailable.
	}
	return cloudAudio;
}

async function cacheSpeech(hash: string, audio: Blob): Promise<void> {
	if (!('caches' in globalThis)) return;
	const cache = await caches.open(audioCacheName);
	await cache.put(
		audioCacheRequest(hash),
		new Response(audio, {
			headers: {
				'Content-Type': audio.type || 'audio/mpeg',
				'Cache-Control': 'private, max-age=31536000'
			}
		})
	);
}

export async function synchronizeOpenRouterAudioCache(
	onProgress?: (completed: number, total: number) => void
): Promise<void> {
	if (!('caches' in globalThis) || durableAudioProvider !== 'google') return;
	const files = await listGoogleDriveAudio();
	const cache = await caches.open(audioCacheName);
	const missing: typeof files = [];
	let completed = 0;
	for (const file of files) {
		if (await cache.match(audioCacheRequest(file.hash))) {
			completed += 1;
		} else {
			missing.push(file);
		}
	}
	onProgress?.(completed, files.length);

	let nextIndex = 0;
	const workerCount = Math.min(2, missing.length);
	await Promise.all(
		Array.from({ length: workerCount }, async () => {
			while (nextIndex < missing.length) {
				const file = missing[nextIndex];
				nextIndex += 1;
				const audio = await loadGoogleDriveAudio(file.hash);
				if (!audio) throw new Error('A Google Drive audio file could not be downloaded.');
				await cacheSpeech(file.hash, audio);
				completed += 1;
				onProgress?.(completed, files.length);
			}
		})
	);
}

export class OpenRouterSpeechError extends Error {
	constructor(
		message: string,
		readonly status: number
	) {
		super(message);
		this.name = 'OpenRouterSpeechError';
	}
}

function blobSpeechSource(audio: Blob): OpenRouterSpeechSource {
	const url = URL.createObjectURL(audio);
	let released = false;
	return {
		url,
		release: () => {
			if (released) return;
			released = true;
			URL.revokeObjectURL(url);
		}
	};
}

function abortError(): DOMException {
	return new DOMException('Speech generation was cancelled.', 'AbortError');
}

function canStreamMP3(): boolean {
	return (
		'MediaSource' in globalThis &&
		typeof MediaSource.isTypeSupported === 'function' &&
		MediaSource.isTypeSupported('audio/mpeg')
	);
}

function waitForMediaSource(
	mediaSource: MediaSource,
	signal?: AbortSignal
): Promise<void> {
	if (mediaSource.readyState === 'open') return Promise.resolve();
	return new Promise((resolve, reject) => {
		const opened = (): void => {
			cleanup();
			resolve();
		};
		const aborted = (): void => {
			cleanup();
			reject(abortError());
		};
		const cleanup = (): void => {
			mediaSource.removeEventListener('sourceopen', opened);
			signal?.removeEventListener('abort', aborted);
		};
		mediaSource.addEventListener('sourceopen', opened, { once: true });
		signal?.addEventListener('abort', aborted, { once: true });
	});
}

function appendMP3Chunk(sourceBuffer: SourceBuffer, chunk: Uint8Array): Promise<void> {
	return new Promise((resolve, reject) => {
		const completed = (): void => {
			cleanup();
			resolve();
		};
		const failed = (): void => {
			cleanup();
			reject(new Error('The streamed audio could not be decoded.'));
		};
		const cleanup = (): void => {
			sourceBuffer.removeEventListener('updateend', completed);
			sourceBuffer.removeEventListener('error', failed);
		};
		sourceBuffer.addEventListener('updateend', completed, { once: true });
		sourceBuffer.addEventListener('error', failed, { once: true });
		try {
			const buffer = new ArrayBuffer(chunk.byteLength);
			new Uint8Array(buffer).set(chunk);
			sourceBuffer.appendBuffer(buffer);
		} catch (error) {
			cleanup();
			reject(error);
		}
	});
}

async function persistGeneratedSpeech(hash: string, audio: Blob): Promise<void> {
	try {
		await cacheSpeech(hash, audio);
	} catch {
		// Playback should still succeed when browser storage is full or unavailable.
	}
	const store =
		durableAudioProvider === 'icloud'
			? storeICloudAudio
			: durableAudioProvider === 'google'
				? storeGoogleDriveAudio
				: null;
	void store?.(hash, audio).catch(() => {
		// Cloud backup is optional; playback should not wait for or fail with its upload.
	});
}

function mediaSourceSpeechSource(
	body: ReadableStream<Uint8Array>,
	hash: string,
	signal?: AbortSignal
): OpenRouterSpeechSource {
	const mediaSource = new MediaSource();
	const url = URL.createObjectURL(mediaSource);
	const [playbackBody, persistenceBody] = body.tee();
	const reader = playbackBody.getReader();
	let released = false;

	void new Response(persistenceBody)
		.blob()
		.then((audio) => {
			if (audio.size) return persistGeneratedSpeech(hash, new Blob([audio], { type: 'audio/mpeg' }));
		})
		.catch(() => {
			// Streaming playback should continue when caching fails.
		});

	void (async () => {
		try {
			await waitForMediaSource(mediaSource, signal);
			if (released || signal?.aborted) throw abortError();
			const sourceBuffer = mediaSource.addSourceBuffer('audio/mpeg');
			while (true) {
				const { done, value } = await reader.read();
				if (done) break;
				if (!value?.byteLength) continue;
				const copy = value.slice();
				await appendMP3Chunk(sourceBuffer, copy);
			}
			if (mediaSource.readyState === 'open' && !sourceBuffer.updating) {
				mediaSource.endOfStream();
			}
		} catch (error) {
			if (mediaSource.readyState === 'open') {
				try {
					mediaSource.endOfStream(
						error instanceof DOMException && error.name === 'AbortError'
							? undefined
							: 'network'
					);
				} catch {
					// The media element may already have closed the source.
				}
			}
		} finally {
			reader.releaseLock();
		}
	})();

	return {
		url,
		release: () => {
			if (released) return;
			released = true;
			void reader.cancel().catch(() => {});
			URL.revokeObjectURL(url);
		}
	};
}

export async function createOpenRouterSpeechSource(
	_credential: OpenRouterCredential,
	text: string,
	voice: OpenRouterVoice,
	model: OpenRouterTTSModel,
	signal?: AbortSignal,
	onLoadingPhase?: (phase: SpeechLoadingPhase) => void
): Promise<OpenRouterSpeechSource> {
	const cached = await loadCachedSpeech(text, voice, model, onLoadingPhase);
	if (cached) return blobSpeechSource(cached);
	if (signal?.aborted) throw abortError();

	onLoadingPhase?.('generating');
	const response = await fetch('/api/tts', {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Accept: 'audio/mpeg',
			'X-Briefly-Request-Id': crypto.randomUUID()
		},
		body: JSON.stringify({ input: text, voice, model }),
		signal
	});
	if (!response.ok) {
		throw new OpenRouterSpeechError(
			await errorMessage(response, `OpenRouter speech failed (${response.status}).`),
			response.status
		);
	}
	const balanceMicros = Number(response.headers.get('X-Briefly-TTS-Balance-Micros'));
	if (Number.isSafeInteger(balanceMicros) && balanceMicros >= 0) {
		window.dispatchEvent(new CustomEvent('briefly:tts-balance', { detail: balanceMicros }));
	}

	onLoadingPhase?.('downloading');
	const hash = await audioFingerprint(text, voice, model);
	if (response.body && canStreamMP3()) {
		return mediaSourceSpeechSource(response.body, hash, signal);
	}
	const audio = await response.blob();
	if (!audio.size) throw new OpenRouterSpeechError('OpenRouter returned empty audio.', 502);
	await persistGeneratedSpeech(hash, audio);
	return blobSpeechSource(audio);
}
