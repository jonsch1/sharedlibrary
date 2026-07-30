import assert from 'node:assert/strict';
import test from 'node:test';

import worker from './index.js';

test('public requests cannot impersonate accounts or read private media', async () => {
	const env = environment();
	const status = await worker.fetch(
		new Request('https://library.example/api/auth/status', {
			headers: { 'oai-authenticated-user-email': 'victim@example.com' }
		}),
		env
	);
	assert.equal((await status.json()).authenticated, false);
	assert.equal(status.headers.get('x-frame-options'), 'DENY');

	const media = await worker.fetch(
		new Request(`https://library.example/api/media/audio/${'a'.repeat(64)}`),
		env
	);
	assert.equal(media.status, 401);
});

test('paid routes fail closed and still reject path traversal for entitled accounts', async () => {
	const unavailable = await worker.fetch(
		authenticatedRequest('/api/library'),
		environment('reader@example.com')
	);
	assert.equal(unavailable.status, 503);
	assert.equal((await unavailable.json()).code, 'billing_unavailable');

	const traversal = await worker.fetch(
		authenticatedRequest(
			`/api/library/file?path=${encodeURIComponent('../secrets.md')}&hash=${'a'.repeat(64)}`
		),
		environment('schauljonathan@gmail.com')
	);
	assert.equal(traversal.status, 400);
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

test('Stripe webhooks reject invalid signatures before changing state', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/billing/webhook', {
			method: 'POST',
			headers: { 'Stripe-Signature': 't=0,v1=invalid' },
			body: JSON.stringify({ id: 'evt_invalid', type: 'checkout.session.completed' })
		}),
		{
			...environment(),
			STRIPE_SECRET_KEY: 'rk_test_briefly',
			STRIPE_WEBHOOK_SECRET: 'whsec_briefly_test'
		}
	);
	assert.equal(response.status, 400);
});

function environment(email = null) {
	return {
		DB: database(email),
		ASSETS: { fetch: async () => new Response('asset') }
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
