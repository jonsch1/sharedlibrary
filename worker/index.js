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

function googleCloudProjectNumber(clientID) {
	const match = /^(\d+)(?:-|\.apps\.googleusercontent\.com$)/.exec(clientID ?? '');
	return match?.[1] ?? null;
}

function configuredGroupFolderID(env) {
	const value = String(env.SHARED_LIBRARY_GROUP_FOLDER_ID || '').trim();
	return /^[A-Za-z0-9_-]{10,256}$/.test(value) ? value : null;
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

async function sha256Hex(value) {
	const input =
		typeof value === 'string'
			? new TextEncoder().encode(value)
			: value instanceof Uint8Array
				? value
				: new Uint8Array(value);
	const digest = new Uint8Array(
		await crypto.subtle.digest('SHA-256', input)
	);
	return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
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
			),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS google_drive_connections (
				user_email TEXT PRIMARY KEY NOT NULL,
				client_id TEXT NOT NULL,
				encrypted_client_secret TEXT NOT NULL,
				client_secret_iv TEXT NOT NULL,
				encrypted_access_token TEXT,
				access_token_iv TEXT,
				encrypted_refresh_token TEXT,
				refresh_token_iv TEXT,
				access_token_expires_at INTEGER,
				folder_id TEXT,
				connected_at TEXT,
				updated_at TEXT NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS google_oauth_states (
				state TEXT PRIMARY KEY NOT NULL,
				user_email TEXT NOT NULL,
				code_verifier TEXT NOT NULL,
				created_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS shared_folder_connections (
				user_email TEXT PRIMARY KEY NOT NULL,
				folder_id TEXT NOT NULL,
				user_id TEXT NOT NULL,
				username TEXT NOT NULL,
				connected_at TEXT NOT NULL,
				updated_at TEXT NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS sharing_operations (
				user_email TEXT NOT NULL,
				capture_id TEXT NOT NULL,
				recipient_ids TEXT NOT NULL,
				generation TEXT NOT NULL,
				status TEXT NOT NULL,
				attempt_count INTEGER NOT NULL DEFAULT 0,
				last_error TEXT,
				created_at TEXT NOT NULL,
				updated_at TEXT NOT NULL,
				PRIMARY KEY (user_email, capture_id)
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

async function fetchLibrarySnapshot(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set(
		'q',
		"appProperties has { key='sharedLibraryKind' and value='library-index' } and trashed=false"
	);
	listURL.searchParams.set('fields', 'files(id,name,mimeType)');
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) {
		return json(
			{ error: response.status === 401 ? 'Connect Google Drive first.' : 'Google Drive could not be searched.' },
			{ status: response.status }
		);
	}
	const value = await response.json();
	const file = value.files?.[0];
	if (!file) {
		return json(
			{ error: 'Google Drive does not contain the library index yet. Open the Mac app and let it synchronize.' },
			{ status: 404 }
		);
	}
	response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(file.id)}?alt=media`
	);
	if (response.status === 404) {
		return json(
			{ error: 'The Google Drive library could not be found. Open the Mac app and let it upload again.' },
			{ status: 404 }
		);
	}
	if (!response.ok) {
		let value;
		try {
			value = await response.json();
		} catch {
			value = {};
		}
		return json({ error: value.message || 'The Google Drive library could not be downloaded.' }, { status: response.status });
	}
	return new Response(response.body, {
		headers: {
			'Content-Type': 'application/json',
			'Cache-Control': 'private, no-store'
		}
	});
}

function validLibraryPath(path) {
	return (
		typeof path === 'string' &&
		path.length > 0 &&
		path.length <= 1024 &&
		(path === 'topics.md' || path.startsWith('library/')) &&
		!path.split('/').some((component) => !component || component === '.' || component === '..')
	);
}

async function fetchLibraryFile(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const url = new URL(request.url);
	const path = url.searchParams.get('path');
	const expectedHash = url.searchParams.get('hash');
	if (!validLibraryPath(path) || !/^[a-f0-9]{64}$/.test(expectedHash || '')) {
		return json({ error: 'Invalid library file request.' }, { status: 400 });
	}

	const pathHash = await sha256Hex(path);
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set(
		'q',
		`appProperties has { key='sharedLibraryKind' and value='workspace' } and appProperties has { key='sharedLibraryPathHash' and value='${pathHash}' } and trashed=false`
	);
	listURL.searchParams.set(
		'fields',
		'files(id,mimeType,appProperties)'
	);
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) {
		return json({ error: 'Google Drive could not be searched.' }, { status: response.status });
	}
	const file = (await response.json()).files?.[0];
	if (!file || file.appProperties?.sharedLibraryContentHash !== expectedHash) {
		return json({ error: 'The requested library file is not available.' }, { status: 404 });
	}
	response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(file.id)}?alt=media`
	);
	if (!response.ok) {
		return json({ error: 'The library file could not be downloaded.' }, { status: response.status });
	}
	return new Response(response.body, {
		headers: {
			'Content-Type': file.mimeType || 'text/markdown; charset=utf-8',
			'Cache-Control': 'private, max-age=86400',
			'X-Content-Hash': expectedHash
		}
	});
}

function validGoogleClientID(value) {
	return (
		typeof value === 'string' &&
		value.length >= 20 &&
		value.length <= 256 &&
		value.endsWith('.apps.googleusercontent.com')
	);
}

function googleOAuthConfig(env) {
	const clientID = env.GOOGLE_DRIVE_WEB_CLIENT_ID?.trim();
	const clientSecret = env.GOOGLE_DRIVE_WEB_CLIENT_SECRET?.trim();
	if (!validGoogleClientID(clientID) || typeof clientSecret !== 'string' || clientSecret.length < 8) {
		return null;
	}
	return { clientID, clientSecret };
}

async function storedGoogleOAuthConfig(env, connection) {
	if (!connection?.client_id || !connection.encrypted_client_secret || !connection.client_secret_iv) {
		return null;
	}
	return {
		clientID: connection.client_id,
		clientSecret: await decryptCredential(
			env,
			connection.encrypted_client_secret,
			connection.client_secret_iv
		)
	};
}

async function googleDriveStatus(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ configured: false, connected: false }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await env.DB.prepare(
		`SELECT client_id, encrypted_refresh_token, connected_at
		 FROM google_drive_connections
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	const config = googleOAuthConfig(env) ?? (await storedGoogleOAuthConfig(env, connection));
	const appID = googleCloudProjectNumber(config?.clientID);
	const groupFolderID = configuredGroupFolderID(env);
	return json({
		configured: Boolean(config),
		connected: Boolean(connection?.encrypted_refresh_token),
		connectedAt: connection?.connected_at ?? undefined,
		callbackURL: new URL('/api/google/connect/callback', request.url).toString(),
		pickerConfigured: Boolean(appID),
		appID: appID ?? undefined,
		groupFolderConfigured: Boolean(groupFolderID)
	});
}

async function googleDrivePickerConfig(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await googleDriveConnection(env, email);
	if (!connection?.encrypted_refresh_token) {
		return json({ error: 'Connect Google Drive before choosing a shared folder.' }, { status: 409 });
	}
	const config = googleOAuthConfig(env) ?? (await storedGoogleOAuthConfig(env, connection));
	const appID = googleCloudProjectNumber(config?.clientID);
	if (!appID) {
		return json(
			{ error: 'Google Drive Picker is not configured for this deployment.' },
			{ status: 503 }
		);
	}
	const oauthToken = await googleAccessToken(env, email);
	if (!oauthToken) {
		return json({ error: 'Reconnect Google Drive before choosing a folder.' }, { status: 401 });
	}
	return json({
		appID,
		oauthToken,
		developerKey: env.GOOGLE_DRIVE_PICKER_API_KEY || undefined,
		folderID: configuredGroupFolderID(env) ?? undefined
	});
}

async function startGoogleDriveConnection(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await env.DB.prepare(
		`SELECT client_id, encrypted_client_secret, client_secret_iv
		 FROM google_drive_connections WHERE user_email = ?`
	)
		.bind(email)
		.first();
	const config = googleOAuthConfig(env) ?? (await storedGoogleOAuthConfig(env, connection));
	if (!config) {
		return json(
			{ error: 'Shared Library has not been configured with Google Drive OAuth yet.' },
			{ status: 503 }
		);
	}

	const state = randomBase64URL();
	const verifier = randomBase64URL(64);
	const challenge = await sha256Base64URL(verifier);
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM google_oauth_states WHERE created_at < ? OR user_email = ?')
			.bind(now - oauthStateLifetimeMilliseconds, email),
		env.DB
			.prepare(
				`INSERT INTO google_oauth_states (state, user_email, code_verifier, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(state, email, verifier, now)
	]);
	const callbackURL = new URL('/api/google/connect/callback', request.url);
	const authorizationURL = new URL('https://accounts.google.com/o/oauth2/v2/auth');
	authorizationURL.searchParams.set('client_id', config.clientID);
	authorizationURL.searchParams.set('redirect_uri', callbackURL.toString());
	authorizationURL.searchParams.set('response_type', 'code');
	authorizationURL.searchParams.set('scope', 'https://www.googleapis.com/auth/drive.file');
	authorizationURL.searchParams.set('access_type', 'offline');
	authorizationURL.searchParams.set('prompt', 'consent');
	authorizationURL.searchParams.set('state', state);
	authorizationURL.searchParams.set('code_challenge', challenge);
	authorizationURL.searchParams.set('code_challenge_method', 'S256');
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishGoogleDriveConnection(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const url = new URL(request.url);
	const state = url.searchParams.get('state');
	const code = url.searchParams.get('code');
	if (!state || !code) return redirectWithProviderResult(request, 'google', 'error');
	const pending = await env.DB.prepare(
		`SELECT user_email, code_verifier, created_at
		 FROM google_oauth_states WHERE state = ?`
	)
		.bind(state)
		.first();
	if (
		!pending ||
		pending.user_email !== email ||
		Date.now() - pending.created_at > oauthStateLifetimeMilliseconds
	) {
		return redirectWithProviderResult(request, 'google', 'expired');
	}
	const connection = await env.DB.prepare(
		`SELECT client_id, encrypted_client_secret, client_secret_iv
		 FROM google_drive_connections WHERE user_email = ?`
	)
		.bind(email)
		.first();
	const config = googleOAuthConfig(env) ?? (await storedGoogleOAuthConfig(env, connection));
	if (!config) return redirectWithProviderResult(request, 'google', 'error');
	const callbackURL = new URL('/api/google/connect/callback', request.url);
	const response = await fetch('https://oauth2.googleapis.com/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: config.clientID,
			client_secret: config.clientSecret,
			code,
			code_verifier: pending.code_verifier,
			grant_type: 'authorization_code',
			redirect_uri: callbackURL.toString()
		})
	});
	const value = await response.json();
	if (
		!response.ok ||
		typeof value.access_token !== 'string' ||
		typeof value.refresh_token !== 'string'
	) {
		return redirectWithProviderResult(request, 'google', 'error');
	}
	const encryptedAccess = await encryptCredential(env, value.access_token);
	const encryptedRefresh = await encryptCredential(env, value.refresh_token);
	const encryptedSecret = await encryptCredential(env, config.clientSecret);
	const timestamp = new Date().toISOString();
	await env.DB.batch([
		env.DB.prepare(
			`INSERT INTO google_drive_connections (
				user_email, client_id, encrypted_client_secret, client_secret_iv,
				encrypted_access_token, access_token_iv, encrypted_refresh_token,
				refresh_token_iv, access_token_expires_at, folder_id, connected_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
			ON CONFLICT(user_email) DO UPDATE SET
				client_id = excluded.client_id,
				encrypted_client_secret = excluded.encrypted_client_secret,
				client_secret_iv = excluded.client_secret_iv,
				encrypted_access_token = excluded.encrypted_access_token,
				access_token_iv = excluded.access_token_iv,
				encrypted_refresh_token = excluded.encrypted_refresh_token,
				refresh_token_iv = excluded.refresh_token_iv,
				access_token_expires_at = excluded.access_token_expires_at,
				connected_at = excluded.connected_at,
				updated_at = excluded.updated_at`
		).bind(
			email,
			config.clientID,
			encryptedSecret.encryptedAPIKey,
			encryptedSecret.initializationVector,
			encryptedAccess.encryptedAPIKey,
			encryptedAccess.initializationVector,
			encryptedRefresh.encryptedAPIKey,
			encryptedRefresh.initializationVector,
			Date.now() + Number(value.expires_in || 3600) * 1000,
			timestamp,
			timestamp,
		),
		env.DB.prepare('DELETE FROM google_oauth_states WHERE state = ?').bind(state)
	]);
	return redirectWithProviderResult(request, 'google', 'connected');
}

function redirectWithProviderResult(request, provider, result) {
	const destination = new URL('/', request.url);
	destination.searchParams.set(provider, result);
	return Response.redirect(destination.toString(), 302);
}

async function disconnectGoogleDrive(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM google_drive_connections WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM google_oauth_states WHERE user_email = ?').bind(email)
	]);
	return json({ configured: Boolean(googleOAuthConfig(env)), connected: false });
}

async function googleDriveConnection(env, email) {
	return env.DB.prepare(
		`SELECT client_id, encrypted_client_secret, client_secret_iv,
		        encrypted_access_token, access_token_iv, encrypted_refresh_token,
		        refresh_token_iv, access_token_expires_at, folder_id
		 FROM google_drive_connections WHERE user_email = ?`
	)
		.bind(email)
		.first();
}

async function googleAccessToken(env, email, forceRefresh = false) {
	const connection = await googleDriveConnection(env, email);
	if (!connection?.encrypted_refresh_token || !connection.refresh_token_iv) return null;
	const shouldRefresh =
		forceRefresh ||
		!connection.encrypted_access_token ||
		!connection.access_token_iv ||
		!connection.access_token_expires_at ||
		connection.access_token_expires_at <= Date.now() + 90_000;
	if (!shouldRefresh) {
		return decryptCredential(env, connection.encrypted_access_token, connection.access_token_iv);
	}
	const [clientSecret, refreshToken] = await Promise.all([
		Promise.resolve(googleOAuthConfig(env)?.clientSecret).then(
			(secret) =>
				secret ??
				decryptCredential(
					env,
					connection.encrypted_client_secret,
					connection.client_secret_iv
				)
		),
		decryptCredential(env, connection.encrypted_refresh_token, connection.refresh_token_iv)
	]);
	const clientID = googleOAuthConfig(env)?.clientID ?? connection.client_id;
	const response = await fetch('https://oauth2.googleapis.com/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: clientID,
			client_secret: clientSecret,
			refresh_token: refreshToken,
			grant_type: 'refresh_token'
		})
	});
	const value = await response.json();
	if (!response.ok || typeof value.access_token !== 'string') return null;
	const encrypted = await encryptCredential(env, value.access_token);
	await env.DB.prepare(
		`UPDATE google_drive_connections SET
			encrypted_access_token = ?, access_token_iv = ?,
			access_token_expires_at = ?, updated_at = ?
		 WHERE user_email = ?`
	)
		.bind(
			encrypted.encryptedAPIKey,
			encrypted.initializationVector,
			Date.now() + Number(value.expires_in || 3600) * 1000,
			new Date().toISOString(),
			email
		)
		.run();
	return value.access_token;
}

async function googleDriveRequest(env, email, url, init = {}) {
	for (const forceRefresh of [false, true]) {
		const token = await googleAccessToken(env, email, forceRefresh);
		if (!token) return new Response('Google Drive is not connected.', { status: 401 });
		const headers = new Headers(init.headers);
		headers.set('Authorization', `Bearer ${token}`);
		const response = await fetch(url, { ...init, headers });
		if (response.status === 401 && !forceRefresh) continue;
		return response;
	}
	return new Response('Google Drive connection expired.', { status: 401 });
}

async function findDriveMedia(env, email, media) {
	const query = `appProperties has { key='sharedLibraryHash' and value='${media.hash}' } and appProperties has { key='sharedLibraryKind' and value='${media.kind}' } and trashed=false`;
	const url = new URL('https://www.googleapis.com/drive/v3/files');
	url.searchParams.set('q', query);
	url.searchParams.set('fields', 'files(id,name,mimeType,size)');
	url.searchParams.set('pageSize', '1');
	const response = await googleDriveRequest(env, email, url);
	if (!response.ok) return { response };
	const value = await response.json();
	return { file: value.files?.[0] ?? null };
}

async function ensureDriveRootFolder(env, email) {
	const connection = await googleDriveConnection(env, email);
	if (connection?.folder_id) return connection.folder_id;
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set('fields', 'files(id)');
	listURL.searchParams.set('pageSize', '1');
	let folderID;
	let response;
	let value;
	for (const query of [
		"appProperties has { key='sharedLibraryRoot' and value='true' } and mimeType='application/vnd.google-apps.folder' and trashed=false",
		"name='Shared Library' and mimeType='application/vnd.google-apps.folder' and trashed=false",
		"name='Shared Library Media' and mimeType='application/vnd.google-apps.folder' and trashed=false"
	]) {
		listURL.searchParams.set('q', query);
		response = await googleDriveRequest(env, email, listURL);
		if (!response.ok) throw new Error(`Google Drive folder lookup failed (${response.status}).`);
		value = await response.json();
		folderID = value.files?.[0]?.id;
		if (folderID) break;
	}
	if (!folderID) {
		response = await googleDriveRequest(
			env,
			email,
			'https://www.googleapis.com/drive/v3/files?fields=id',
			{
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					name: 'Shared Library',
					mimeType: 'application/vnd.google-apps.folder',
					appProperties: { sharedLibraryRoot: 'true' }
				})
			}
		);
		if (!response.ok) throw new Error(`Google Drive folder creation failed (${response.status}).`);
		value = await response.json();
		folderID = value.id;
	}
	await env.DB.prepare(
		`UPDATE google_drive_connections SET folder_id = ?, updated_at = ? WHERE user_email = ?`
	)
		.bind(folderID, new Date().toISOString(), email)
		.run();
	return folderID;
}

async function ensureDriveMediaFolder(env, email) {
	const rootID = await ensureDriveRootFolder(env, email);
	const pathHash = await sha256Hex('audio');
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set(
		'q',
		`appProperties has { key='sharedLibraryKind' and value='folder' } and appProperties has { key='sharedLibraryPathHash' and value='${pathHash}' } and trashed=false`
	);
	listURL.searchParams.set('fields', 'files(id)');
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) throw new Error(`Google Drive audio folder lookup failed (${response.status}).`);
	let value = await response.json();
	if (value.files?.[0]?.id) return value.files[0].id;
	response = await googleDriveRequest(
		env,
		email,
		'https://www.googleapis.com/drive/v3/files?fields=id',
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'audio',
				mimeType: 'application/vnd.google-apps.folder',
				parents: [rootID],
				appProperties: {
					sharedLibraryKind: 'folder',
					sharedLibraryPathHash: pathHash
				}
			})
		}
	);
	if (!response.ok) throw new Error(`Google Drive audio folder creation failed (${response.status}).`);
	value = await response.json();
	return value.id;
}

function mediaPath(url) {
	const match = url.pathname.match(/^\/api\/media\/audio\/([a-f0-9]{64})$/);
	return match ? { kind: 'audio', hash: match[1] } : null;
}

async function listDriveAudio(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const files = [];
	let pageToken;
	do {
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set(
			'q',
			"appProperties has { key='sharedLibraryKind' and value='audio' } and trashed=false"
		);
		url.searchParams.set(
			'fields',
			'nextPageToken,files(id,mimeType,size,appProperties)'
		);
		url.searchParams.set('pageSize', '1000');
		if (pageToken) url.searchParams.set('pageToken', pageToken);
		const response = await googleDriveRequest(env, email, url);
		if (!response.ok) {
			return json(
				{ error: response.status === 401 ? 'Connect Google Drive first.' : 'Google Drive audio could not be listed.' },
				{ status: response.status }
			);
		}
		const value = await response.json();
		for (const file of value.files ?? []) {
			const hash = file.appProperties?.sharedLibraryHash;
			if (!/^[a-f0-9]{64}$/.test(hash || '')) continue;
			files.push({
				hash,
				byteCount: Number(file.size || 0),
				contentType: file.mimeType || 'audio/mpeg'
			});
		}
		pageToken = value.nextPageToken;
	} while (pageToken);
	return json({ files });
}

async function downloadDriveMedia(request, env, media) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const found = await findDriveMedia(env, email, media);
	if (found.response) return found.response;
	if (!found.file) return json({ error: 'Media is not stored in Google Drive.' }, { status: 404 });
	const response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(found.file.id)}?alt=media`,
		{
			headers: request.headers.get('Range') ? { Range: request.headers.get('Range') } : {}
		}
	);
	const headers = new Headers();
	for (const name of ['Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges']) {
		const value = response.headers.get(name);
		if (value) headers.set(name, value);
	}
	headers.set('Cache-Control', 'private, max-age=86400');
	return new Response(response.body, { status: response.status, headers });
}

async function uploadDriveMedia(request, env, media) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const contentLength = Number(request.headers.get('Content-Length') || 0);
	if (contentLength > 25_000_000) {
		return json({ error: 'Media files are limited to 25 MB.' }, { status: 413 });
	}
	const existing = await findDriveMedia(env, email, media);
	if (existing.response) return existing.response;
	if (existing.file) return json({ id: existing.file.id, existed: true });
	const contentType =
		request.headers.get('Content-Type') || 'audio/mpeg';
	if (!contentType.startsWith('audio/')) {
		return json({ error: 'Only audio media is supported.' }, { status: 400 });
	}
	const bytes = await request.arrayBuffer();
	if (!bytes.byteLength || bytes.byteLength > 25_000_000) {
		return json({ error: 'Media files must be between 1 byte and 25 MB.' }, { status: 413 });
	}
	const folderID = await ensureDriveMediaFolder(env, email);
	const metadata = JSON.stringify({
		name: `${media.hash}.mp3`,
		parents: [folderID],
		appProperties: {
			sharedLibraryHash: media.hash,
			sharedLibraryKind: media.kind
		}
	});
	const boundary = `SharedLibrary-${crypto.randomUUID()}`;
	const body = new Blob([
		`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n`,
		metadata,
		`\r\n--${boundary}\r\nContent-Type: ${contentType}\r\n\r\n`,
		bytes,
		`\r\n--${boundary}--\r\n`
	]);
	const response = await googleDriveRequest(
		env,
		email,
		'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id',
		{
			method: 'POST',
			headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
			body
		}
	);
	if (!response.ok) {
		return json({ error: `Google Drive upload failed (${response.status}).` }, { status: response.status });
	}
	const value = await response.json();
	return json({ id: value.id, existed: false });
}

function normalizedUsername(value) {
	return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

function validUsername(value) {
	const username = normalizedUsername(value);
	return /^[a-z0-9](?:[a-z0-9_-]{0,30}[a-z0-9])?$/.test(username);
}

function googleDriveFolderID(value) {
	if (typeof value !== 'string') return null;
	const trimmed = value.trim();
	if (!trimmed) return null;
	let candidate = trimmed;
	try {
		const url = new URL(trimmed);
		const components = url.pathname.split('/').filter(Boolean);
		const index = components.indexOf('folders');
		if (index >= 0 && components[index + 1]) candidate = components[index + 1];
	} catch {
		// A bare folder ID is also valid.
	}
	return /^[A-Za-z0-9_-]{10,256}$/.test(candidate) ? candidate : null;
}

async function sharedFolderConnection(env, email) {
	return env.DB.prepare(
		`SELECT folder_id, user_id, username, connected_at
		 FROM shared_folder_connections WHERE user_email = ?`
	)
		.bind(email)
		.first();
}

async function sharedFolderStatus(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ connected: false }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	return json({
		connected: Boolean(connection),
		folderID: connection?.folder_id ?? undefined,
		userID: connection?.user_id ?? undefined,
		username: connection?.username ?? undefined,
		connectedAt: connection?.connected_at ?? undefined
	});
}

function validSharedPath(path) {
	if (path === 'people.json') return true;
	if (typeof path !== 'string' || path.length > 2048) return false;
	const components = path.split('/');
	if (components.length !== 2 || components.some((component) => !component)) return false;
	if (components[0] === 'library') return components[1].endsWith('.md');
	if (components[0] === 'shares') return components[1].endsWith('.json');
	return false;
}

async function driveFolderMetadata(env, email, folderID) {
	const url = new URL(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(folderID)}`);
	url.searchParams.set('fields', 'id,name,mimeType,capabilities(canEdit)');
	url.searchParams.set('supportsAllDrives', 'true');
	const response = await googleDriveRequest(env, email, url);
	if (!response.ok) {
		throw new Error(
			response.status === 404
				? 'Google Drive has not granted Shared Library access to that folder. Choose it with the folder picker, then try again.'
				: `The shared Google Drive folder could not be opened (${response.status}).`
		);
	}
	const folder = await response.json();
	if (folder.mimeType !== 'application/vnd.google-apps.folder') {
		throw new Error('The sharing location must be a Google Drive folder.');
	}
	if (folder.capabilities?.canEdit === false) {
		throw new Error('You need edit access to the shared Google Drive folder.');
	}
	return folder;
}

async function driveFolderChildren(env, email, parentID) {
	const files = [];
	let pageToken;
	do {
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set(
			'q',
			`'${String(parentID).replaceAll("'", "\\'")}' in parents and trashed=false`
		);
		url.searchParams.set(
			'fields',
			'nextPageToken,files(id,name,mimeType,parents,modifiedTime,appProperties)'
		);
		url.searchParams.set('pageSize', '1000');
		url.searchParams.set('supportsAllDrives', 'true');
		url.searchParams.set('includeItemsFromAllDrives', 'true');
		if (pageToken) url.searchParams.set('pageToken', pageToken);
		const response = await googleDriveRequest(env, email, url);
		if (!response.ok) {
			throw new Error(`The shared Google Drive folder could not be listed (${response.status}).`);
		}
		const value = await response.json();
		files.push(...(value.files ?? []));
		pageToken = value.nextPageToken;
	} while (pageToken);
	return files;
}

async function driveFolderTree(
	env,
	email,
	rootFolderID,
	allowedPath = validSharedPath,
	includeHiddenFolders = false
) {
	const folders = new Map([['', rootFolderID]]);
	const files = new Map();
	const queue = [{ path: '', id: rootFolderID }];
	for (let index = 0; index < queue.length; index += 1) {
		const parent = queue[index];
		for (const item of await driveFolderChildren(env, email, parent.id)) {
			if (
				typeof item.name !== 'string' ||
				!item.name ||
				item.name === '.' ||
				item.name === '..' ||
				item.name.includes('/')
			) {
				continue;
			}
			const path = parent.path ? `${parent.path}/${item.name}` : item.name;
			if (item.mimeType === 'application/vnd.google-apps.folder') {
				if (!includeHiddenFolders && path.startsWith('.')) continue;
				folders.set(path, item.id);
				queue.push({ path, id: item.id });
			} else if (allowedPath(path)) {
				files.set(path, { ...item, path });
			}
		}
	}
	return { folders, files };
}

async function shallowSharedTree(env, email, rootFolderID) {
	const folders = new Map([['', rootFolderID]]);
	const files = new Map();
	const rootChildren = await driveFolderChildren(env, email, rootFolderID);
	for (const item of rootChildren) {
		if (item.mimeType === 'application/vnd.google-apps.folder') {
			if (item.name === 'library' || item.name === 'shares') folders.set(item.name, item.id);
		} else if (item.name === 'people.json') {
			files.set('people.json', { ...item, path: 'people.json' });
		}
	}
	await Promise.all(
		['library', 'shares'].map(async (directory) => {
			const folderID = folders.get(directory);
			if (!folderID) return;
			for (const item of await driveFolderChildren(env, email, folderID)) {
				if (item.mimeType === 'application/vnd.google-apps.folder') continue;
				const path = `${directory}/${item.name}`;
				if (validSharedPath(path)) files.set(path, { ...item, path });
			}
		})
	);
	return { folders, files };
}

async function downloadDriveFile(env, email, fileID) {
	const response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileID)}?alt=media&supportsAllDrives=true`
	);
	if (!response.ok) {
		throw new Error(`A shared file could not be downloaded (${response.status}).`);
	}
	return new Uint8Array(await response.arrayBuffer());
}

function driveContentType(path) {
	if (path.endsWith('.json')) return 'application/json';
	if (path.endsWith('.md') || path.endsWith('.markdown')) return 'text/markdown';
	if (path.endsWith('.mp3')) return 'audio/mpeg';
	if (path.endsWith('.m4a')) return 'audio/mp4';
	return 'application/octet-stream';
}

async function ensureDrivePath(env, email, rootFolderID, folders, path) {
	if (!path) return rootFolderID;
	let parentID = rootFolderID;
	let currentPath = '';
	for (const component of path.split('/')) {
		currentPath = currentPath ? `${currentPath}/${component}` : component;
		const existing = folders.get(currentPath);
		if (existing) {
			parentID = existing;
			continue;
		}
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set('fields', 'id');
		url.searchParams.set('supportsAllDrives', 'true');
		const response = await googleDriveRequest(env, email, url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: component,
				mimeType: 'application/vnd.google-apps.folder',
				parents: [parentID],
				appProperties: {
					sharedLibraryKind: 'shared-folder',
					sharedLibraryPathHash: await sha256Hex(currentPath)
				}
			})
		});
		if (!response.ok) {
			throw new Error(`A shared Google Drive folder could not be created (${response.status}).`);
		}
		parentID = (await response.json()).id;
		folders.set(currentPath, parentID);
	}
	return parentID;
}

async function upsertDriveFile(
	env,
	email,
	{ rootFolderID, folders, path, bytes, existingID = null, kind = 'shared-workspace' }
) {
	const components = path.split('/');
	const name = components.pop();
	const parentID = existingID
		? null
		: await ensureDrivePath(env, email, rootFolderID, folders, components.join('/'));
	const contentHash = await sha256Hex(bytes);
	const metadata = {
		name,
		appProperties: {
			sharedLibraryKind: kind,
			sharedLibraryPathHash: await sha256Hex(path),
			sharedLibraryContentHash: contentHash
		}
	};
	if (!existingID) metadata.parents = [parentID];
	const boundary = `SharedLibrary-${crypto.randomUUID()}`;
	const body = new Blob([
		`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n`,
		JSON.stringify(metadata),
		`\r\n--${boundary}\r\nContent-Type: ${driveContentType(path)}\r\n\r\n`,
		bytes,
		`\r\n--${boundary}--\r\n`
	]);
	const uploadURL = existingID
		? `https://www.googleapis.com/upload/drive/v3/files/${encodeURIComponent(existingID)}?uploadType=multipart&fields=id&supportsAllDrives=true`
		: 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id&supportsAllDrives=true';
	const response = await googleDriveRequest(env, email, uploadURL, {
		method: existingID ? 'PATCH' : 'POST',
		headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
		body
	});
	if (!response.ok) {
		throw new Error(`A Google Drive file could not be saved (${response.status}).`);
	}
	return { id: (await response.json()).id, contentHash, byteCount: bytes.byteLength };
}

async function trashDriveFile(env, email, fileID) {
	const response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileID)}?supportsAllDrives=true`,
		{
			method: 'PATCH',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ trashed: true })
		}
	);
	if (!response.ok) {
		throw new Error(`A shared Google Drive file could not be removed (${response.status}).`);
	}
}

async function registerSharedProfile(env, email, rootFolderID, username, existingUserID) {
	const tree = await shallowSharedTree(env, email, rootFolderID);
	const peopleFile = tree.files.get('people.json');
	let people = [];
	if (peopleFile) {
		try {
			const document = JSON.parse(
				new TextDecoder().decode(await downloadDriveFile(env, email, peopleFile.id))
			);
			if (document?.schemaVersion !== 2 || !Array.isArray(document.people)) {
				throw new Error('The shared people directory is not version 2.');
			}
			people = document.people;
		} catch (error) {
			throw new Error(
				error instanceof Error ? error.message : 'The shared people directory is invalid.'
			);
		}
	}
	const userID = validSharedUserID(existingUserID)
		? existingUserID
		: crypto.randomUUID().toLowerCase();
	const taken = people.find(
		(person) =>
			normalizedUsername(person?.username) === username &&
			person?.userID !== userID
	);
	if (taken) throw new Error(`@${username} is already used by another person.`);
	const now = new Date().toISOString();
	people = people
		.filter((person) => person?.userID !== userID)
		.concat({ userID, username, updatedAt: now })
		.sort((a, b) => normalizedUsername(a.username).localeCompare(normalizedUsername(b.username)));
	const document = new TextEncoder().encode(
		JSON.stringify(
			{ schemaVersion: 2, people, updatedAt: now },
			null,
			2
		)
	);
	await upsertDriveFile(env, email, {
		rootFolderID,
		folders: tree.folders,
		path: 'people.json',
		bytes: document,
		existingID: peopleFile?.id ?? null
	});
	await Promise.all([
		ensureDrivePath(env, email, rootFolderID, tree.folders, 'library'),
		ensureDrivePath(env, email, rootFolderID, tree.folders, 'shares')
	]);
	return userID;
}

async function connectSharedFolder(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid connection request.' }, { status: 400 });
	}
	const folderID = googleDriveFolderID(value?.folder);
	const username = normalizedUsername(value?.username);
	if (!folderID) return json({ error: 'Choose a valid Google Drive folder.' }, { status: 400 });
	const groupFolderID = configuredGroupFolderID(env);
	if (groupFolderID && folderID !== groupFolderID) {
		return json(
			{ error: 'Choose the predefined Shared Library group folder.' },
			{ status: 400 }
		);
	}
	if (!validUsername(username)) {
		return json(
			{ error: 'Use 2–32 letters, numbers, hyphens, or underscores for the username.' },
			{ status: 400 }
		);
	}
	try {
		const folder = await driveFolderMetadata(env, email, folderID);
		const existingConnection = await sharedFolderConnection(env, email);
		const userID = await registerSharedProfile(
			env,
			email,
			folderID,
			username,
			existingConnection?.user_id
		);
		const now = new Date().toISOString();
		await env.DB.prepare(
			`INSERT INTO shared_folder_connections (
				user_email, folder_id, user_id, username, connected_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(user_email) DO UPDATE SET
				folder_id = excluded.folder_id,
				user_id = excluded.user_id,
				username = excluded.username,
				updated_at = excluded.updated_at`
		)
			.bind(email, folderID, userID, username, now, now)
			.run();
		return json({ connected: true, folderID, folderName: folder.name, userID, username });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The shared folder could not be connected.' },
			{ status: 400 }
		);
	}
}

async function disconnectSharedFolder(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM sharing_operations WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM shared_folder_connections WHERE user_email = ?').bind(email)
	]);
	return json({ disconnected: true });
}

function parsedMarkdownDocument(text, fallbackTitle) {
	let title = fallbackTitle;
	let body = text;
	let captureID;
	let sourceURL;
	let topicIDs = [];
	let tags = [];
	let createdAt;
	if (text.startsWith('---')) {
		const end = text.indexOf('\n---', 3);
		if (end >= 0) {
			const frontmatter = text.slice(3, end);
			body = text.slice(end + 4).trim();
			const scalar = (name) => {
				const match = frontmatter.match(new RegExp(`^${name}:\\s*[\"']?([^\\n\"']+)[\"']?\\s*$`, 'm'));
				return match?.[1]?.trim();
			};
			title = scalar('title') || title;
			captureID = scalar('id');
			sourceURL = scalar('source_url');
			createdAt = scalar('created_at');
			const tagLine = scalar('tags');
			if (tagLine?.startsWith('[')) {
				try {
					tags = JSON.parse(tagLine.replaceAll("'", '"'));
				} catch {
					tags = [];
				}
			}
			const topicsBlock = frontmatter.match(/^topics:\s*\n((?:\s+-[^\n]+\n?)*)/m)?.[1] ?? '';
			topicIDs = [...topicsBlock.matchAll(/^\s+-\s*[\"']?([^\"'\n]+)[\"']?\s*$/gm)].map(
				(match) => match[1].trim()
			);
		}
	}
	return {
		title,
		body,
		captureID,
		sourceURL,
		topicIDs,
		topicNames: topicIDs,
		tags: Array.isArray(tags) ? tags.filter((tag) => typeof tag === 'string') : [],
		createdAt,
		excerpt: body.replace(/\s+/g, ' ').trim().slice(0, 260)
	};
}

function validCaptureIdentifier(value) {
	return (
		typeof value === 'string' &&
		value.length >= 1 &&
		value.length <= 256 &&
		/^[a-zA-Z0-9:_-]+$/.test(value)
	);
}

function validSharedUserID(value) {
	return (
		typeof value === 'string' &&
		value.length >= 1 &&
		value.length <= 128 &&
		/^[a-zA-Z0-9_-]+$/.test(value)
	);
}

async function loadSharedPeople(env, email, tree) {
	const file = tree.files.get('people.json');
	if (!file) return [];
	let document;
	try {
		document = JSON.parse(
			new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
		);
	} catch {
		throw new Error('The shared people directory is invalid.');
	}
	if (document?.schemaVersion !== 2 || !Array.isArray(document.people)) {
		throw new Error('The shared people directory is not version 2.');
	}
	const people = document.people
		.filter(
			(profile) =>
				validSharedUserID(profile?.userID) &&
				validUsername(profile?.username)
		)
		.map((profile) => ({
			userID: profile.userID,
			username: normalizedUsername(profile.username)
		}));
	return [...new Map(people.map((person) => [person.userID, person])).values()].sort(
		(a, b) => a.username.localeCompare(b.username)
	);
}

async function loadPersonalSharingItem(env, email, captureID, includeFiles = false) {
	const indexFile = await driveFileByKind(env, email, 'library-index');
	if (!indexFile) {
		throw new Error('Your personal library has not synchronized to Google Drive yet.');
	}
	let index;
	try {
		index = JSON.parse(
			new TextDecoder().decode(await downloadDriveFile(env, email, indexFile.id))
		);
	} catch {
		throw new Error('The personal library index in Google Drive is invalid.');
	}
	const entry = Array.isArray(index?.entries)
		? index.entries.find(
				(candidate) =>
					candidate?.origin === 'personal' &&
					(candidate.captureID === captureID || candidate.id === captureID)
			)
		: null;
	if (!entry) throw new Error('This document is no longer in your personal library.');
	const sourceReference = Array.isArray(entry.texts)
		? entry.texts.find(
				(text) =>
					text?.variant === 'source' &&
					typeof text.path === 'string' &&
					/^library\/[^/]+$/.test(text.path)
			)
		: null;
	if (!sourceReference) {
		throw new Error('This document has no synchronized source file to share.');
	}
	if (!includeFiles) return { entry, sourcePath: sourceReference.path, files: [] };
	const personalRootID = await ensureDriveRootFolder(env, email);
	const tree = await driveFolderTree(
		env,
		email,
		personalRootID,
		personalWorkspacePath,
		true
	);
	const paths = [
		...new Set(
			entry.texts
				.map((text) => text?.path)
				.filter((path) => typeof path === 'string' && personalWorkspacePath(path))
		)
	];
	const files = paths
		.map((path) => ({ path, file: tree.files.get(path) }))
		.filter((item) => item.file);
	if (!files.some((item) => item.path === sourceReference.path)) {
		throw new Error('The source file has not synchronized to Google Drive yet.');
	}
	return { entry, sourcePath: sourceReference.path, files };
}

async function sharedItemID(captureID) {
	if (validSharedUserID(captureID)) return captureID.toLowerCase();
	return (await sha256Hex(captureID)).slice(0, 32);
}

async function sharingReferenceForItem(env, email, tree, itemID) {
	const file = tree.files.get(`shares/${itemID}.json`);
	if (!file) return null;
	try {
		const reference = JSON.parse(
			new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
		);
		return reference?.schemaVersion === 2 &&
			reference.id === itemID &&
			reference.itemID === itemID &&
			reference.contentPath === `library/${itemID}.source.md` &&
			Array.isArray(reference.sharedWithIDs)
			? reference
			: null;
	} catch {
		throw new Error('The sharing record for this document is invalid.');
	}
}

async function sharedItemContext(env, email, connection, captureID, includePersonalFiles = false) {
	const itemID = await sharedItemID(captureID);
	const [personal, tree] = await Promise.all([
		loadPersonalSharingItem(env, email, captureID, includePersonalFiles),
		shallowSharedTree(env, email, connection.folder_id)
	]);
	const [people, reference] = await Promise.all([
		loadSharedPeople(env, email, tree),
		sharingReferenceForItem(env, email, tree, itemID)
	]);
	return { itemID, personal, tree, people, reference };
}

function sharedCompanionPaths(itemID) {
	return [
		`library/${itemID}.source.md`,
		`library/${itemID}.brief.md`,
		`library/${itemID}.concise.md`,
		`library/${itemID}.detailed.md`,
		`library/${itemID}.comprehensive.md`
	];
}

async function sharingOperation(env, email, captureID) {
	return env.DB.prepare(
		`SELECT capture_id, recipient_ids, generation, status, attempt_count, last_error, updated_at
		 FROM sharing_operations
		 WHERE user_email = ? AND capture_id = ?`
	)
		.bind(email, captureID)
		.first();
}

function sharingOperationRecipientIDs(operation) {
	try {
		const values = JSON.parse(operation?.recipient_ids ?? '[]');
		return Array.isArray(values) ? values.filter(validSharedUserID) : [];
	} catch {
		return [];
	}
}

async function enqueueSharingOperation(env, email, captureID, recipientIDs) {
	const now = new Date().toISOString();
	const generation = crypto.randomUUID();
	await env.DB.prepare(
		`INSERT INTO sharing_operations (
			user_email, capture_id, recipient_ids, generation, status,
			attempt_count, last_error, created_at, updated_at
		) VALUES (?, ?, ?, ?, 'queued', 0, NULL, ?, ?)
		ON CONFLICT(user_email, capture_id) DO UPDATE SET
			recipient_ids = excluded.recipient_ids,
			generation = excluded.generation,
			status = CASE
				WHEN sharing_operations.status = 'syncing' THEN 'syncing'
				ELSE 'queued'
			END,
			attempt_count = 0,
			last_error = NULL,
			updated_at = excluded.updated_at`
	)
		.bind(email, captureID, JSON.stringify(recipientIDs), generation, now, now)
		.run();
	return sharingOperation(env, email, captureID);
}

function scheduleSharingOperation(context, task) {
	if (context && typeof context.waitUntil === 'function') {
		context.waitUntil(task);
		return;
	}
	void task.catch(() => {});
}

async function performSharedItemUpdate(env, email, captureID, requestedIDs) {
	const connection = await sharedFolderConnection(env, email);
	if (!connection) throw new Error('Connect the shared folder first.');
	const { itemID, personal, tree, people, reference: existing } = await sharedItemContext(
		env,
		email,
		connection,
		captureID,
		true
	);
	const peopleByID = new Map(people.map((person) => [person.userID, person]));
	const recipients = requestedIDs
		.filter((id) => id !== connection.user_id)
		.map((id) => peopleByID.get(id));
	if (recipients.some((person) => !person)) {
		throw new Error('One or more people are no longer available in the shared folder.');
	}
	recipients.sort((a, b) => a.username.localeCompare(b.username));
	if (existing && existing.sharedByID !== connection.user_id) {
		throw new Error('This shared item is owned by another person.');
	}
	const now = new Date().toISOString();
	const referencePath = `shares/${itemID}.json`;
	const companionPaths = sharedCompanionPaths(itemID);
	if (recipients.length === 0) {
		await Promise.all(
			[referencePath, ...companionPaths]
				.map((path) => tree.files.get(path))
				.filter(Boolean)
				.map((file) => trashDriveFile(env, email, file.id))
		);
		return {
			shared: false,
			recipientIDs: [],
			people: people.filter((person) => person.userID !== connection.user_id)
		};
	}

	const personalFiles = new Map(personal.files.map((item) => [item.path, item.file]));
	const desired = [];
	for (const text of personal.entry.texts ?? []) {
		if (
			!['source', 'brief', 'concise', 'detailed', 'comprehensive'].includes(text?.variant) ||
			typeof text?.path !== 'string'
		) {
			continue;
		}
		const file = personalFiles.get(text.path);
		if (!file) continue;
		desired.push({
			path: `library/${itemID}.${text.variant}.md`,
			file
		});
	}
	if (!desired.some((item) => item.path === `library/${itemID}.source.md`)) {
		throw new Error('The source file has not synchronized to Google Drive yet.');
	}
	const desiredPaths = new Set(desired.map((item) => item.path));
	await Promise.all(
		companionPaths
			.filter((path) => !desiredPaths.has(path))
			.map((path) => tree.files.get(path))
			.filter(Boolean)
			.map((file) => trashDriveFile(env, email, file.id))
	);
	await ensureDrivePath(env, email, connection.folder_id, tree.folders, 'library');
	await ensureDrivePath(env, email, connection.folder_id, tree.folders, 'shares');
	for (const item of desired) {
		const bytes = await downloadDriveFile(env, email, item.file.id);
		await upsertDriveFile(env, email, {
			rootFolderID: connection.folder_id,
			folders: tree.folders,
			path: item.path,
			bytes,
			existingID: tree.files.get(item.path)?.id ?? null
		});
	}

	const sharedReference = {
		schemaVersion: 2,
		id: itemID,
		itemID,
		contentPath: `library/${itemID}.source.md`,
		sourceFilename: personal.sourcePath.split('/').at(-1),
		sharedByID: connection.user_id,
		sharedWithIDs: recipients.map((person) => person.userID),
		revision: (existing?.revision ?? 0) + 1,
		createdAt: existing?.createdAt ?? now,
		updatedAt: now
	};
	const referenceBytes = new TextEncoder().encode(JSON.stringify(sharedReference, null, 2));
	await upsertDriveFile(env, email, {
		rootFolderID: connection.folder_id,
		folders: tree.folders,
		path: referencePath,
		bytes: referenceBytes,
		existingID: tree.files.get(referencePath)?.id ?? null
	});
	return {
		shared: true,
		referenceID: itemID,
		recipientIDs: recipients.map((person) => person.userID),
		people: people.filter((person) => person.userID !== connection.user_id)
	};
}

async function processSharingOperation(env, email, captureID) {
	for (let iteration = 0; iteration < 4; iteration += 1) {
		const operation = await sharingOperation(env, email, captureID);
		if (!operation || operation.status === 'failed' || operation.status === 'syncing') return;
		const generation = operation.generation;
		const startedAt = new Date().toISOString();
		const claim = await env.DB.prepare(
			`UPDATE sharing_operations
			 SET status = 'syncing', attempt_count = attempt_count + 1, updated_at = ?
			 WHERE user_email = ? AND capture_id = ? AND generation = ? AND status = 'queued'`
		)
			.bind(startedAt, email, captureID, generation)
			.run();
		if (Number(claim?.meta?.changes ?? 0) === 0) return;

		try {
			await performSharedItemUpdate(
				env,
				email,
				captureID,
				sharingOperationRecipientIDs(operation)
			);
			const completed = await env.DB.prepare(
				`DELETE FROM sharing_operations
				 WHERE user_email = ? AND capture_id = ? AND generation = ?`
			)
				.bind(email, captureID, generation)
				.run();
			if (Number(completed?.meta?.changes ?? 0) > 0) return;
			await env.DB.prepare(
				`UPDATE sharing_operations
				 SET status = 'queued', updated_at = ?
				 WHERE user_email = ? AND capture_id = ? AND status = 'syncing'`
			)
				.bind(new Date().toISOString(), email, captureID)
				.run();
		} catch (error) {
			const message =
				error instanceof Error ? error.message : 'The document could not be shared.';
			const failed = await env.DB.prepare(
				`UPDATE sharing_operations
				 SET status = 'failed', last_error = ?, updated_at = ?
				 WHERE user_email = ? AND capture_id = ? AND generation = ?`
			)
				.bind(message, new Date().toISOString(), email, captureID, generation)
				.run();
			if (Number(failed?.meta?.changes ?? 0) > 0) return;
			await env.DB.prepare(
				`UPDATE sharing_operations
				 SET status = 'queued', updated_at = ?
				 WHERE user_email = ? AND capture_id = ? AND status = 'syncing'`
			)
				.bind(new Date().toISOString(), email, captureID)
				.run();
		}
	}
}

async function resumeSharingOperation(env, email, captureID, operation, context) {
	let resumable = operation;
	if (
		resumable?.status === 'syncing' &&
		Date.now() - Date.parse(resumable.updated_at ?? '') > 2 * 60 * 1000
	) {
		await env.DB.prepare(
			`UPDATE sharing_operations
			 SET status = 'queued', updated_at = ?
			 WHERE user_email = ? AND capture_id = ? AND generation = ? AND status = 'syncing'`
		)
			.bind(new Date().toISOString(), email, captureID, resumable.generation)
			.run();
		resumable = await sharingOperation(env, email, captureID);
	}
	if (resumable?.status === 'queued') {
		scheduleSharingOperation(context, processSharingOperation(env, email, captureID));
	}
	return resumable;
}

async function sharedItemStatus(request, env, context) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect the shared folder first.' }, { status: 409 });
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	const pending = await resumeSharingOperation(
		env,
		email,
		captureID,
		await sharingOperation(env, email, captureID),
		context
	);
	try {
		const itemContext = await sharedItemContext(env, email, connection, captureID);
		const pendingRecipientIDs = pending
			? sharingOperationRecipientIDs(pending)
			: null;
		return json({
			shared: pending ? pendingRecipientIDs.length > 0 : Boolean(itemContext.reference),
			referenceID: itemContext.reference?.id,
			recipientIDs: pendingRecipientIDs ?? itemContext.reference?.sharedWithIDs ?? [],
			people: itemContext.people.filter((person) => person.userID !== connection.user_id),
			operationStatus: pending?.status,
			operationError: pending?.last_error ?? undefined
		});
	} catch (error) {
		if (pending) {
			const recipientIDs = sharingOperationRecipientIDs(pending);
			return json({
				shared: recipientIDs.length > 0,
				recipientIDs,
				people: [],
				operationStatus: pending.status,
				operationError:
					pending.last_error ??
					(error instanceof Error ? error.message : 'Sharing details could not be refreshed.')
			});
		}
		return json(
			{ error: error instanceof Error ? error.message : 'Sharing details could not be loaded.' },
			{ status: 400 }
		);
	}
}

async function sharedOperationStatus(request, env, context) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	const operation = await resumeSharingOperation(
		env,
		email,
		captureID,
		await sharingOperation(env, email, captureID),
		context
	);
	if (!operation) return json({ status: 'complete' });
	return json({
		status: operation.status,
		error: operation.last_error ?? undefined
	});
}

async function updateSharedItem(request, env, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect the shared folder first.' }, { status: 409 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid sharing request.' }, { status: 400 });
	}
	const captureID = value?.captureID;
	if (!validCaptureIdentifier(captureID) || !Array.isArray(value?.recipientIDs)) {
		return json({ error: 'Choose a valid document and recipients.' }, { status: 400 });
	}
	const requestedIDs = [...new Set(value.recipientIDs)];
	if (requestedIDs.length > 100 || requestedIDs.some((id) => !validSharedUserID(id))) {
		return json({ error: 'One or more sharing recipients are invalid.' }, { status: 400 });
	}
	const recipientIDs = requestedIDs.filter((id) => id !== connection.user_id);
	const operation = await enqueueSharingOperation(env, email, captureID, recipientIDs);
	scheduleSharingOperation(context, processSharingOperation(env, email, captureID));
	return json(
		{
			shared: recipientIDs.length > 0,
			referenceID: recipientIDs.length > 0 ? await sharedItemID(captureID) : undefined,
			recipientIDs,
			people: [],
			operationStatus: operation?.status === 'syncing' ? 'syncing' : 'queued'
		},
		{ status: 202 }
	);
}

async function loadSharedInboxProjection(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) {
		return json({ schemaVersion: 3, generatedAt: new Date().toISOString(), files: [], entries: [] });
	}
	try {
		const [tree, inboxContext] = await Promise.all([
			shallowSharedTree(env, email, connection.folder_id),
			loadPersonalInboxState(env, email)
		]);
		const people = await loadSharedPeople(env, email, tree);
		const usernames = new Map(people.map((person) => [person.userID, person.username]));
		const referenceFiles = [...tree.files.values()].filter(
			(file) => file.path.startsWith('shares/') && file.path.endsWith('.json')
		);
		const references = (
			await Promise.all(
				referenceFiles.map(async (file) => {
					try {
						const reference = JSON.parse(
							new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
						);
						if (
							reference?.schemaVersion === 2 &&
							validSharedUserID(reference.id) &&
							reference.itemID === reference.id &&
							reference.contentPath === `library/${reference.itemID}.source.md` &&
							Array.isArray(reference.sharedWithIDs) &&
							reference.sharedWithIDs.includes(connection.user_id)
						) {
							return reference;
						}
					} catch {
						// Malformed records are excluded from the derived Inbox.
					}
					return null;
				})
			)
		).filter(Boolean);
		const pendingReferences = references.filter((reference) => {
			const decision = inboxContext.state.shares?.[reference.id];
			return !decision || Number(decision.handledRevision ?? 0) < Number(reference.revision ?? 0);
		});
		const entries = (
			await Promise.all(
				pendingReferences.map(async (reference) => {
					const source = tree.files.get(reference.contentPath);
					if (!source) return null;
					const sourceText = new TextDecoder().decode(
						await downloadDriveFile(env, email, source.id)
					);
					const metadata = parsedMarkdownDocument(
						sourceText,
						String(reference.sourceFilename ?? reference.itemID).replace(/\.[^.]+$/, '')
					);
					const texts = await Promise.all(
						['brief', 'concise', 'detailed', 'comprehensive'].map(async (variant) => {
							const summary = tree.files.get(`library/${reference.itemID}.${variant}.md`);
							if (!summary) return null;
							return {
								variant,
								text: new TextDecoder().decode(
									await downloadDriveFile(env, email, summary.id)
								)
							};
						})
					);
					texts.push({ variant: 'source', text: metadata.body });
					return {
						id: `shared:${reference.id}`,
						captureID: metadata.captureID,
						title: metadata.title,
						excerpt: metadata.excerpt,
						topicIDs: metadata.topicIDs,
						topicNames: metadata.topicNames,
						tags: metadata.tags,
						sourceURL: metadata.sourceURL,
						createdAt: metadata.createdAt ?? reference.createdAt,
						updatedAt: reference.updatedAt,
						origin: 'shared',
						sharedByUsername: usernames.get(reference.sharedByID),
						inboxReferenceID: reference.id,
						texts: texts.filter(Boolean)
					};
				})
			)
		).filter(Boolean);
		entries.sort((a, b) => String(b.updatedAt ?? '').localeCompare(String(a.updatedAt ?? '')));
		return json({
			schemaVersion: 3,
			generatedAt: new Date().toISOString(),
			files: [],
			entries
		});
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The shared Inbox could not be loaded.' },
			{ status: 502 }
		);
	}
}

async function loadPersonalInboxState(env, email) {
	const rootFolderID = await ensureDriveRootFolder(env, email);
	const folders = new Map([['', rootFolderID]]);
	const rootChildren = await driveFolderChildren(env, email, rootFolderID);
	const controlFolder = rootChildren.find(
		(item) =>
			item.name === '.shared-library' &&
			item.mimeType === 'application/vnd.google-apps.folder'
	);
	let file = null;
	if (controlFolder) {
		folders.set('.shared-library', controlFolder.id);
		file = (await driveFolderChildren(env, email, controlFolder.id)).find(
			(item) =>
				item.name === 'inbox-state.json' &&
				item.mimeType !== 'application/vnd.google-apps.folder'
		) ?? null;
	}
	let state = {
		schemaVersion: 1,
		shares: {},
		updatedAt: new Date().toISOString()
	};
	if (file) {
		try {
			const value = JSON.parse(
				new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
			);
			if (value?.schemaVersion !== 1 || typeof value.shares !== 'object' || !value.shares) {
				throw new Error('The personal Inbox state is invalid.');
			}
			state = value;
		} catch (error) {
			throw new Error(
				error instanceof Error ? error.message : 'The personal Inbox state is invalid.'
			);
		}
	}
	return { rootFolderID, folders, file, state };
}

async function markPersonalInbox(env, email, reference, disposition) {
	const context = await loadPersonalInboxState(env, email);
	const now = new Date().toISOString();
	context.state.shares[reference.id] = {
		disposition,
		handledRevision: Number(reference.revision ?? 0),
		updatedAt: now
	};
	context.state.updatedAt = now;
	await upsertDriveFile(env, email, {
		rootFolderID: context.rootFolderID,
		folders: context.folders,
		path: '.shared-library/inbox-state.json',
		bytes: new TextEncoder().encode(JSON.stringify(context.state, null, 2)),
		existingID: context.file?.id ?? null,
		kind: 'workspace'
	});
}

async function sharedReferenceByID(env, email, connection, referenceID) {
	const tree = await shallowSharedTree(env, email, connection.folder_id);
	const file = tree.files.get(`shares/${referenceID}.json`);
	if (!file) throw new Error('This Inbox item is no longer available.');
	const reference = JSON.parse(
		new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
	);
	if (
		reference?.schemaVersion !== 2 ||
		reference.id !== referenceID ||
		reference.itemID !== referenceID ||
		!Array.isArray(reference.sharedWithIDs) ||
		!reference.sharedWithIDs.includes(connection.user_id)
	) {
		throw new Error('This Inbox reference is invalid.');
	}
	return { tree, reference };
}

async function dismissInboxReference(request, env, referenceID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect a shared folder first.' }, { status: 409 });
	try {
		const { reference } = await sharedReferenceByID(env, email, connection, referenceID);
		await markPersonalInbox(env, email, reference, 'dismissed');
		return json({ dismissed: true });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The Inbox item could not be dismissed.' },
			{ status: 400 }
		);
	}
}

/*
 * Inbox state deliberately lives in the recipient's personal workspace.
 * The shared folder contains only people.json, shares/*.json, and library/*.md.
 */

function rewriteCaptureID(sourceText, captureID, shareID, shareRevision) {
	if (!sourceText.startsWith('---')) return sourceText;
	const end = sourceText.indexOf('\n---', 3);
	if (end < 0) return sourceText;
	let updated = sourceText.slice(0, end);
	for (const [key, value] of [
		['id', captureID],
		['shared_from', shareID],
		['shared_revision', String(shareRevision)]
	]) {
		updated = new RegExp(`^${key}:`, 'm').test(updated)
			? updated.replace(new RegExp(`^${key}:.*$`, 'm'), `${key}: "${value}"`)
			: `${updated}\n${key}: "${value}"`;
	}
	return updated + sourceText.slice(end);
}

function personalWorkspacePath(path) {
	return (
		path === 'topics.md' ||
		path === '.shared-library/inbox-state.json' ||
		(path.startsWith('library/') && path.endsWith('.md'))
	);
}

async function driveFileByKind(env, email, kind) {
	const url = new URL('https://www.googleapis.com/drive/v3/files');
	url.searchParams.set(
		'q',
		`appProperties has { key='sharedLibraryKind' and value='${kind}' } and trashed=false`
	);
	url.searchParams.set('fields', 'files(id,name,mimeType,parents,appProperties)');
	url.searchParams.set('pageSize', '1');
	url.searchParams.set('supportsAllDrives', 'true');
	url.searchParams.set('includeItemsFromAllDrives', 'true');
	const response = await googleDriveRequest(env, email, url);
	if (!response.ok) throw new Error(`Google Drive could not find the library index (${response.status}).`);
	return (await response.json()).files?.[0] ?? null;
}

function wordCount(text) {
	return text.trim() ? text.trim().split(/\s+/).length : 0;
}

async function updatePersonalDriveIndexAfterInboxSave(
	env,
	email,
	{ personalRootID, personalTree, copied, captureID, sourceDestination, sourceText }
) {
	const currentIndexFile = await driveFileByKind(env, email, 'library-index');
	let index = {
		schemaVersion: 3,
		generatedAt: new Date().toISOString(),
		files: [],
		entries: []
	};
	if (currentIndexFile) {
		try {
			const value = JSON.parse(
				new TextDecoder().decode(await downloadDriveFile(env, email, currentIndexFile.id))
			);
			if (
				value?.schemaVersion === 3 &&
				Array.isArray(value.files) &&
				Array.isArray(value.entries)
			) {
				index = value;
			}
		} catch {
			// A fresh index is safer than publishing malformed metadata.
		}
	}
	const copiedPaths = new Set(copied.map((file) => file.path));
	index.files = [
		...index.files.filter((file) => !copiedPaths.has(file.path)),
		...copied.map((file) => ({
			path: file.path,
			contentHash: file.contentHash,
			byteCount: file.byteCount
		}))
	].sort((a, b) => a.path.localeCompare(b.path));
	const metadata = parsedMarkdownDocument(
		sourceText,
		sourceDestination.split('/').at(-1)?.replace(/\.[^.]+$/, '') || 'Shared item'
	);
	const texts = [];
	for (const file of copied) {
		let variant;
		if (file.path === sourceDestination) variant = 'source';
		else if (file.path.includes('/summaries/brief/')) variant = 'brief';
		else if (file.path.includes('/summaries/concise/')) variant = 'concise';
		else if (file.path.includes('/summaries/detailed/')) variant = 'detailed';
		else if (file.path.includes('/summaries/comprehensive/')) variant = 'comprehensive';
		else if (file.path.includes('/summaries/')) variant = 'concise';
		if (!variant || texts.some((text) => text.variant === variant)) continue;
		const text =
			variant === 'source'
				? metadata.body
				: new TextDecoder().decode(file.bytes);
		texts.push({
			variant,
			path: file.path,
			contentHash: file.contentHash,
			wordCount: wordCount(text)
		});
	}
	const entry = {
		id: `personal:${captureID}`,
		captureID,
		title: metadata.title,
		excerpt: metadata.excerpt,
		topicIDs: metadata.topicIDs,
		topicNames: metadata.topicNames,
		tags: metadata.tags,
		sourceURL: metadata.sourceURL,
		createdAt: metadata.createdAt,
		updatedAt: new Date().toISOString(),
		origin: 'personal',
		texts
	};
	index.entries = [
		...index.entries.filter(
			(candidate) => candidate.id !== entry.id && candidate.captureID !== captureID
		),
		entry
	].sort((a, b) => String(b.updatedAt ?? b.createdAt ?? '').localeCompare(
		String(a.updatedAt ?? a.createdAt ?? '')
	));
	index.schemaVersion = 3;
	index.generatedAt = new Date().toISOString();
	await upsertDriveFile(env, email, {
		rootFolderID: personalRootID,
		folders: personalTree.folders,
		path: '.shared-library/index.json',
		bytes: new TextEncoder().encode(JSON.stringify(index, null, 2)),
		existingID: currentIndexFile?.id ?? null,
		kind: 'library-index'
	});
}

async function saveInboxReference(request, env, referenceID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect a shared folder first.' }, { status: 409 });
	try {
		const { tree: sharedTree, reference } = await sharedReferenceByID(
			env,
			email,
			connection,
			referenceID
		);
		const sourceFile = sharedTree.files.get(reference.contentPath);
		if (!sourceFile) throw new Error('The shared source file is no longer available.');
		const personalRootID = await ensureDriveRootFolder(env, email);
		const personalTree = await driveFolderTree(
			env,
			email,
			personalRootID,
			personalWorkspacePath,
			true
		);
		const originalFilename =
			typeof reference.sourceFilename === 'string' &&
			/^[^/]+\.md$/i.test(reference.sourceFilename)
				? reference.sourceFilename
				: `${reference.itemID}.md`;
		const base = originalFilename.replace(/\.[^.]+$/, '');
		const extension = originalFilename.includes('.') ? `.${originalFilename.split('.').at(-1)}` : '';
		let filename = originalFilename;
		for (let index = 1; personalTree.files.has(`library/${filename}`); index += 1) {
			filename = `${base}${index === 1 ? '-shared' : `-shared-${index}`}${extension}`;
		}
		const captureID = crypto.randomUUID().toLowerCase();
		const copied = [];
		const sourceBytes = await downloadDriveFile(env, email, sourceFile.id);
		const rewrittenSource = new TextEncoder().encode(
			rewriteCaptureID(
				new TextDecoder().decode(sourceBytes),
				captureID,
				reference.id,
				reference.revision
			)
		);
		const sourceDestination = `library/${filename}`;
		copied.push({
			path: sourceDestination,
			bytes: rewrittenSource,
			...(await upsertDriveFile(env, email, {
				rootFolderID: personalRootID,
				folders: personalTree.folders,
				path: sourceDestination,
				bytes: rewrittenSource,
				kind: 'workspace'
			}))
		});
		for (const variant of ['brief', 'concise', 'detailed', 'comprehensive']) {
			const sourcePath = `library/${reference.itemID}.${variant}.md`;
			const summary = sharedTree.files.get(sourcePath);
			if (!summary) continue;
			const destination = `library/summaries/${variant}/${filename}`;
			const bytes = await downloadDriveFile(env, email, summary.id);
			copied.push({
				path: destination,
				bytes,
				...(await upsertDriveFile(env, email, {
					rootFolderID: personalRootID,
					folders: personalTree.folders,
					path: destination,
					bytes,
					kind: 'workspace'
				}))
			});
		}
		await updatePersonalDriveIndexAfterInboxSave(env, email, {
			personalRootID,
			personalTree,
			copied,
			captureID,
			sourceDestination,
			sourceText: new TextDecoder().decode(rewrittenSource)
		});
		await markPersonalInbox(env, email, reference, 'saved');
		return json({ saved: true, path: sourceDestination, captureID });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The Inbox item could not be saved.' },
			{ status: 400 }
		);
	}
}

const worker = {
	async fetch(request, env, context) {
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
		if (url.pathname === '/api/library' && request.method === 'GET') {
			return fetchLibrarySnapshot(request, env);
		}
		if (url.pathname === '/api/library/file' && request.method === 'GET') {
			return fetchLibraryFile(request, env);
		}
		if (url.pathname === '/api/sharing/status' && request.method === 'GET') {
			return sharedFolderStatus(request, env);
		}
		if (url.pathname === '/api/sharing/connect' && request.method === 'POST') {
			return connectSharedFolder(request, env);
		}
		if (url.pathname === '/api/sharing/disconnect' && request.method === 'POST') {
			return disconnectSharedFolder(request, env);
		}
		if (url.pathname === '/api/sharing/item' && request.method === 'GET') {
			return sharedItemStatus(request, env, context);
		}
		if (url.pathname === '/api/sharing/item' && request.method === 'POST') {
			return updateSharedItem(request, env, context);
		}
		if (url.pathname === '/api/sharing/operation' && request.method === 'GET') {
			return sharedOperationStatus(request, env, context);
		}
		if (url.pathname === '/api/inbox' && request.method === 'GET') {
			return loadSharedInboxProjection(request, env);
		}
		const inboxAction = url.pathname.match(
			/^\/api\/inbox\/([a-zA-Z0-9_-]{1,256})\/(save|dismiss)$/
		);
		if (inboxAction && request.method === 'POST') {
			return inboxAction[2] === 'save'
				? saveInboxReference(request, env, inboxAction[1])
				: dismissInboxReference(request, env, inboxAction[1]);
		}
		if (url.pathname === '/api/google/status' && request.method === 'GET') {
			return googleDriveStatus(request, env);
		}
		if (url.pathname === '/api/google/picker' && request.method === 'GET') {
			return googleDrivePickerConfig(request, env);
		}
		if (url.pathname === '/api/google/connect/start' && request.method === 'GET') {
			return startGoogleDriveConnection(request, env);
		}
		if (url.pathname === '/api/google/connect/callback' && request.method === 'GET') {
			return finishGoogleDriveConnection(request, env);
		}
		if (url.pathname === '/api/google/disconnect' && request.method === 'POST') {
			return disconnectGoogleDrive(request, env);
		}
		if (url.pathname === '/api/media/audio' && request.method === 'GET') {
			return listDriveAudio(request, env);
		}
		const media = mediaPath(url);
		if (media && request.method === 'GET') {
			return downloadDriveMedia(request, env, media);
		}
		if (media && request.method === 'PUT') {
			return uploadDriveMedia(request, env, media);
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
