import assert from 'node:assert/strict';
import test from 'node:test';

import worker, { validAppStoreTransaction } from './index.js';

test('App Store transactions must match the Briefly app and subscription', () => {
	const config = {
		bundleID: 'fyi.readbriefly.BrieflyNative',
		productID: 'fyi.readbriefly.plus.monthly'
	};
	const transaction = {
		bundleId: config.bundleID,
		productId: config.productID,
		type: 'Auto-Renewable Subscription',
		transactionId: '1234567890',
		originalTransactionId: '1234567890',
		appAccountToken: '15b360f5-6a58-4a77-890d-ae7b322f0b1f',
		expiresDate: Date.now() + 60_000,
		signedDate: Date.now()
	};
	assert.equal(validAppStoreTransaction(config, transaction), true);
	assert.equal(validAppStoreTransaction(config, { ...transaction, bundleId: 'attacker.app' }), false);
	assert.equal(validAppStoreTransaction(config, { ...transaction, productId: 'other.product' }), false);
});

test('public requests cannot impersonate accounts or reach removed private-library APIs', async () => {
	const env = environment();
	const status = await worker.fetch(
		new Request('https://library.example/api/auth/status', {
			headers: { 'oai-authenticated-user-email': 'victim@example.com' }
		}),
		env
	);
	assert.equal((await status.json()).authenticated, false);
	assert.equal(status.headers.get('x-frame-options'), 'DENY');

	const library = await worker.fetch(new Request('https://library.example/api/library'), env);
	assert.equal(library.status, 404);
});

test('unknown web routes remain unavailable', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/not-a-briefly-page', {
			headers: { Accept: 'text/html' }
		}),
		{
			...environment(),
			ASSETS: {
				fetch: async (request) => {
					const path = new URL(request.url).pathname;
					return new Response(path === '/' ? 'landing' : 'not found', {
						status: path === '/' ? 200 : 404
					});
				}
			}
		}
	);
	assert.equal(response.status, 404);
});

test('native services fail closed without an App Store entitlement', async () => {
	const unavailable = await worker.fetch(
		authenticatedRequest('/api/ai/process', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
		}),
		{ ...environment('reader@example.com'), OPENROUTER_API_KEY: 'test-key' }
	);
	assert.equal(unavailable.status, 402);
	assert.equal((await unavailable.json()).code, 'subscription_required');
});

test('Briefly AI uses zero-data-retention routing without exposing model details', async () => {
	const originalFetch = globalThis.fetch;
	let openRouterRequest;
	globalThis.fetch = async (url, init) => {
		openRouterRequest = { url: String(url), init };
		return new Response(
			JSON.stringify({
				choices: [{ message: { content: 'A concise summary.' } }],
				usage: { cost: 0.001 }
			}),
			{ headers: { 'Content-Type': 'application/json' } }
		);
	};

	try {
		const response = await worker.fetch(
			authenticatedRequest('/api/ai/process', {
				method: 'POST',
				headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
				body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
			}),
			managedAIEnvironment()
		);
		assert.equal(response.status, 200);
		assert.deepEqual(JSON.parse(openRouterRequest.init.body).provider, { zdr: true });
		const result = await response.json();
		assert.equal(result.output, 'A concise summary.');
		assert.equal('model' in result, false);

		globalThis.fetch = async () =>
			new Response(
				JSON.stringify({ error: { message: 'Underlying model provider failed.' } }),
				{ status: 503, headers: { 'Content-Type': 'application/json' } }
			);
		const failedResponse = await worker.fetch(
			authenticatedRequest('/api/ai/process', {
				method: 'POST',
				headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
				body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
			}),
			managedAIEnvironment()
		);
		assert.equal(failedResponse.status, 503);
		assert.equal(
			(await failedResponse.json()).error,
			'Briefly AI via OpenRouter is temporarily unavailable.'
		);
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test('share mutations reject cross-origin requests', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/share-links', {
			method: 'POST',
			headers: {
				Origin: 'https://attacker.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({ captureID: 'capture-1' })
		}),
		environment('schauljonathan@gmail.com'),
		{ waitUntil() {} }
	);
	assert.equal(response.status, 403);
});

test('App Store notifications reject malformed signed payloads before changing state', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/billing/apple/notifications', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ signedPayload: 'invalid' })
		}),
		environment()
	);
	assert.equal(response.status, 400);
});

function environment(email = null) {
	return {
		DB: database(email),
		ASSETS: { fetch: async () => new Response('asset') }
	};
}

function managedAIEnvironment() {
	const email = 'schauljonathan@gmail.com';
	const accountID = '15b360f5-6a58-4a77-890d-ae7b322f0b1f';
	return {
		OPENROUTER_API_KEY: 'test-key',
		ASSETS: { fetch: async () => new Response('asset') },
		DB: {
			prepare(sql) {
				const statement = {
					bind() {
						return statement;
					},
					async first() {
						if (sql.includes('FROM app_sessions')) {
							return { user_email: email, expires_at: Date.now() + 60_000 };
						}
						if (sql.includes('FROM accounts')) {
							return { account_id: accountID, user_email: email };
						}
						if (sql.includes('FROM managed_ai_usage')) {
							return { spent_micros: 0, reserved_micros: 5_000_000 };
						}
						return null;
					},
					async run() {
						return { success: true, meta: { changes: 1 } };
					}
				};
				return statement;
			}
		}
	};
}

function database(email) {
	return {
		prepare(sql) {
			const statement = {
				bind() {
					return statement;
				},
				async first() {
					return email && sql.includes('FROM app_sessions')
						? { user_email: email, expires_at: Date.now() + 60_000 }
						: null;
				},
				async all() {
					return { results: [] };
				},
				async run() {
					return { success: true, meta: { changes: 0 } };
				}
			};
			return statement;
		},
		async batch() {
			return [];
		}
	};
}

function authenticatedRequest(path, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Cookie', 'shared_library_session=test-session');
	return new Request(`https://library.example${path}`, { ...init, headers });
}
