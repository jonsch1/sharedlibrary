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
		if (this.sql.includes('FROM shared_folder_connections')) {
			return this.database.sharedFolderConnection;
		}
		if (this.sql.includes('FROM sharing_operations')) {
			return this.database.sharingOperation;
		}
		return null;
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
		if (this.sql.includes('INSERT INTO sharing_operations')) {
			this.database.sharingOperation = {
				capture_id: this.arguments[1],
				recipient_ids: this.arguments[2],
				generation: this.arguments[3],
				status:
					this.database.sharingOperation?.status === 'syncing' ? 'syncing' : 'queued',
				attempt_count: 0,
				last_error: null,
				updated_at: this.arguments[5]
			};
			changes = 1;
		}
		return { success: true, meta: { changes } };
	}
}

class MockDatabase {
	credential = null;
	oauthState = null;
	pendingOAuthState = null;
	savedCredential = null;
	sharedFolderConnection = null;
	sharingOperation = null;

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
	assert.equal(googleStatus.pickerConfigured, true);
	assert.equal(googleStatus.appID, '123456789');
	assert.equal(googleStatus.groupFolderConfigured, true);
	assert.equal('clientID' in googleStatus, false);
	assert.equal('clientSecret' in googleStatus, false);
});

test('folder picker requires a connected Google Drive account', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/google/picker'),
		environment()
	);
	assert.equal(response.status, 409);
	assert.deepEqual(await response.json(), {
		error: 'Connect Google Drive before choosing a shared folder.'
	});
});

test('shared folder is optional and independent from the personal Drive connection', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/sharing/status'),
		environment()
	);
	assert.equal(response.status, 200);
	assert.deepEqual(await response.json(), { connected: false });
});

test('shared folder connection is restricted to the configured group folder', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/sharing/connect', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				folder: '1DifferentGoogleDriveFolder2345',
				username: 'reader'
			})
		}),
		environment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), {
		error: 'Choose the predefined Shared Library group folder.'
	});
});

test('sharing updates return immediately and persist a coalescing Drive operation', async () => {
	const database = new MockDatabase();
	database.sharedFolderConnection = {
		user_email: 'reader@example.com',
		folder_id: '1ConfiguredGroupFolder234567890',
		user_id: 'reader-id',
		username: 'reader'
	};
	let backgroundTask;
	const response = await worker.fetch(
		authenticatedRequest('/api/sharing/item', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				captureID: 'capture-1',
				recipientIDs: ['reader-id', 'recipient-1', 'recipient-1']
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
	assert.deepEqual(await response.json(), {
		shared: true,
		referenceID: 'capture-1',
		recipientIDs: ['recipient-1'],
		people: [],
		operationStatus: 'queued'
	});
	assert.deepEqual(JSON.parse(database.sharingOperation.recipient_ids), ['recipient-1']);
	assert.equal(database.sharingOperation.status, 'queued');
	assert.ok(backgroundTask);
	await backgroundTask;
});

test('sharing operation status completes without reading Google Drive', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/sharing/operation?captureID=capture-1'),
		environment()
	);
	assert.equal(response.status, 200);
	assert.deepEqual(await response.json(), { status: 'complete' });
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
			path: '/api/sharing/connect',
			body: { folder: '1AbCdEfGhIjKlMnOpQrStUvWxYz', username: 'reader' }
		},
		{
			path: '/api/sharing/item',
			body: { captureID: 'capture-1', recipientIDs: ['recipient-1'] }
		},
		{
			path: '/api/inbox/reference-1/dismiss'
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
