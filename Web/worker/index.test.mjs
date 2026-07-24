import assert from 'node:assert/strict';
import test from 'node:test';
import worker from './index.js';

class MockStatement {
	constructor(database, sql) {
		this.database = database;
		this.sql = sql;
		this.arguments = [];
	}

	bind(...values) {
		this.arguments = values;
		return this;
	}

	async first() {
		if (this.sql.includes('FROM openrouter_oauth_states')) {
			return this.database.pendingOAuthState;
		}
		if (this.sql.includes('FROM openrouter_credentials')) {
			return this.database.credential;
		}
		if (this.sql.includes('FROM share_links')) {
			if (this.sql.includes('owner_email = ? AND capture_id = ?')) {
				return (
					[...this.database.shareLinks.values()].find(
						(record) =>
							record.owner_email === this.arguments[0] &&
							record.capture_id === this.arguments[1]
					) ?? null
				);
			}
			return this.database.shareLinks.get(this.arguments[0]) ?? null;
		}
		return null;
	}

	async all() {
		if (this.sql.includes('FROM share_texts')) {
			return {
				results: this.database.shareTexts.filter(
					(row) =>
						row.share_token === this.arguments[0] &&
						(this.arguments.length < 2 || row.generation === this.arguments[1])
				)
			};
		}
		if (this.sql.includes('FROM share_audio_segments')) {
			return {
				results: this.database.shareAudioSegments.filter(
					(row) =>
						row.share_token === this.arguments[0] &&
						(this.arguments.length < 2 || row.generation === this.arguments[1])
				)
			};
		}
		return { results: [] };
	}

	async run() {
		let changes = 0;
		if (this.sql.includes('INSERT INTO openrouter_oauth_states')) {
			this.database.oauthState = {
				state: this.arguments[0],
				userEmail: this.arguments[1],
				verifier: this.arguments[2],
				createdAt: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('DELETE FROM openrouter_credentials')) {
			this.database.credential = null;
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO openrouter_credentials')) {
			this.database.savedCredential = {
				userEmail: this.arguments[0],
				encryptedAPIKey: this.arguments[1],
				initializationVector: this.arguments[2],
				openRouterUserID: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO share_links')) {
			const existing = [...this.database.shareLinks.values()].find(
				(record) =>
					record.owner_email === this.arguments[1] &&
					record.capture_id === this.arguments[2]
			);
			const record = {
				token: existing?.token ?? this.arguments[0],
				owner_email: this.arguments[1],
				capture_id: this.arguments[2],
				generation: this.arguments[3],
				revision: (existing?.revision ?? 0) + 1,
				status: 'preparing',
				metadata_json: existing?.metadata_json ?? null,
				source_filename: existing?.source_filename ?? null,
				voice: this.arguments[4],
				error_message: null,
				created_at: existing?.created_at ?? this.arguments[5],
				updated_at: this.arguments[6]
			};
			this.database.shareLinks.set(record.token, record);
			changes = 1;
		}
		if (this.sql.includes("SET status = 'failed'")) {
			const record = this.database.shareLinks.get(this.arguments[2]);
			if (record && record.generation === this.arguments[3]) {
				record.status = 'failed';
				record.error_message = this.arguments[0];
				record.updated_at = this.arguments[1];
				changes = 1;
			}
		}
		if (this.sql.includes('DELETE FROM share_links')) {
			const record = this.database.shareLinks.get(this.arguments[0]);
			if (record && record.owner_email === this.arguments[1]) {
				this.database.shareLinks.delete(this.arguments[0]);
				changes = 1;
			}
		}
		return { success: true, meta: { changes } };
	}
}

class MockDatabase {
	credential = null;
	oauthState = null;
	pendingOAuthState = null;
	savedCredential = null;
	shareLinks = new Map();
	shareTexts = [];
	shareAudioSegments = [];

	prepare(sql) {
		return new MockStatement(this, sql);
	}

	async batch(statements) {
		for (const statement of statements) await statement.run();
		return statements.map(() => ({ success: true }));
	}
}

function environment(database = new MockDatabase()) {
	return {
		DB: database,
		OPENROUTER_CREDENTIAL_KEY: '0'.repeat(64),
		GOOGLE_DRIVE_WEB_CLIENT_ID:
			'123456789-sharedlibrary.apps.googleusercontent.com',
		GOOGLE_DRIVE_WEB_CLIENT_SECRET: 'central-google-secret',
		SHARED_LIBRARY_GROUP_FOLDER_ID: '1ConfiguredGroupFolder234567890',
		SHARE_PREPARE_RETRY_DELAY_MS: 0,
		ASSETS: {
			async fetch() {
				return new Response('asset', { status: 200 });
			}
		}
	};
}

function authenticatedRequest(path, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('oai-authenticated-user-email', 'reader@example.com');
	return new Request(`https://library.example${path}`, { ...init, headers });
}

test('connection status never exposes the stored credential', async () => {
	const database = new MockDatabase();
	database.credential = {
		openrouter_user_id: 'user_123',
		connected_at: '2026-07-23T07:00:00Z',
		encrypted_api_key: 'ciphertext',
		initialization_vector: 'iv'
	};
	const response = await worker.fetch(
		authenticatedRequest('/api/openrouter/status'),
		environment(database)
	);
	assert.equal(response.status, 200);
	assert.deepEqual(await response.json(), {
		connected: true,
		userID: 'user_123',
		connectedAt: '2026-07-23T07:00:00Z'
	});
});

test('Google Drive setup is centrally configured without exposing OAuth credentials', async () => {
	const env = environment();
	const googleResponse = await worker.fetch(authenticatedRequest('/api/google/status'), env);
	assert.equal(googleResponse.status, 200);
	const googleStatus = await googleResponse.json();
	assert.equal(googleStatus.configured, true);
	assert.equal(googleStatus.connected, false);
	assert.equal(
		googleStatus.callbackURL,
		'https://library.example/api/google/connect/callback'
	);
	assert.equal('clientID' in googleStatus, false);
	assert.equal('clientSecret' in googleStatus, false);
});

test('group-folder sharing endpoints are no longer exposed', async () => {
	for (const path of ['/api/sharing/status', '/api/inbox']) {
		const response = await worker.fetch(authenticatedRequest(path), environment());
		assert.equal(response.status, 404);
	}
});

test('publishing creates a stable 192-bit capability link and returns immediately', async () => {
	const database = new MockDatabase();
	let backgroundTask;
	const response = await worker.fetch(
		authenticatedRequest('/api/share-links', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				captureID: 'capture-1',
				voice: 'eve'
			})
		}),
		environment(database),
		{
			waitUntil(task) {
				backgroundTask = task;
			}
		}
	);
	assert.equal(response.status, 202);
	const published = await response.json();
	assert.equal(published.shared, true);
	assert.equal(published.status, 'preparing');
	assert.match(published.token, /^[A-Za-z0-9_-]{32}$/);
	assert.equal(
		published.url,
		`https://library.example/?shared=${published.token}`
	);
	assert.ok(backgroundTask);
	await backgroundTask;

	const statusResponse = await worker.fetch(
		authenticatedRequest('/api/share-links?captureID=capture-1'),
		environment(database)
	);
	assert.equal(statusResponse.status, 200);
	const status = await statusResponse.json();
	assert.equal(status.shared, true);
	assert.equal(status.token, published.token);
});

test('a ready share document is readable anonymously at all stored conciseness levels', async () => {
	const database = new MockDatabase();
	const token = 'A'.repeat(32);
	database.shareLinks.set(token, {
		token,
		owner_email: 'reader@example.com',
		capture_id: 'capture-1',
		generation: 'generation-1',
		revision: 2,
		status: 'ready',
		metadata_json: JSON.stringify({
			title: 'Shared research',
			excerpt: 'A short excerpt',
			topicNames: ['Research']
		}),
		source_filename: 'shared-research.md',
		voice: 'eve',
		error_message: null,
		created_at: '2026-07-23T10:00:00Z',
		updated_at: '2026-07-23T11:00:00Z'
	});
	database.shareTexts = [
		{
			share_token: token,
			generation: 'generation-1',
			variant: 'brief',
			markdown: 'Brief text',
			word_count: 2
		},
		{
			share_token: token,
			generation: 'generation-1',
			variant: 'source',
			markdown: '---\ntitle: Shared research\n---\nOriginal text',
			word_count: 2
		}
	];
	const response = await worker.fetch(
		new Request(`https://library.example/api/public/shares/${token}`),
		environment(database)
	);
	assert.equal(response.status, 200);
	const document = await response.json();
	assert.equal(document.title, 'Shared research');
	assert.equal(document.revision, 2);
	assert.deepEqual(
		document.texts.map((text) => [text.variant, text.markdown]),
		[
			['brief', 'Brief text'],
			['source', 'Original text']
		]
	);
});

test('Google authorization uses the central web client with each user account', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/google/connect/start'),
		environment()
	);
	assert.equal(response.status, 302);
	const authorizationURL = new URL(response.headers.get('location'));
	assert.equal(authorizationURL.hostname, 'accounts.google.com');
	assert.equal(
		authorizationURL.searchParams.get('client_id'),
		'123456789-sharedlibrary.apps.googleusercontent.com'
	);
	assert.equal(
		authorizationURL.searchParams.get('scope'),
		'https://www.googleapis.com/auth/drive.file'
	);
});

test('library file access rejects paths outside the mirrored workspace', async () => {
	const response = await worker.fetch(
		authenticatedRequest(
			`/api/library/file?path=${encodeURIComponent('../secrets.md')}&hash=${'a'.repeat(64)}`
		),
		environment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), { error: 'Invalid library file request.' });
});

test('audio mirror listing requires an authenticated account', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/media/audio'),
		environment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), { error: 'Authentication required.' });
});

test('GitHub endpoints are no longer exposed', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/github/status'),
		environment()
	);
	assert.equal(response.status, 404);
});

test('OAuth start keeps the verifier server-side and sends only its challenge', async () => {
	const database = new MockDatabase();
	const response = await worker.fetch(
		authenticatedRequest('/api/openrouter/connect/start'),
		environment(database)
	);
	assert.equal(response.status, 302);
	assert.ok(database.oauthState?.verifier);
	const authorizationURL = new URL(response.headers.get('location'));
	assert.equal(authorizationURL.origin, 'https://openrouter.ai');
	assert.equal(authorizationURL.pathname, '/auth');
	assert.equal(authorizationURL.searchParams.get('code_challenge_method'), 'S256');
	assert.notEqual(
		authorizationURL.searchParams.get('code_challenge'),
		database.oauthState.verifier
	);
	assert.ok(
		authorizationURL.searchParams
			.get('callback_url')
			?.startsWith('https://library.example/api/openrouter/connect/callback?state=')
	);
});

test('OAuth callback encrypts the user-controlled key before storage', async (context) => {
	const database = new MockDatabase();
	database.pendingOAuthState = {
		user_email: 'reader@example.com',
		code_verifier: 'server-side-verifier',
		created_at: Date.now()
	};
	context.mock.method(globalThis, 'fetch', async (input) => {
		assert.equal(String(input), 'https://openrouter.ai/api/v1/auth/keys');
		return Response.json({ key: 'sk-or-private', user_id: 'openrouter-user' });
	});

	const response = await worker.fetch(
		authenticatedRequest('/api/openrouter/connect/callback?state=pending&code=authorization'),
		environment(database)
	);
	assert.equal(response.status, 302);
	assert.equal(database.savedCredential?.userEmail, 'reader@example.com');
	assert.equal(database.savedCredential?.openRouterUserID, 'openrouter-user');
	assert.notEqual(database.savedCredential?.encryptedAPIKey, 'sk-or-private');
	assert.ok(database.savedCredential?.initializationVector);
});

test('credential and media mutations reject cross-origin requests', async () => {
	const env = environment();
	const mutations = [
		{ path: '/api/tts', body: { input: 'Hello', voice: 'eve' } },
		{ path: '/api/openrouter/disconnect' },
		{
			path: `/api/media/audio/${'a'.repeat(64)}`,
			body: new Uint8Array([1, 2, 3]),
			contentType: 'audio/mpeg'
		},
		{
			path: '/api/share-links',
			body: { captureID: 'capture-1', voice: 'eve' }
		},
		{
			path: `/api/public/shares/${'A'.repeat(32)}/import`
		}
	];
	for (const mutation of mutations) {
		const body =
			mutation.body instanceof Uint8Array
				? mutation.body
				: mutation.body
					? JSON.stringify(mutation.body)
					: undefined;
		const response = await worker.fetch(
			authenticatedRequest(mutation.path, {
				method: mutation.path.startsWith('/api/media/') ? 'PUT' : 'POST',
				headers: {
					Origin: 'https://attacker.example',
					'Content-Type': mutation.contentType ?? 'application/json'
				},
				body
			}),
			env
		);
		assert.equal(response.status, 403);
	}
});

test('speech requires an account-bound OpenRouter connection', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ input: 'Hello', voice: 'eve' })
		}),
		environment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), { error: 'OpenRouter is not connected.' });
});
