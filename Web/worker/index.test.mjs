import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
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

test('account deletion revokes Apple authorization and removes deletable account data', async (t) => {
	const denied = await worker.fetch(
		new Request('https://library.example/api/auth/account', {
			method: 'DELETE',
			headers: { Origin: 'https://library.example' }
		}),
		environment()
	);
	assert.equal(denied.status, 401);

	const deletion = await accountDeletionEnvironment(t);
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

		for (const table of ['share_texts', 'share_links', 'service_usage', 'auth_identities',
			'apple_authorizations', 'app_sessions', 'accounts', 'service_access']) {
			assert.equal(deletion.env.DB.sqlite.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get().count, 0);
		}
		assert.equal(deletion.env.DB.sqlite.prepare('SELECT COUNT(*) AS count FROM content_reports').get().count, 1);
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

test('share publication preserves the newest text and respects moderation and revocation', { timeout: 10_000 }, async (t) => {
	const env = await sqliteEnvironment(t, 'schauljonathan@gmail.com');
	const captureID = 'capture-1';
	const mutation = (path, value, method = 'POST') => authenticatedRequest(path, {
		method,
		headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
		body: value && JSON.stringify(value)
	});
	const publish = async (markdown) => {
		const tasks = [];
		const response = await worker.fetch(mutation('/api/share-links', {
			captureID,
			source: {
				filename: 'capture.md', title: 'Shared article', topicIDs: [], topicNames: [], tags: [],
				texts: [{ variant: 'source', markdown: 'Private source.' }, { variant: 'concise', markdown }]
			}
		}), env, { waitUntil(task) { tasks.push(task); } });
		return { response, tasks };
	};
	const firstReady = Promise.withResolvers();
	const releaseFirst = Promise.withResolvers();
	env.DB.afterWrite = async () => {
		if (env.DB.sqlite.prepare('SELECT status FROM share_links').get()?.status !== 'ready') return;
		env.DB.afterWrite = undefined;
		firstReady.resolve();
		await releaseFirst.promise;
	};
	const first = await publish('Older summary.');
	assert.equal(first.response.status, 202);
	const { token } = await first.response.json();
	const read = () => worker.fetch(new Request(`https://library.example/api/public/shares/${token}`), env);
	try {
		await firstReady.promise;
		const newer = await publish('Newest summary.');
		assert.equal(newer.response.status, 202);
		await Promise.all(newer.tasks);
	} finally {
		releaseFirst.resolve();
		await Promise.all(first.tasks);
	}
	const document = await (await read()).json();
	assert.equal(document.status, 'ready');
	assert.deepEqual(document.texts.map((text) => text.markdown), ['Newest summary.']);
	assert.equal(env.DB.sqlite.prepare('SELECT COUNT(*) AS count FROM share_texts').get().count, 1);
	env.DB.afterRead = async (record) => {
		if (record?.token !== token || record.status !== 'ready') return;
		env.DB.afterRead = undefined;
		const newer = await publish('Published while reading.');
		await Promise.all(newer.tasks);
	};
	const snapshot = await (await read()).json();
	assert.equal(snapshot.revision, document.revision);
	assert.deepEqual(snapshot.texts, document.texts);
	assert.deepEqual((await (await read()).json()).texts.map((text) => text.markdown), ['Published while reading.']);

	const report = await worker.fetch(mutation(`/api/public/shares/${token}/reports`, {
		category: 'privacy', reporterName: 'Reader', reporterEmail: 'reader@example.com',
		explanation: 'This summary contains private information.', goodFaith: true
	}), env);
	assert.equal(report.status, 201);
	const { id } = await report.json();
	const beforeCommit = Promise.withResolvers();
	const releaseCommit = Promise.withResolvers();
	env.DB.beforeWrite = async () => {
		if (env.DB.sqlite.prepare('SELECT status FROM share_links').get()?.status !== 'preparing') return;
		env.DB.beforeWrite = undefined;
		beforeCommit.resolve();
		await releaseCommit.promise;
	};
	const pending = await publish('Do not restore removed content.');
	try {
		await beforeCommit.promise;
		const removed = await worker.fetch(mutation('/api/admin/content-reports', { id, decision: 'removed' }, 'PATCH'), env);
		assert.equal(removed.status, 200);
	} finally {
		releaseCommit.resolve();
		await Promise.all(pending.tasks);
	}
	assert.equal((await read()).status, 409);
	assert.equal(env.DB.sqlite.prepare('SELECT COUNT(*) AS count FROM share_texts').get().count, 0);
	assert.equal((await publish('Still removed.')).response.status, 403);
	const revoked = await worker.fetch(mutation(`/api/share-links/${token}`, null, 'DELETE'), env);
	assert.equal(revoked.status, 200);
	assert.equal((await read()).status, 404);
});

test('Apple web login binds callbacks to the browser and keeps return URLs on site', async (t) => {
	const env = await appleEnvironment(t);
	const keys = await crypto.subtle.generateKey(
		{ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
		true, ['sign', 'verify']
	);
	const jwk = { ...await crypto.subtle.exportKey('jwk', keys.publicKey), kid: 'test-apple-key' };
	const originalFetch = globalThis.fetch;
	t.after(() => { globalThis.fetch = originalFetch; });
	let nonce;
	globalThis.fetch = async (url) => {
		if (String(url).endsWith('/auth/keys')) return Response.json({ keys: [jwk] });
		assert.equal(String(url), 'https://appleid.apple.com/auth/token');
		const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
		const input = encode({ alg: 'RS256', kid: jwk.kid }) + '.' + encode({
			iss: 'https://appleid.apple.com', aud: env.APPLE_CLIENT_ID, nonce,
			exp: Math.floor(Date.now() / 1000) + 300, sub: 'apple-reader',
			email: 'reader@example.com', email_verified: true
		});
		const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', keys.privateKey, new TextEncoder().encode(input));
		return Response.json({ id_token: input + '.' + Buffer.from(signature).toString('base64url'), refresh_token: 'refresh-token' });
	};
	const start = async (returnTo) => {
		const url = new URL('https://library.example/api/auth/apple/start');
		url.searchParams.set('return_to', returnTo);
		const response = await worker.fetch(new Request(url), env);
		const authorization = new URL(response.headers.get('location'));
		nonce = authorization.searchParams.get('nonce');
		const cookie = response.headers.get('set-cookie');
		assert.match(cookie, /HttpOnly; Secure; SameSite=None; Max-Age=600/);
		return { state: authorization.searchParams.get('state'), cookie: cookie.split(';')[0] };
	};
	const finish = (login, cookie = login.cookie) => worker.fetch(new Request('https://library.example/api/auth/apple/callback', {
		method: 'POST', headers: { Cookie: cookie },
		body: new URLSearchParams({ state: login.state, code: 'apple-code' })
	}), env);
	const login = await start('/admin?view=reports');
	const foreign = await finish(login, '');
	assert.equal(new URL(foreign.headers.get('location')).searchParams.get('apple'), 'error');
	assert.equal(env.DB.sqlite.prepare('SELECT COUNT(*) AS count FROM app_sessions').get().count, 0);
	const successful = await finish(login);
	assert.equal(successful.headers.get('location'), 'https://library.example/admin?view=reports&apple=signed-in');
	const session = successful.headers.getSetCookie().find((cookie) => cookie.startsWith('shared_library_session=')).split(';')[0];
	const status = await worker.fetch(new Request('https://library.example/api/auth/status', { headers: { Cookie: session } }), env);
	assert.equal((await status.json()).email, 'reader@example.com');
	const replay = await finish(login);
	assert.equal(new URL(replay.headers.get('location')).searchParams.get('apple'), 'expired');
	assert.equal(env.DB.sqlite.prepare('SELECT COUNT(*) AS count FROM app_sessions').get().count, 1);
	const unsafe = await finish(await start('/\\attacker.example/'));
	assert.equal(unsafe.headers.get('location'), 'https://library.example/?apple=signed-in');
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

async function accountDeletionEnvironment(t) {
	const env = await appleEnvironment(t, 'reader@example.com');
	env.DB.sqlite.exec(`
		INSERT INTO auth_identities VALUES ('apple', 'apple-subject', 'reader@example.com', 0);
		INSERT INTO apple_authorizations VALUES ('apple-subject', 'fyi.readbriefly.BrieflyNative', 'apple-refresh-token', 0, 0);
		INSERT INTO service_access VALUES ('reader@example.com', 'admin@example.com', 0);
		INSERT INTO service_usage VALUES ('test-account', 'firecrawl', '2026-09-12', 1, 0);
		INSERT INTO share_links VALUES ('share-token', 'reader@example.com', 'capture-1', 'generation-1', 1, 'ready', '{}', 'capture.md', NULL, '', '');
		INSERT INTO share_texts VALUES ('share-token', 'generation-1', 'concise', 'Saved summary.', 2);
		INSERT INTO content_reports (id, share_token, owner_email, capture_id, share_title, reported_url, category, explanation, status, created_at)
		VALUES ('report-1', 'share-token', 'reader@example.com', 'capture-1', 'Title', 'https://library.example/', 'privacy', 'Keep moderation history.', 'open', 0);
	`);
	return { env };
}

async function appleEnvironment(t, email) {
	const keys = await crypto.subtle.generateKey(
		{ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']
	);
	return {
		...await sqliteEnvironment(t, email),
		APPLE_CLIENT_ID: 'fyi.readbriefly.web',
		APPLE_KEY_ID: 'ABCDEFGHIJ',
		APPLE_TEAM_ID: 'KLMNOPQRST',
		APPLE_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\n' +
			Buffer.from(await crypto.subtle.exportKey('pkcs8', keys.privateKey)).toString('base64') +
			'\n-----END PRIVATE KEY-----'
	};
}

async function sqliteEnvironment(t, email) {
	const sqlite = new DatabaseSync(':memory:');
	t.after(() => sqlite.close());
	const migrations = new URL('../drizzle/', import.meta.url);
	for (const name of readdirSync(migrations).filter((name) => name.endsWith('.sql')).sort()) {
		sqlite.exec(readFileSync(new URL(name, migrations), 'utf8'));
	}
	// Only adapt D1's result shape; all SQL, constraints and transactions run in SQLite.
	const DB = {
		sqlite,
		prepare(sql) {
			let bindings = [];
			const prepared = sqlite.prepare(sql);
			const statement = {
				bind(...values) { bindings = values; return statement; },
				async first() {
					const result = prepared.get(...bindings) ?? null;
					await DB.afterRead?.(result);
					return result;
				},
				async all() {
					const results = prepared.all(...bindings);
					await DB.afterRead?.(results[0]);
					return { results };
				},
				execute() { return { success: true, meta: prepared.run(...bindings) }; },
				async run() {
					await DB.beforeWrite?.();
					const result = statement.execute();
					await DB.afterWrite?.();
					return result;
				}
			};
			return statement;
		},
		async batch(statements) {
			await DB.beforeWrite?.();
			sqlite.exec('BEGIN');
			let results;
			try {
				results = statements.map((statement) => statement.execute());
				sqlite.exec('COMMIT');
			} catch (error) {
				sqlite.exec('ROLLBACK');
				throw error;
			}
			await DB.afterWrite?.();
			return results;
		}
	};
	if (email) {
		const tokenHash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('test-session'))).toString('hex');
		sqlite.prepare('INSERT INTO app_sessions VALUES (?, ?, ?, ?)').run(tokenHash, email, Date.now(), Date.now() + 60_000);
		sqlite.prepare('INSERT INTO accounts VALUES (?, ?, ?, ?)').run(email, 'test-account', Date.now(), Date.now());
	}
	return { DB, ASSETS: { fetch: async () => new Response('asset') } };
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
