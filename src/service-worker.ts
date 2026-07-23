/// <reference lib="webworker" />

import { build, files, version } from '$service-worker';

const worker = self as unknown as ServiceWorkerGlobalScope;
const cacheName = `shared-library-${version}`;
const audioCacheName = 'shared-library-openrouter-audio-v1';
const applicationFiles = [...build, ...files];
const streamPathPrefix = '/__openrouter-speech-stream/';
const streamLifetimeMilliseconds = 10 * 60 * 1000;
const supportedVoices = new Set(['eve', 'ara', 'leo', 'rex', 'sal']);

interface PendingSpeechStream {
	input: string;
	voice: string;
	cacheURL: string;
	port: MessagePort;
	abortController: AbortController | null;
	timeout: number;
	started: boolean;
}

const pendingSpeechStreams = new Map<string, PendingSpeechStream>();

function closePendingSpeechStream(id: string, pending: PendingSpeechStream): void {
	if (pendingSpeechStreams.get(id) !== pending) return;
	pendingSpeechStreams.delete(id);
	clearTimeout(pending.timeout);
	pending.abortController?.abort();
	pending.port.close();
}

function speechStreamID(pathname: string): string | null {
	if (!pathname.startsWith(streamPathPrefix) || !pathname.endsWith('.mp3')) return null;
	const id = pathname.slice(streamPathPrefix.length, -4);
	return /^[0-9a-f-]{36}$/i.test(id) ? id : null;
}

function notifyStreamError(
	pending: PendingSpeechStream,
	status: number,
	message: string
): void {
	try {
		pending.port.postMessage({
			type: 'openrouter-speech-stream-error',
			status,
			message
		});
	} catch {
		// The playback page may already have closed its message channel.
	}
}

async function speechErrorMessage(response: Response): Promise<string> {
	try {
		const value = (await response.clone().json()) as {
			error?: { message?: string } | string;
			message?: string;
		};
		if (typeof value.error === 'string') return value.error;
		if (typeof value.error?.message === 'string') return value.error.message;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The response was not JSON.
	}
	return `OpenRouter speech failed (${response.status}).`;
}

async function streamSpeech(
	event: FetchEvent,
	id: string,
	pending: PendingSpeechStream
): Promise<Response> {
	if (pending.started) {
		return new Response('This speech stream has already started.', { status: 409 });
	}
	pending.started = true;
	pending.abortController = new AbortController();

	try {
		const response = await fetch('/api/tts', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Accept: 'audio/mpeg'
			},
			credentials: 'same-origin',
			body: JSON.stringify({ input: pending.input, voice: pending.voice }),
			signal: pending.abortController.signal
		});

		if (!response.ok) {
			notifyStreamError(pending, response.status, await speechErrorMessage(response));
			closePendingSpeechStream(id, pending);
			return response;
		}

		const cacheCopy = response.clone();
		const caching = caches
			.open(audioCacheName)
			.then((cache) => cache.put(pending.cacheURL, cacheCopy))
			.catch(() => {
				// Streaming playback should continue if device storage is unavailable.
			})
			.finally(() => closePendingSpeechStream(id, pending));
		event.waitUntil(caching);
		return response;
	} catch (error) {
		const cancelled = error instanceof DOMException && error.name === 'AbortError';
		if (!cancelled) {
			notifyStreamError(pending, 502, 'The OpenRouter audio stream could not be started.');
		}
		closePendingSpeechStream(id, pending);
		return new Response(cancelled ? 'Speech streaming was cancelled.' : 'Speech streaming failed.', {
			status: cancelled ? 499 : 502
		});
	}
}

worker.addEventListener('install', (event) => {
	event.waitUntil(caches.open(cacheName).then((cache) => cache.addAll(applicationFiles)));
});

worker.addEventListener('activate', (event) => {
	event.waitUntil(
		caches
			.keys()
			.then((keys) =>
				Promise.all(
					keys
						.filter((key) => key !== cacheName && key !== audioCacheName)
						.map((key) => caches.delete(key))
				)
			)
			.then(() => worker.clients.claim())
	);
});

worker.addEventListener('message', (event) => {
	const value = event.data as {
		type?: unknown;
		id?: unknown;
		input?: unknown;
		voice?: unknown;
		cacheURL?: unknown;
	};
	if (value.type === 'cancel-openrouter-speech-stream' && typeof value.id === 'string') {
		const pending = pendingSpeechStreams.get(value.id);
		if (pending) closePendingSpeechStream(value.id, pending);
		return;
	}
	if (
		value.type !== 'prepare-openrouter-speech-stream' ||
		typeof value.id !== 'string' ||
		!value.id.match(/^[0-9a-f-]{36}$/i) ||
		typeof value.input !== 'string' ||
		!value.input.trim() ||
		value.input.length > 14_000 ||
		typeof value.voice !== 'string' ||
		!supportedVoices.has(value.voice) ||
		typeof value.cacheURL !== 'string' ||
		!value.cacheURL.startsWith(`${worker.location.origin}/__openrouter-audio-cache/`) ||
		event.ports.length !== 1
	) {
		return;
	}

	const existing = pendingSpeechStreams.get(value.id);
	if (existing) closePendingSpeechStream(value.id, existing);
	const port = event.ports[0];
	const pending: PendingSpeechStream = {
		input: value.input,
		voice: value.voice,
		cacheURL: value.cacheURL,
		port,
		abortController: null,
		timeout: 0,
		started: false
	};
	pending.timeout = worker.setTimeout(
		() => closePendingSpeechStream(value.id as string, pending),
		streamLifetimeMilliseconds
	);
	pendingSpeechStreams.set(value.id, pending);
	port.postMessage({ type: 'openrouter-speech-stream-ready' });
});

worker.addEventListener('fetch', (event) => {
	const url = new URL(event.request.url);
	const streamID = speechStreamID(url.pathname);
	if (event.request.method === 'GET' && url.origin === worker.location.origin && streamID) {
		const pending = pendingSpeechStreams.get(streamID);
		if (pending) {
			event.respondWith(streamSpeech(event, streamID, pending));
		} else {
			event.respondWith(new Response('Speech stream not found.', { status: 404 }));
		}
		return;
	}
	if (event.request.method !== 'GET' || url.search || url.pathname.startsWith('/api/')) return;
	event.respondWith(
		caches.match(event.request).then((cached) => {
			if (cached) return cached;
			return fetch(event.request).then((response) => {
				if (
					response.ok &&
					url.origin === worker.location.origin
				) {
					const copy = response.clone();
					caches.open(cacheName).then((cache) => cache.put(event.request, copy));
				}
				return response;
			});
		})
	);
});
