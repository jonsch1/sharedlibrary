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
	apiKey: string;
	userID?: string;
	connectedAt: string;
}

const credentialDatabaseName = 'shared-library-openrouter';
const credentialStoreName = 'credentials';
const credentialKey = 'active';
const verifierSessionKey = 'shared-library-openrouter-code-verifier';
const audioCacheName = 'shared-library-openrouter-audio-v1';
const voicePreferenceKey = 'shared-library-openrouter-voice';
const maximumInputLength = 14_000;

function openCredentialDatabase(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		const request = indexedDB.open(credentialDatabaseName, 1);
		request.onupgradeneeded = () => {
			if (!request.result.objectStoreNames.contains(credentialStoreName)) {
				request.result.createObjectStore(credentialStoreName);
			}
		};
		request.onsuccess = () => resolve(request.result);
		request.onerror = () =>
			reject(request.error ?? new Error('Could not open OpenRouter storage.'));
	});
}

async function writeCredential(credential: OpenRouterCredential): Promise<void> {
	const database = await openCredentialDatabase();
	try {
		await new Promise<void>((resolve, reject) => {
			const transaction = database.transaction(credentialStoreName, 'readwrite');
			transaction.objectStore(credentialStoreName).put(credential, credentialKey);
			transaction.oncomplete = () => resolve();
			transaction.onerror = () =>
				reject(transaction.error ?? new Error('Could not save the OpenRouter connection.'));
			transaction.onabort = () =>
				reject(transaction.error ?? new Error('Saving the OpenRouter connection was interrupted.'));
		});
	} finally {
		database.close();
	}
}

export async function loadOpenRouterCredential(): Promise<OpenRouterCredential | null> {
	const database = await openCredentialDatabase();
	try {
		return await new Promise<OpenRouterCredential | null>((resolve, reject) => {
			const request = database
				.transaction(credentialStoreName, 'readonly')
				.objectStore(credentialStoreName)
				.get(credentialKey);
			request.onsuccess = () => {
				const value = request.result;
				if (
					typeof value === 'object' &&
					value !== null &&
					typeof value.apiKey === 'string' &&
					typeof value.connectedAt === 'string'
				) {
					resolve(value as OpenRouterCredential);
				} else {
					resolve(null);
				}
			};
			request.onerror = () =>
				reject(request.error ?? new Error('Could not read the OpenRouter connection.'));
		});
	} finally {
		database.close();
	}
}

export async function disconnectOpenRouter(): Promise<void> {
	const database = await openCredentialDatabase();
	try {
		await new Promise<void>((resolve, reject) => {
			const transaction = database.transaction(credentialStoreName, 'readwrite');
			transaction.objectStore(credentialStoreName).delete(credentialKey);
			transaction.oncomplete = () => resolve();
			transaction.onerror = () =>
				reject(transaction.error ?? new Error('Could not remove the OpenRouter connection.'));
		});
	} finally {
		database.close();
	}
}

function base64URL(bytes: Uint8Array): string {
	let binary = '';
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

async function sha256Base64URL(value: string): Promise<string> {
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
	return base64URL(new Uint8Array(digest));
}

function callbackURL(): string {
	const url = new URL(window.location.href);
	url.search = '';
	url.hash = '';
	return url.toString();
}

export async function beginOpenRouterConnection(): Promise<void> {
	const random = new Uint8Array(64);
	crypto.getRandomValues(random);
	const verifier = base64URL(random);
	const challenge = await sha256Base64URL(verifier);
	sessionStorage.setItem(verifierSessionKey, verifier);

	const authorizationURL = new URL('https://openrouter.ai/auth');
	authorizationURL.searchParams.set('callback_url', callbackURL());
	authorizationURL.searchParams.set('code_challenge', challenge);
	authorizationURL.searchParams.set('code_challenge_method', 'S256');
	window.location.assign(authorizationURL);
}

function consumeAuthorizationCode(): string | null {
	const url = new URL(window.location.href);
	const code = url.searchParams.get('code');
	if (!code) return null;
	url.searchParams.delete('code');
	window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
	return code;
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

export async function completeOpenRouterConnection(): Promise<OpenRouterCredential | null> {
	const code = consumeAuthorizationCode();
	if (!code) return null;

	const verifier = sessionStorage.getItem(verifierSessionKey);
	sessionStorage.removeItem(verifierSessionKey);
	if (!verifier) {
		throw new Error(
			'OpenRouter sign-in returned to a different browser session. Open Audio settings and connect again.'
		);
	}

	const response = await fetch('https://openrouter.ai/api/v1/auth/keys', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			code,
			code_verifier: verifier,
			code_challenge_method: 'S256'
		})
	});
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, `OpenRouter sign-in failed (${response.status}).`)
		);
	}

	const value = (await response.json()) as { key?: unknown; user_id?: unknown };
	if (typeof value.key !== 'string' || !value.key) {
		throw new Error('OpenRouter did not return a usable connection key.');
	}

	const credential: OpenRouterCredential = {
		apiKey: value.key,
		userID: typeof value.user_id === 'string' ? value.user_id : undefined,
		connectedAt: new Date().toISOString()
	};
	await writeCredential(credential);
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

export async function createOpenRouterSpeech(
	credential: OpenRouterCredential,
	text: string,
	voice: OpenRouterVoice,
	signal?: AbortSignal
): Promise<Blob> {
	const cached = await loadCachedSpeech(text, voice);
	if (cached) return cached;

	const response = await fetch('https://openrouter.ai/api/v1/audio/speech', {
		method: 'POST',
		headers: {
			Authorization: `Bearer ${credential.apiKey}`,
			'Content-Type': 'application/json',
			'X-Title': 'Shared Library'
		},
		body: JSON.stringify({
			model: openRouterModel,
			input: text,
			voice,
			response_format: 'mp3'
		}),
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
	return audio;
}
