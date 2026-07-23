const openRouterModel = 'x-ai/grok-voice-tts-1.0';
const supportedVoices = new Set(['eve', 'ara', 'leo', 'rex', 'sal']);
const oauthStateLifetimeMilliseconds = 10 * 60 * 1000;
const maximumSpeechInputLength = 14_000;

function json(value, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Content-Type', 'application/json');
	headers.set('Cache-Control', 'no-store');
	return new Response(JSON.stringify(value), { ...init, headers });
}

function authenticatedEmail(request) {
	const email = request.headers.get('oai-authenticated-user-email')?.trim();
	return email || null;
}

function requireSameOrigin(request) {
	const expected = new URL(request.url).origin;
	const origin = request.headers.get('Origin');
	return origin === expected;
}

function randomBase64URL(byteLength = 32) {
	const bytes = new Uint8Array(byteLength);
	crypto.getRandomValues(bytes);
	return bytesToBase64URL(bytes);
}

function bytesToBase64URL(bytes) {
	let binary = '';
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64URLToBytes(value) {
	const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
	const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
	const binary = atob(padded);
	return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function hexToBytes(value) {
	if (!/^[0-9a-f]{64}$/i.test(value)) {
		throw new Error('OPENROUTER_CREDENTIAL_KEY must contain 32 bytes encoded as hexadecimal.');
	}
	return Uint8Array.from(value.match(/.{2}/g), (pair) => Number.parseInt(pair, 16));
}

async function sha256Base64URL(value) {
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
	return bytesToBase64URL(new Uint8Array(digest));
}

async function credentialEncryptionKey(env) {
	if (!env.OPENROUTER_CREDENTIAL_KEY) {
		throw new Error('OpenRouter credential encryption is not configured.');
	}
	return crypto.subtle.importKey(
		'raw',
		hexToBytes(env.OPENROUTER_CREDENTIAL_KEY),
		'AES-GCM',
		false,
		['encrypt', 'decrypt']
	);
}

async function encryptCredential(env, apiKey) {
	const initializationVector = new Uint8Array(12);
	crypto.getRandomValues(initializationVector);
	const ciphertext = await crypto.subtle.encrypt(
		{ name: 'AES-GCM', iv: initializationVector },
		await credentialEncryptionKey(env),
		new TextEncoder().encode(apiKey)
	);
	return {
		encryptedAPIKey: bytesToBase64URL(new Uint8Array(ciphertext)),
		initializationVector: bytesToBase64URL(initializationVector)
	};
}

async function decryptCredential(env, encryptedAPIKey, initializationVector) {
	const plaintext = await crypto.subtle.decrypt(
		{ name: 'AES-GCM', iv: base64URLToBytes(initializationVector) },
		await credentialEncryptionKey(env),
		base64URLToBytes(encryptedAPIKey)
	);
	return new TextDecoder().decode(plaintext);
}

async function ensureSchema(database) {
	await database.batch([
		database
			.prepare(
				`CREATE TABLE IF NOT EXISTS openrouter_credentials (
					user_email TEXT PRIMARY KEY NOT NULL,
					encrypted_api_key TEXT NOT NULL,
					initialization_vector TEXT NOT NULL,
					openrouter_user_id TEXT,
					connected_at TEXT NOT NULL,
					updated_at TEXT NOT NULL
				)`
			),
		database
			.prepare(
				`CREATE TABLE IF NOT EXISTS openrouter_oauth_states (
					state TEXT PRIMARY KEY NOT NULL,
					user_email TEXT NOT NULL,
					code_verifier TEXT NOT NULL,
					created_at INTEGER NOT NULL
				)`
			)
	]);
}

async function openRouterError(response, fallback) {
	try {
		const value = await response.json();
		if (typeof value.error === 'string') return value.error;
		if (typeof value.error?.message === 'string') return value.error.message;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The upstream response was not JSON.
	}
	return fallback;
}

async function connectionStatus(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ connected: false }, { status: 401 });
	await ensureSchema(env.DB);
	const credential = await env.DB.prepare(
		`SELECT openrouter_user_id, connected_at
		 FROM openrouter_credentials
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	return json({
		connected: Boolean(credential),
		userID: credential?.openrouter_user_id ?? undefined,
		connectedAt: credential?.connected_at ?? undefined
	});
}

async function startConnection(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	const state = randomBase64URL();
	const verifier = randomBase64URL(64);
	const challenge = await sha256Base64URL(verifier);
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM openrouter_oauth_states WHERE created_at < ? OR user_email = ?')
			.bind(now - oauthStateLifetimeMilliseconds, email),
		env.DB
			.prepare(
				`INSERT INTO openrouter_oauth_states (state, user_email, code_verifier, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(state, email, verifier, now)
	]);

	const callbackURL = new URL('/api/openrouter/connect/callback', request.url);
	callbackURL.searchParams.set('state', state);
	const authorizationURL = new URL('https://openrouter.ai/auth');
	authorizationURL.searchParams.set('callback_url', callbackURL.toString());
	authorizationURL.searchParams.set('code_challenge', challenge);
	authorizationURL.searchParams.set('code_challenge_method', 'S256');
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishConnection(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	const url = new URL(request.url);
	const state = url.searchParams.get('state');
	const code = url.searchParams.get('code');
	if (!state || !code) return redirectWithOAuthResult(request, 'error');

	const pending = await env.DB.prepare(
		`SELECT user_email, code_verifier, created_at
		 FROM openrouter_oauth_states
		 WHERE state = ?`
	)
		.bind(state)
		.first();
	if (
		!pending ||
		pending.user_email !== email ||
		Date.now() - pending.created_at > oauthStateLifetimeMilliseconds
	) {
		return redirectWithOAuthResult(request, 'expired');
	}

	await env.DB.prepare('DELETE FROM openrouter_oauth_states WHERE state = ?').bind(state).run();
	const response = await fetch('https://openrouter.ai/api/v1/auth/keys', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			code,
			code_verifier: pending.code_verifier,
			code_challenge_method: 'S256'
		})
	});
	if (!response.ok) return redirectWithOAuthResult(request, 'error');

	const value = await response.json();
	if (typeof value.key !== 'string' || !value.key) {
		return redirectWithOAuthResult(request, 'error');
	}

	const encrypted = await encryptCredential(env, value.key);
	const timestamp = new Date().toISOString();
	await env.DB.prepare(
		`INSERT INTO openrouter_credentials (
			user_email,
			encrypted_api_key,
			initialization_vector,
			openrouter_user_id,
			connected_at,
			updated_at
		) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_email) DO UPDATE SET
			encrypted_api_key = excluded.encrypted_api_key,
			initialization_vector = excluded.initialization_vector,
			openrouter_user_id = excluded.openrouter_user_id,
			connected_at = excluded.connected_at,
			updated_at = excluded.updated_at`
	)
		.bind(
			email,
			encrypted.encryptedAPIKey,
			encrypted.initializationVector,
			typeof value.user_id === 'string' ? value.user_id : null,
			timestamp,
			timestamp
		)
		.run();
	return redirectWithOAuthResult(request, 'connected');
}

function redirectWithOAuthResult(request, result) {
	const destination = new URL('/', request.url);
	destination.searchParams.set('openrouter', result);
	return Response.redirect(destination.toString(), 302);
}

async function disconnect(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.prepare('DELETE FROM openrouter_credentials WHERE user_email = ?').bind(email).run();
	return json({ connected: false });
}

async function createSpeech(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid speech request.' }, { status: 400 });
	}
	if (
		typeof value.input !== 'string' ||
		!value.input.trim() ||
		value.input.length > maximumSpeechInputLength ||
		typeof value.voice !== 'string' ||
		!supportedVoices.has(value.voice)
	) {
		return json({ error: 'Invalid speech text or voice.' }, { status: 400 });
	}

	const credential = await env.DB.prepare(
		`SELECT encrypted_api_key, initialization_vector
		 FROM openrouter_credentials
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	if (!credential) return json({ error: 'OpenRouter is not connected.' }, { status: 401 });

	let apiKey;
	try {
		apiKey = await decryptCredential(
			env,
			credential.encrypted_api_key,
			credential.initialization_vector
		);
	} catch {
		return json({ error: 'The OpenRouter connection could not be opened.' }, { status: 500 });
	}

	const response = await fetch('https://openrouter.ai/api/v1/audio/speech', {
		method: 'POST',
		headers: {
			Authorization: `Bearer ${apiKey}`,
			'Content-Type': 'application/json',
			'X-Title': 'Shared Library'
		},
		body: JSON.stringify({
			model: openRouterModel,
			input: value.input,
			voice: value.voice,
			response_format: 'mp3'
		})
	});
	if (!response.ok) {
		return json(
			{ error: await openRouterError(response, `OpenRouter speech failed (${response.status}).`) },
			{ status: response.status }
		);
	}

	const headers = new Headers({
		'Content-Type': response.headers.get('Content-Type') || 'audio/mpeg',
		'Cache-Control': 'private, no-store'
	});
	const generationID = response.headers.get('X-Generation-Id');
	if (generationID) headers.set('X-Generation-Id', generationID);
	return new Response(response.body, { status: 200, headers });
}

const worker = {
	async fetch(request, env) {
		const url = new URL(request.url);

		if (url.pathname === '/api/openrouter/status' && request.method === 'GET') {
			return connectionStatus(request, env);
		}
		if (url.pathname === '/api/openrouter/connect/start' && request.method === 'GET') {
			return startConnection(request, env);
		}
		if (url.pathname === '/api/openrouter/connect/callback' && request.method === 'GET') {
			return finishConnection(request, env);
		}
		if (url.pathname === '/api/openrouter/disconnect' && request.method === 'POST') {
			return disconnect(request, env);
		}
		if (url.pathname === '/api/tts' && request.method === 'POST') {
			return createSpeech(request, env);
		}
		if (url.pathname.startsWith('/api/')) {
			return json({ error: 'Not found.' }, { status: 404 });
		}

		const response = await env.ASSETS.fetch(request);
		if (response.status !== 404 || request.method !== 'GET') return response;
		const acceptsHTML = request.headers.get('accept')?.includes('text/html') ?? false;
		if (!acceptsHTML) return response;
		return env.ASSETS.fetch(new Request(new URL('/', request.url), request));
	}
};

export default worker;
