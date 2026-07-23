import { loadGoogleDriveAudio, storeGoogleDriveAudio } from '$lib/google-drive.js';

export const openRouterModel = 'x-ai/grok-voice-tts-1.0';

export const openRouterVoices = [
	{ id: 'eve', name: 'Eve', description: 'Energetic and engaging' },
	{ id: 'ara', name: 'Ara', description: 'Clear and composed' },
	{ id: 'leo', name: 'Leo', description: 'Warm and friendly' },
	{ id: 'rex', name: 'Rex', description: 'Confident and direct' },
	{ id: 'sal', name: 'Sal', description: 'Natural and conversational' }
] as const;

export type OpenRouterVoice = (typeof openRouterVoices)[number]['id'];

export interface OpenRouterCredential {
	connected: true;
	userID?: string;
	connectedAt?: string;
}

const audioCacheName = 'shared-library-openrouter-audio-v1';
const voicePreferenceKey = 'shared-library-openrouter-voice';
const maximumSpeechSegmentLength = 360;

export interface OpenRouterSpeechSource {
	url: string;
	release: () => void;
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

export async function loadOpenRouterCredential(): Promise<OpenRouterCredential | null> {
	const response = await fetch('/api/openrouter/status', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401 || response.status === 404) return null;
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, `Could not read the OpenRouter connection (${response.status}).`)
		);
	}
	const value = (await response.json()) as {
		connected?: unknown;
		userID?: unknown;
		connectedAt?: unknown;
	};
	if (value.connected !== true) return null;
	return {
		connected: true,
		userID: typeof value.userID === 'string' ? value.userID : undefined,
		connectedAt: typeof value.connectedAt === 'string' ? value.connectedAt : undefined
	};
}

export async function disconnectOpenRouter(): Promise<void> {
	const response = await fetch('/api/openrouter/disconnect', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, `Could not disconnect OpenRouter (${response.status}).`)
		);
	}
}

export async function beginOpenRouterConnection(): Promise<void> {
	window.location.assign('/api/openrouter/connect/start');
}

function consumeConnectionResult(): string | null {
	const url = new URL(window.location.href);
	const result = url.searchParams.get('openrouter');
	if (!result) return null;
	url.searchParams.delete('openrouter');
	window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
	return result;
}

export async function completeOpenRouterConnection(): Promise<OpenRouterCredential | null> {
	const result = consumeConnectionResult();
	if (!result) return null;
	if (result === 'expired') {
		throw new Error('The OpenRouter sign-in expired. Open Audio settings and connect again.');
	}
	if (result !== 'connected') {
		throw new Error('OpenRouter sign-in could not be completed. Please try again.');
	}
	const credential = await loadOpenRouterCredential();
	if (!credential) throw new Error('OpenRouter connected, but the saved connection was not found.');
	return credential;
}

export function loadVoicePreference(): OpenRouterVoice {
	const stored = localStorage.getItem(voicePreferenceKey);
	return openRouterVoices.some((voice) => voice.id === stored)
		? (stored as OpenRouterVoice)
		: 'eve';
}

export function saveVoicePreference(voice: OpenRouterVoice): void {
	localStorage.setItem(voicePreferenceKey, voice);
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
	voice: OpenRouterVoice
): Promise<string> {
	const fingerprint = await crypto.subtle.digest(
		'SHA-256',
		new TextEncoder().encode(`${openRouterModel}\n${voice}\n${text}`)
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
	voice: OpenRouterVoice
): Promise<Blob | null> {
	const hash = await audioFingerprint(text, voice);
	try {
		if ('caches' in globalThis) {
			const cache = await caches.open(audioCacheName);
			const response = await cache.match(audioCacheRequest(hash));
			if (response) return response.blob();
		}
	} catch {
		// Fall through to the durable Google Drive copy.
	}
	const driveAudio = await loadGoogleDriveAudio(hash);
	if (!driveAudio) return null;
	try {
		await cacheSpeech(hash, driveAudio);
	} catch {
		// Playback can continue when local storage is unavailable.
	}
	return driveAudio;
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

export async function clearOpenRouterAudioCache(): Promise<void> {
	if ('caches' in globalThis) await caches.delete(audioCacheName);
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

export async function createOpenRouterSpeechSource(
	_credential: OpenRouterCredential,
	text: string,
	voice: OpenRouterVoice,
	signal?: AbortSignal
): Promise<OpenRouterSpeechSource> {
	const cached = await loadCachedSpeech(text, voice);
	if (cached) return blobSpeechSource(cached);
	if (signal?.aborted) throw abortError();

	const response = await fetch('/api/tts', {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			Accept: 'audio/mpeg'
		},
		body: JSON.stringify({ input: text, voice }),
		signal
	});
	if (!response.ok) {
		throw new OpenRouterSpeechError(
			await errorMessage(response, `OpenRouter speech failed (${response.status}).`),
			response.status
		);
	}

	const audio = await response.blob();
	if (!audio.size) throw new OpenRouterSpeechError('OpenRouter returned empty audio.', 502);
	const hash = await audioFingerprint(text, voice);
	try {
		await cacheSpeech(hash, audio);
	} catch {
		// Playback should still succeed when browser storage is full or unavailable.
	}
	void storeGoogleDriveAudio(hash, audio).catch(() => {
		// Google Drive is optional; playback should not wait for or fail with its upload.
	});
	return blobSpeechSource(audio);
}
