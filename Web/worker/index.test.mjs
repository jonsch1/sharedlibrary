import assert from 'node:assert/strict';
import test from 'node:test';

import worker from './index.js';

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

test('App Review credentials grant revocable review access', async () => {
	const username = 'app-review@readbriefly.fyi';
	const password = 'correct horse battery staple';
	const env = await appReviewEnvironment(username, password);

	const crossOrigin = await worker.fetch(
		new Request('https://library.example/api/auth/review', {
			method: 'POST',
			headers: { Origin: 'https://attacker.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ username, password })
		}),
		env
	);
	assert.equal(crossOrigin.status, 403);

	const invalid = await worker.fetch(
		new Request('https://library.example/api/auth/review', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ username, password: 'wrong' })
		}),
		env
	);
	assert.equal(invalid.status, 401);
	assert.equal(invalid.headers.get('set-cookie'), null);

	const login = await worker.fetch(
		new Request('https://library.example/api/auth/review', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ username, password })
		}),
		env
	);
	assert.equal(login.status, 200);
	assert.match(login.headers.get('set-cookie'), /^shared_library_session=/);
	assert.deepEqual(await login.json(), {
		authenticated: true,
		reviewAccess: true,
		email: username,
		accountID: '15b360f5-6a58-4a77-890d-ae7b322f0b1f',
		isAdmin: false
	});

	const status = await worker.fetch(authenticatedRequest('/api/auth/status'), env);
	const statusPayload = await status.json();
	assert.equal(statusPayload.reviewAccess, true);

	const deletion = await worker.fetch(
		authenticatedRequest('/api/auth/account', {
			method: 'DELETE',
			headers: { Origin: 'https://library.example' }
		}),
		env
	);
	assert.equal(deletion.status, 200);
	assert.equal((await deletion.json()).deleted, true);
	assert.match(deletion.headers.get('set-cookie'), /Max-Age=0/);
});

test('account deletion revokes Apple authorization and removes deletable account data', async () => {
	const denied = await worker.fetch(
		new Request('https://library.example/api/auth/account', {
			method: 'DELETE',
			headers: { Origin: 'https://library.example' }
		}),
		environment()
	);
	assert.equal(denied.status, 401);

	const deletion = await accountDeletionEnvironment();
	const originalFetch = globalThis.fetch;
	let revocation;
	globalThis.fetch = async (url, init) => {
		revocation = { url: String(url), body: new URLSearchParams(init.body) };
		return new Response(null, { status: 200 });
	};

	try {
		const response = await worker.fetch(
			authenticatedRequest('/api/auth/account', {
				method: 'DELETE',
				headers: { Origin: 'https://library.example' }
			}),
			deletion.env
		);
		assert.equal(response.status, 200);
		assert.equal((await response.json()).deleted, true);
		assert.match(response.headers.get('set-cookie'), /Max-Age=0/);
		assert.equal(revocation.url, 'https://appleid.apple.com/auth/revoke');
		assert.equal(revocation.body.get('client_id'), 'fyi.readbriefly.BrieflyNative');
		assert.equal(revocation.body.get('token'), 'apple-refresh-token');

		const changes = deletion.batch.map((statement) => statement.sql).join('\n');
		assert.match(changes, /DELETE FROM share_texts/);
		assert.match(changes, /DELETE FROM share_links/);
		assert.match(changes, /DELETE FROM service_usage/);
		assert.match(changes, /DELETE FROM auth_identities/);
		assert.match(changes, /DELETE FROM app_sessions/);
		assert.match(changes, /DELETE FROM accounts/);
		assert.match(changes, /DELETE FROM service_access/);
		assert.doesNotMatch(changes, /DELETE FROM content_reports/);
	} finally {
		globalThis.fetch = originalFetch;
	}
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

test('static HTML keeps its page-specific CSP instead of receiving the API policy', async () => {
	const response = await worker.fetch(new Request('https://library.example/admin'), {
		...environment(),
		ASSETS: {
			fetch: async () =>
				new Response('<meta http-equiv="content-security-policy" content="script-src self">', {
					headers: { 'Content-Type': 'text/html' }
				})
		}
	});
	assert.equal(response.status, 200);
	assert.equal(response.headers.get('content-security-policy'), null);
	assert.equal(response.headers.get('x-frame-options'), 'DENY');
});

test('hosted services fail closed without explicit access', async () => {
	const unavailable = await worker.fetch(
		authenticatedRequest('/api/ai/process', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
		}),
		{ ...environment('reader@example.com'), OPENROUTER_API_KEY: 'test-key' }
	);
	assert.equal(unavailable.status, 403);
	assert.equal((await unavailable.json()).code, 'service_access_required');
});

test('Briefly AI prefers Fireworks with provider fallback', async () => {
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
		const environment = managedAIEnvironment();
		const response = await worker.fetch(
			authenticatedRequest('/api/ai/process', {
				method: 'POST',
				headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
				body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
			}),
			environment
		);
		assert.equal(response.status, 200);
		assert.deepEqual(JSON.parse(openRouterRequest.init.body).provider, {
			order: ['fireworks'],
			allow_fallbacks: true
		});
		const result = await response.json();
		assert.equal(result.output, 'A concise summary.');
		assert.equal('model' in result, false);
		assert.equal(environment.managedAIState.reservedMicros, 0);

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
			environment
		);
		assert.equal(failedResponse.status, 503);
		assert.equal(
			(await failedResponse.json()).error,
			'Briefly AI via OpenRouter is temporarily unavailable.'
		);
		assert.equal(environment.managedAIState.reservedMicros, 0);

		globalThis.fetch = async () =>
			new Response(
				JSON.stringify({
					choices: [{ message: { content: 'Recovered after a stale request.' } }],
					usage: { cost: 0.001 }
				}),
				{ headers: { 'Content-Type': 'application/json' } }
			);
		const staleEnvironment = managedAIEnvironment({
			reservedMicros: 4_000_000,
			reservationID: 'abandoned-request',
			updatedAt: Date.now() - 21 * 60 * 1_000
		});
		const recoveredResponse = await worker.fetch(
			authenticatedRequest('/api/ai/process', {
				method: 'POST',
				headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
				body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
			}),
			staleEnvironment
		);
		assert.equal(recoveredResponse.status, 200);
		assert.equal(staleEnvironment.managedAIState.reservedMicros, 0);
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test('Briefly AI reserves usage for concurrent processing requests', async () => {
	const originalFetch = globalThis.fetch;
	let releaseUpstream;
	const upstreamBarrier = new Promise((resolve) => {
		releaseUpstream = resolve;
	});
	let upstreamCalls = 0;
	globalThis.fetch = async () => {
		upstreamCalls += 1;
		await upstreamBarrier;
		return new Response(
			JSON.stringify({
				choices: [{ message: { content: 'Concurrent summary.' } }],
				usage: { cost: 0.001 }
			}),
			{ headers: { 'Content-Type': 'application/json' } }
		);
	};

	try {
		const environment = managedAIEnvironment();
		const makeRequest = () =>
			worker.fetch(
				authenticatedRequest('/api/ai/process', {
					method: 'POST',
					headers: {
						Origin: 'https://library.example',
						'Content-Type': 'application/json'
					},
					body: JSON.stringify({ prompt: 'Summarize this.', format: 'text' })
				}),
				environment
			);
		const requests = [makeRequest(), makeRequest(), makeRequest()];
		for (let attempt = 0; attempt < 20 && upstreamCalls < 3; attempt += 1) {
			await Promise.resolve();
		}
		releaseUpstream();
		const responses = await Promise.all(requests);
		assert.equal(upstreamCalls, 3);
		assert.deepEqual(responses.map((response) => response.status), [200, 200, 200]);
		assert.equal(environment.managedAIState.spentMicros, 3_000);
		assert.equal(environment.managedAIState.reservedMicros, 0);
	} finally {
		releaseUpstream?.();
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

function environment(email = null) {
	return {
		DB: database(email),
		ASSETS: { fetch: async () => new Response('asset') }
	};
}

async function appReviewEnvironment(username, password) {
	const encoded = new TextEncoder().encode(`${username}\0${password}`);
	const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', encoded));
	const credentialHash = [...digest]
		.map((byte) => byte.toString(16).padStart(2, '0'))
		.join('');
	const accountID = '15b360f5-6a58-4a77-890d-ae7b322f0b1f';
	return {
		APP_REVIEW_USERNAME: username,
		APP_REVIEW_CREDENTIAL_HASH: credentialHash,
		ASSETS: { fetch: async () => new Response('asset') },
		DB: {
			prepare(sql) {
				const statement = {
					bind() {
						return statement;
					},
					async first() {
						if (sql.includes('FROM app_sessions')) {
							return { user_email: username, expires_at: Date.now() + 60_000 };
						}
						if (sql.includes('FROM accounts')) {
							return { account_id: accountID, user_email: username };
						}
						return null;
					},
					async all() {
						return { results: [] };
					},
					async run() {
						return { success: true, meta: { changes: 1 } };
					}
				};
				return statement;
			},
			async batch(statements) {
				return statements.map(() => ({ success: true, meta: { changes: 1 } }));
			}
		}
	};
}

async function accountDeletionEnvironment() {
	const email = 'reader@example.com';
	const accountID = '15b360f5-6a58-4a77-890d-ae7b322f0b1f';
	const keys = await crypto.subtle.generateKey(
		{ name: 'ECDSA', namedCurve: 'P-256' },
		true,
		['sign', 'verify']
	);
	const privateKey = Buffer.from(await crypto.subtle.exportKey('pkcs8', keys.privateKey))
		.toString('base64')
		.match(/.{1,64}/g)
		.join('\n');
	const batch = [];
	const DB = {
		prepare(sql) {
			let bindings = [];
			const statement = {
				sql,
				get bindings() {
					return bindings;
				},
				bind(...values) {
					bindings = values;
					return statement;
				},
				async first() {
					if (sql.includes('FROM app_sessions')) {
						return { user_email: email, expires_at: Date.now() + 60_000 };
					}
					if (sql.includes('FROM accounts')) {
						return { account_id: accountID, user_email: email };
					}
					if (sql.includes('JOIN apple_authorizations')) {
						return {
							client_id: 'fyi.readbriefly.BrieflyNative',
							refresh_token: 'apple-refresh-token'
						};
					}
					return null;
				},
				async all() {
					return sql.includes('SELECT token FROM share_links')
						? { results: [{ token: 'share-token' }] }
						: { results: [] };
				},
				async run() {
					return { success: true, meta: { changes: 1 } };
				}
			};
			return statement;
		},
		async batch(statements) {
			batch.push(...statements);
			return statements.map(() => ({ success: true, meta: { changes: 1 } }));
		}
	};
	return {
		batch,
		env: {
			APPLE_KEY_ID: 'ABCDEFGHIJ',
			APPLE_PRIVATE_KEY:
				'-----BEGIN PRIVATE KEY-----\n' +
				privateKey +
				'\n-----END PRIVATE KEY-----',
			APPLE_TEAM_ID: 'KLMNOPQRST',
			ASSETS: { fetch: async () => new Response('asset') },
			DB
		}
	};
}

function managedAIEnvironment(initialState = {}) {
	const email = 'schauljonathan@gmail.com';
	const accountID = '15b360f5-6a58-4a77-890d-ae7b322f0b1f';
	const managedAIState = {
		spentMicros: initialState.spentMicros ?? 0,
		reservedMicros: initialState.reservedMicros ?? 0,
		reservationID: initialState.reservationID ?? null,
		updatedAt: initialState.updatedAt ?? Date.now()
	};
	return {
		OPENROUTER_API_KEY: 'test-key',
		ASSETS: { fetch: async () => new Response('asset') },
		managedAIState,
		DB: {
			prepare(sql) {
				let bindings = [];
				const statement = {
					bind(...values) {
						bindings = values;
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
							return {
								spent_micros: managedAIState.spentMicros,
								reserved_micros: managedAIState.reservedMicros
							};
						}
						return null;
					},
					async run() {
						if (sql.includes('SET reserved_micros = CASE')) {
							const [staleBefore, reservation, , now, , , , , allowance] = bindings;
							const reserved = managedAIState.updatedAt < staleBefore
								? 0
								: managedAIState.reservedMicros;
							if (managedAIState.spentMicros + reserved + reservation > allowance) {
								return { success: true, meta: { changes: 0 } };
							}
							managedAIState.reservedMicros = reserved + reservation;
							managedAIState.reservationID = null;
							managedAIState.updatedAt = now;
							return { success: true, meta: { changes: 1 } };
						}
						if (sql.includes('SET spent_micros = MIN')) {
							const [allowance, cost, reservation, now] = bindings;
							managedAIState.spentMicros = Math.min(
								allowance,
								managedAIState.spentMicros + cost
							);
							managedAIState.reservedMicros = Math.max(
								0,
								managedAIState.reservedMicros - reservation
							);
							managedAIState.updatedAt = now;
							return { success: true, meta: { changes: 1 } };
						}
						if (sql.includes('SET reserved_micros = MAX(0, reserved_micros - ?)')) {
							const [reservation, now] = bindings;
							managedAIState.reservedMicros = Math.max(
								0,
								managedAIState.reservedMicros - reservation
							);
							managedAIState.updatedAt = now;
							return { success: true, meta: { changes: 1 } };
						}
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
