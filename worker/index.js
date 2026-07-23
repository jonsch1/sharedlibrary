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
			),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS github_connections (
				user_email TEXT PRIMARY KEY NOT NULL,
				client_id TEXT NOT NULL,
				encrypted_access_token TEXT NOT NULL,
				access_token_iv TEXT NOT NULL,
				encrypted_refresh_token TEXT,
				refresh_token_iv TEXT,
				access_token_expires_at INTEGER,
				refresh_token_expires_at INTEGER,
				login TEXT NOT NULL,
				repository TEXT,
				default_branch TEXT,
				connected_at TEXT NOT NULL,
				updated_at TEXT NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS github_device_states (
				user_email TEXT PRIMARY KEY NOT NULL,
				client_id TEXT NOT NULL,
				encrypted_device_code TEXT NOT NULL,
				device_code_iv TEXT NOT NULL,
				user_code TEXT NOT NULL,
				verification_uri TEXT NOT NULL,
				expires_at INTEGER NOT NULL,
				interval_seconds INTEGER NOT NULL,
				next_poll_at INTEGER NOT NULL
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

function validGitHubClientID(value) {
	return typeof value === 'string' && /^[A-Za-z0-9._-]{8,128}$/.test(value);
}

function githubClientID(env) {
	const value = env.GITHUB_APP_CLIENT_ID?.trim();
	return validGitHubClientID(value) ? value : null;
}

function githubInstallURL(env) {
	const value = env.GITHUB_APP_INSTALL_URL?.trim();
	if (!value) return null;
	try {
		const url = new URL(value);
		return url.protocol === 'https:' && url.hostname === 'github.com' ? url.toString() : null;
	} catch {
		return null;
	}
}

function validRepository(value) {
	return (
		typeof value === 'string' &&
		/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value) &&
		!value.split('/').some((part) => part === '.' || part === '..')
	);
}

async function githubStatus(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ connected: false }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await env.DB.prepare(
		`SELECT client_id, login, repository, default_branch, connected_at
		 FROM github_connections
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	return json({
		configured: Boolean(githubClientID(env)),
		connected: Boolean(connection),
		login: connection?.login ?? undefined,
		repository: connection?.repository ?? undefined,
		defaultBranch: connection?.default_branch ?? undefined,
		connectedAt: connection?.connected_at ?? undefined,
		installURL: githubInstallURL(env) ?? undefined
	});
}

async function startGitHubDeviceFlow(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	const clientID = githubClientID(env);
	if (!clientID) {
		return json(
			{ error: 'Shared Library has not been configured with its GitHub App yet.' },
			{ status: 503 }
		);
	}

	const response = await fetch('https://github.com/login/device/code', {
		method: 'POST',
		headers: {
			Accept: 'application/json',
			'Content-Type': 'application/x-www-form-urlencoded'
		},
		body: new URLSearchParams({ client_id: clientID })
	});
	const value = await response.json();
	if (!response.ok || typeof value.device_code !== 'string') {
		const message =
			value.error === 'device_flow_disabled'
				? 'Device Flow is disabled for this GitHub App.'
				: value.error_description || 'GitHub could not start device authorization.';
		return json({ error: message }, { status: 400 });
	}

	const encrypted = await encryptCredential(env, value.device_code);
	const now = Date.now();
	const interval = Math.max(1, Number(value.interval) || 5);
	await env.DB.prepare(
		`INSERT INTO github_device_states (
			user_email, client_id, encrypted_device_code, device_code_iv,
			user_code, verification_uri, expires_at, interval_seconds, next_poll_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_email) DO UPDATE SET
			client_id = excluded.client_id,
			encrypted_device_code = excluded.encrypted_device_code,
			device_code_iv = excluded.device_code_iv,
			user_code = excluded.user_code,
			verification_uri = excluded.verification_uri,
			expires_at = excluded.expires_at,
			interval_seconds = excluded.interval_seconds,
			next_poll_at = excluded.next_poll_at`
	)
		.bind(
			email,
			clientID,
			encrypted.encryptedAPIKey,
			encrypted.initializationVector,
			value.user_code,
			value.verification_uri,
			now + Number(value.expires_in) * 1000,
			interval,
			now + interval * 1000
		)
		.run();
	return json({
		userCode: value.user_code,
		verificationURI: value.verification_uri,
		expiresIn: Number(value.expires_in),
		interval
	});
}

async function pollGitHubDeviceFlow(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	const pending = await env.DB.prepare(
		`SELECT client_id, encrypted_device_code, device_code_iv, expires_at,
		        interval_seconds, next_poll_at
		 FROM github_device_states
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	if (!pending) return json({ state: 'expired' }, { status: 404 });
	const now = Date.now();
	if (pending.expires_at <= now) {
		await env.DB.prepare('DELETE FROM github_device_states WHERE user_email = ?').bind(email).run();
		return json({ state: 'expired' }, { status: 410 });
	}
	if (pending.next_poll_at > now) {
		return json({
			state: 'pending',
			retryAfter: Math.max(1, Math.ceil((pending.next_poll_at - now) / 1000))
		});
	}

	const deviceCode = await decryptCredential(
		env,
		pending.encrypted_device_code,
		pending.device_code_iv
	);
	const response = await fetch('https://github.com/login/oauth/access_token', {
		method: 'POST',
		headers: {
			Accept: 'application/json',
			'Content-Type': 'application/x-www-form-urlencoded'
		},
		body: new URLSearchParams({
			client_id: pending.client_id,
			device_code: deviceCode,
			grant_type: 'urn:ietf:params:oauth:grant-type:device_code'
		})
	});
	const value = await response.json();
	if (value.error === 'authorization_pending' || value.error === 'slow_down') {
		const interval =
			value.error === 'slow_down'
				? Math.max(Number(value.interval) || 0, pending.interval_seconds + 5)
				: pending.interval_seconds;
		await env.DB.prepare(
			`UPDATE github_device_states
			 SET interval_seconds = ?, next_poll_at = ?
			 WHERE user_email = ?`
		)
			.bind(interval, Date.now() + interval * 1000, email)
			.run();
		return json({ state: 'pending', retryAfter: interval });
	}
	if (value.error) {
		await env.DB.prepare('DELETE FROM github_device_states WHERE user_email = ?').bind(email).run();
		return json(
			{ error: value.error_description || 'GitHub authorization failed.', state: 'failed' },
			{ status: 400 }
		);
	}
	if (!response.ok || typeof value.access_token !== 'string') {
		return json({ error: 'GitHub returned an invalid access token.' }, { status: 502 });
	}

	const profileResponse = await fetch('https://api.github.com/user', {
		headers: githubHeaders(value.access_token)
	});
	const profile = await profileResponse.json();
	if (!profileResponse.ok || typeof profile.login !== 'string') {
		return json({ error: 'GitHub connected, but the user profile could not be read.' }, { status: 502 });
	}

	const encryptedAccess = await encryptCredential(env, value.access_token);
	const encryptedRefresh =
		typeof value.refresh_token === 'string'
			? await encryptCredential(env, value.refresh_token)
			: null;
	const timestamp = new Date().toISOString();
	await env.DB.batch([
		env.DB.prepare(
			`INSERT INTO github_connections (
				user_email, client_id, encrypted_access_token, access_token_iv,
				encrypted_refresh_token, refresh_token_iv, access_token_expires_at,
				refresh_token_expires_at, login, repository, default_branch,
				connected_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
			ON CONFLICT(user_email) DO UPDATE SET
				client_id = excluded.client_id,
				encrypted_access_token = excluded.encrypted_access_token,
				access_token_iv = excluded.access_token_iv,
				encrypted_refresh_token = excluded.encrypted_refresh_token,
				refresh_token_iv = excluded.refresh_token_iv,
				access_token_expires_at = excluded.access_token_expires_at,
				refresh_token_expires_at = excluded.refresh_token_expires_at,
				login = excluded.login,
				connected_at = excluded.connected_at,
				updated_at = excluded.updated_at`
		).bind(
			email,
			pending.client_id,
			encryptedAccess.encryptedAPIKey,
			encryptedAccess.initializationVector,
			encryptedRefresh?.encryptedAPIKey ?? null,
			encryptedRefresh?.initializationVector ?? null,
			value.expires_in ? Date.now() + Number(value.expires_in) * 1000 : null,
			value.refresh_token_expires_in
				? Date.now() + Number(value.refresh_token_expires_in) * 1000
				: null,
			profile.login,
			timestamp,
			timestamp
		),
		env.DB.prepare('DELETE FROM github_device_states WHERE user_email = ?').bind(email)
	]);
	return json({ state: 'connected', login: profile.login });
}

async function disconnectGitHub(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM github_connections WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM github_device_states WHERE user_email = ?').bind(email)
	]);
	return json({ connected: false });
}

function githubHeaders(token, additional = {}) {
	const headers = new Headers(additional);
	headers.set('Authorization', `Bearer ${token}`);
	headers.set('Accept', headers.get('Accept') || 'application/vnd.github+json');
	headers.set('X-GitHub-Api-Version', '2022-11-28');
	headers.set('User-Agent', 'Shared-Library-Web');
	return headers;
}

async function githubConnection(env, email) {
	return env.DB.prepare(
		`SELECT client_id, encrypted_access_token, access_token_iv,
		        encrypted_refresh_token, refresh_token_iv, access_token_expires_at,
		        refresh_token_expires_at, login, repository, default_branch
		 FROM github_connections
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
}

async function githubAccessToken(env, email, forceRefresh = false) {
	let connection = await githubConnection(env, email);
	if (!connection) return null;
	const shouldRefresh =
		forceRefresh ||
		(connection.access_token_expires_at &&
			connection.access_token_expires_at <= Date.now() + 90_000);
	if (!shouldRefresh) {
		return decryptCredential(env, connection.encrypted_access_token, connection.access_token_iv);
	}
	if (
		!connection.encrypted_refresh_token ||
		!connection.refresh_token_iv ||
		(connection.refresh_token_expires_at && connection.refresh_token_expires_at <= Date.now())
	) {
		return null;
	}
	const refreshToken = await decryptCredential(
		env,
		connection.encrypted_refresh_token,
		connection.refresh_token_iv
	);
	const response = await fetch('https://github.com/login/oauth/access_token', {
		method: 'POST',
		headers: {
			Accept: 'application/json',
			'Content-Type': 'application/x-www-form-urlencoded'
		},
		body: new URLSearchParams({
			client_id: connection.client_id,
			grant_type: 'refresh_token',
			refresh_token: refreshToken
		})
	});
	const value = await response.json();
	if (!response.ok || typeof value.access_token !== 'string') return null;
	const encryptedAccess = await encryptCredential(env, value.access_token);
	const encryptedRefresh = await encryptCredential(
		env,
		typeof value.refresh_token === 'string' ? value.refresh_token : refreshToken
	);
	await env.DB.prepare(
		`UPDATE github_connections SET
			encrypted_access_token = ?, access_token_iv = ?,
			encrypted_refresh_token = ?, refresh_token_iv = ?,
			access_token_expires_at = ?, refresh_token_expires_at = ?,
			updated_at = ?
		 WHERE user_email = ?`
	)
		.bind(
			encryptedAccess.encryptedAPIKey,
			encryptedAccess.initializationVector,
			encryptedRefresh.encryptedAPIKey,
			encryptedRefresh.initializationVector,
			value.expires_in ? Date.now() + Number(value.expires_in) * 1000 : null,
			value.refresh_token_expires_in
				? Date.now() + Number(value.refresh_token_expires_in) * 1000
				: connection.refresh_token_expires_at,
			new Date().toISOString(),
			email
		)
		.run();
	return value.access_token;
}

async function githubAPIRequest(env, email, path, init = {}) {
	for (const forceRefresh of [false, true]) {
		const token = await githubAccessToken(env, email, forceRefresh);
		if (!token) return new Response('GitHub connection expired.', { status: 401 });
		const response = await fetch(`https://api.github.com${path}`, {
			...init,
			headers: githubHeaders(token, init.headers)
		});
		if (response.status === 401 && !forceRefresh) continue;
		return response;
	}
	return new Response('GitHub connection expired.', { status: 401 });
}

async function installationRepositories(env, email) {
	const installationsResponse = await githubAPIRequest(
		env,
		email,
		'/user/installations?per_page=100'
	);
	let installations;
	try {
		installations = await installationsResponse.json();
	} catch {
		installations = {};
	}
	if (!installationsResponse.ok) {
		throw new Error(installations.message || 'GitHub App installations could not be read.');
	}
	const repositories = [];
	for (const installation of installations.installations ?? []) {
		if (!Number.isInteger(installation.id)) continue;
		const response = await githubAPIRequest(
			env,
			email,
			`/user/installations/${installation.id}/repositories?per_page=100`
		);
		let value;
		try {
			value = await response.json();
		} catch {
			value = {};
		}
		if (!response.ok) {
			throw new Error(value.message || 'The repositories available to Shared Library could not be read.');
		}
		for (const repository of value.repositories ?? []) {
			if (
				typeof repository.full_name !== 'string' ||
				typeof repository.default_branch !== 'string'
			) {
				continue;
			}
			repositories.push({
				id: repository.id,
				fullName: repository.full_name,
				defaultBranch: repository.default_branch,
				private: Boolean(repository.private)
			});
		}
	}
	return repositories.sort((left, right) => left.fullName.localeCompare(right.fullName));
}

function selectAccessibleRepository(repositories, requestedRepository) {
	const normalized = requestedRepository?.trim();
	if (!validRepository(normalized)) return null;
	return (
		repositories.find(
			(repository) =>
				repository.fullName.toLocaleLowerCase() === normalized.toLocaleLowerCase()
		) ?? null
	);
}

async function listGitHubRepositories(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	try {
		return json({
			repositories: await installationRepositories(env, email),
			installURL: githubInstallURL(env) ?? undefined
		});
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'GitHub repositories could not be read.' },
			{ status: 502 }
		);
	}
}

async function configureGitHubRepository(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	let body;
	try {
		body = await request.json();
	} catch {
		return json({ error: 'Enter the repository as owner/name.' }, { status: 400 });
	}
	const repository = body.repository?.trim();
	if (!validRepository(repository)) {
		return json({ error: 'Enter the repository as owner/name.' }, { status: 400 });
	}
	let selectedRepository;
	try {
		selectedRepository = selectAccessibleRepository(
			await installationRepositories(env, email),
			repository
		);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'GitHub repositories could not be read.' },
			{ status: 502 }
		);
	}
	if (!selectedRepository) {
		return json(
			{ error: 'Choose a repository installed for the Shared Library GitHub App.' },
			{ status: 403 }
		);
	}
	await env.DB.prepare(
		`UPDATE github_connections
		 SET repository = ?, default_branch = ?, updated_at = ?
		 WHERE user_email = ?`
	)
		.bind(
			selectedRepository.fullName,
			selectedRepository.defaultBranch,
			new Date().toISOString(),
			email
		)
		.run();
	return json({
		repository: selectedRepository.fullName,
		defaultBranch: selectedRepository.defaultBranch
	});
}

async function fetchLibrarySnapshot(request, env) {
	const email = authenticatedEmail(request);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await githubConnection(env, email);
	if (!connection?.repository) {
		return json({ error: 'Choose the personal GitHub repository first.' }, { status: 409 });
	}
	const repositoryPath = connection.repository.split('/').map(encodeURIComponent).join('/');
	const branch = encodeURIComponent(connection.default_branch || 'main');
	const response = await githubAPIRequest(
		env,
		email,
		`/repos/${repositoryPath}/contents/.shared-library/library.json?ref=${branch}`,
		{ headers: { Accept: 'application/vnd.github.raw+json' } }
	);
	if (response.status === 404) {
		return json(
			{ error: 'The repository does not contain .shared-library/library.json yet. Update the snapshot in the Mac app and let it sync.' },
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
		return json({ error: value.message || 'The GitHub library could not be downloaded.' }, { status: response.status });
	}
	return new Response(response.body, {
		headers: {
			'Content-Type': 'application/json',
			'Cache-Control': 'private, no-store'
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
	return json({
		configured: Boolean(googleOAuthConfig(env) || connection),
		connected: Boolean(connection?.encrypted_refresh_token),
		connectedAt: connection?.connected_at ?? undefined,
		callbackURL: new URL('/api/google/connect/callback', request.url).toString()
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

async function ensureDriveMediaFolder(env, email) {
	const connection = await googleDriveConnection(env, email);
	if (connection?.folder_id) return connection.folder_id;
	const query = "name='Shared Library Media' and mimeType='application/vnd.google-apps.folder' and trashed=false";
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set('q', query);
	listURL.searchParams.set('fields', 'files(id)');
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) throw new Error(`Google Drive folder lookup failed (${response.status}).`);
	let value = await response.json();
	let folderID = value.files?.[0]?.id;
	if (!folderID) {
		response = await googleDriveRequest(
			env,
			email,
			'https://www.googleapis.com/drive/v3/files?fields=id',
			{
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					name: 'Shared Library Media',
					mimeType: 'application/vnd.google-apps.folder'
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

function mediaPath(url) {
	const match = url.pathname.match(/^\/api\/media\/audio\/([a-f0-9]{64})$/);
	return match ? { kind: 'audio', hash: match[1] } : null;
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
		if (url.pathname === '/api/github/status' && request.method === 'GET') {
			return githubStatus(request, env);
		}
		if (url.pathname === '/api/github/connect/start' && request.method === 'POST') {
			return startGitHubDeviceFlow(request, env);
		}
		if (url.pathname === '/api/github/connect/poll' && request.method === 'POST') {
			return pollGitHubDeviceFlow(request, env);
		}
			if (url.pathname === '/api/github/disconnect' && request.method === 'POST') {
				return disconnectGitHub(request, env);
			}
			if (url.pathname === '/api/github/repositories' && request.method === 'GET') {
				return listGitHubRepositories(request, env);
			}
			if (url.pathname === '/api/github/repository' && request.method === 'POST') {
				return configureGitHubRepository(request, env);
			}
		if (url.pathname === '/api/library' && request.method === 'GET') {
			return fetchLibrarySnapshot(request, env);
		}
		if (url.pathname === '/api/google/status' && request.method === 'GET') {
			return googleDriveStatus(request, env);
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

export { selectAccessibleRepository };
export default worker;
