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
		return null;
	}

	async run() {
		if (this.sql.includes('INSERT INTO openrouter_oauth_states')) {
			this.database.oauthState = {
				state: this.arguments[0],
				userEmail: this.arguments[1],
				verifier: this.arguments[2],
				createdAt: this.arguments[3]
			};
		}
		if (this.sql.includes('DELETE FROM openrouter_credentials')) {
			this.database.credential = null;
		}
		if (this.sql.includes('INSERT INTO openrouter_credentials')) {
			this.database.savedCredential = {
				userEmail: this.arguments[0],
				encryptedAPIKey: this.arguments[1],
				initializationVector: this.arguments[2],
				openRouterUserID: this.arguments[3]
			};
		}
		return { success: true };
	}
}

class MockDatabase {
	credential = null;
	oauthState = null;
	pendingOAuthState = null;
	savedCredential = null;

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
		{ path: '/api/github/connect/start', body: { clientID: 'Iv23li12345678' } },
		{ path: '/api/github/connect/poll' },
		{ path: '/api/github/disconnect' },
		{ path: '/api/github/repository', body: { repository: 'owner/library' } },
		{
			path: `/api/media/audio/${'a'.repeat(64)}`,
			body: new Uint8Array([1, 2, 3]),
			contentType: 'audio/mpeg'
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
