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
const maximumInputLength = 14_000;
const streamPathPrefix = '/__openrouter-speech-stream/';
const streamPreparationTimeoutMilliseconds = 1_500;

export interface OpenRouterSpeechSource {
	url: string;
	streaming: boolean;
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
		if (trimmed.length > maximumInputLength) {
			flush();
			for (let offset = 0; offset < trimmed.length; offset += maximumInputLength) {
				chunks.push(trimmed.slice(offset, offset + maximumInputLength));
			}
		} else if (current && current.length + trimmed.length + 1 > maximumInputLength) {
			flush();
			current = trimmed;
		} else {
			current = current ? `${current} ${trimmed}` : trimmed;
		}
	}
	flush();
	return chunks;
}

async function audioCacheRequest(text: string, voice: OpenRouterVoice): Promise<Request> {
	const fingerprint = await crypto.subtle.digest(
		'SHA-256',
		new TextEncoder().encode(`${openRouterModel}\n${voice}\n${text}`)
	);
	const hash = Array.from(new Uint8Array(fingerprint), (byte) =>
		byte.toString(16).padStart(2, '0')
	).join('');
	return new Request(`${window.location.origin}/__openrouter-audio-cache/${hash}.mp3`);
}

export async function loadCachedSpeech(
	text: string,
	voice: OpenRouterVoice
): Promise<Blob | null> {
	if (!('caches' in globalThis)) return null;
	try {
		const cache = await caches.open(audioCacheName);
		const response = await cache.match(await audioCacheRequest(text, voice));
		return response ? await response.blob() : null;
	} catch {
		return null;
	}
}

async function cacheSpeech(text: string, voice: OpenRouterVoice, audio: Blob): Promise<void> {
	if (!('caches' in globalThis)) return;
	const cache = await caches.open(audioCacheName);
	await cache.put(
		await audioCacheRequest(text, voice),
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
	return {
		url,
		streaming: false,
		release: () => URL.revokeObjectURL(url)
	};
}

function abortError(): DOMException {
	return new DOMException('Speech generation was cancelled.', 'AbortError');
}

async function prepareServiceWorkerStream(
	text: string,
	voice: OpenRouterVoice,
	signal: AbortSignal | undefined,
	onError: (error: OpenRouterSpeechError) => void
): Promise<OpenRouterSpeechSource | null> {
	if (!('serviceWorker' in navigator) || !navigator.serviceWorker.controller) return null;
	if (signal?.aborted) throw abortError();

	const controller = navigator.serviceWorker.controller;
	const id = crypto.randomUUID();
	const cacheURL = (await audioCacheRequest(text, voice)).url;
	const channel = new MessageChannel();

	return new Promise((resolve, reject) => {
		let prepared = false;
		let released = false;

		const cancel = (): void => {
			if (released) return;
			released = true;
			clearTimeout(timeout);
			signal?.removeEventListener('abort', abort);
			channel.port1.close();
			try {
				controller.postMessage({ type: 'cancel-openrouter-speech-stream', id });
			} catch {
				// The worker may already have been replaced or stopped.
			}
		};
		const abort = (): void => {
			cancel();
			if (!prepared) reject(abortError());
		};
		const timeout = window.setTimeout(() => {
			cancel();
			if (!prepared) resolve(null);
		}, streamPreparationTimeoutMilliseconds);

		channel.port1.onmessage = (event: MessageEvent<unknown>) => {
			const value = event.data as {
				type?: unknown;
				status?: unknown;
				message?: unknown;
			};
			if (value.type === 'openrouter-speech-stream-ready' && !prepared) {
				prepared = true;
				clearTimeout(timeout);
				resolve({
					url: new URL(`${streamPathPrefix}${id}.mp3`, window.location.origin).toString(),
					streaming: true,
					release: cancel
				});
				return;
			}
			if (value.type === 'openrouter-speech-stream-error') {
				onError(
					new OpenRouterSpeechError(
						typeof value.message === 'string'
							? value.message
							: 'OpenRouter speech streaming failed.',
						typeof value.status === 'number' ? value.status : 502
					)
				);
			}
		};
		channel.port1.start();
		signal?.addEventListener('abort', abort, { once: true });

		try {
			controller.postMessage(
				{
					type: 'prepare-openrouter-speech-stream',
					id,
					input: text,
					voice,
					cacheURL
				},
				[channel.port2]
			);
		} catch {
			cancel();
			resolve(null);
		}
	});
}

export async function createOpenRouterSpeechSource(
	_credential: OpenRouterCredential,
	text: string,
	voice: OpenRouterVoice,
	signal?: AbortSignal,
	onStreamError: (error: OpenRouterSpeechError) => void = () => {}
): Promise<OpenRouterSpeechSource> {
	const cached = await loadCachedSpeech(text, voice);
	if (cached) return blobSpeechSource(cached);

	const streamed = await prepareServiceWorkerStream(text, voice, signal, onStreamError);
	if (streamed) return streamed;
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
	try {
		await cacheSpeech(text, voice, audio);
	} catch {
		// Playback should still succeed when browser storage is full or unavailable.
	}
	return blobSpeechSource(audio);
}
