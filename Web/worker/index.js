const oauthStateLifetimeMilliseconds = 10 * 60 * 1000;
const managedAIModel = 'deepseek/deepseek-v4-flash';
const managedAIMonthlyAllowanceMicros = 5_000_000;
const maximumManagedAIPromptLength = 600_000;
const uuidPattern =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const firecrawlEndpoint = 'https://api.firecrawl.dev/v2/scrape';
const maximumActiveShareLinks = 100;
const maximumFeedbackItemsPerAccount = 10;
const maximumFeedbackItemsPerDay = 3;
const maximumContentReportsPerSharePerDay = 20;
const emailAddressPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const contentReportCategories = new Set(['copyright', 'privacy', 'child-safety', 'other']);
const serviceUsageLimits = {
	transcription: {
		dailyUnits: 8 * 60 * 60,
		monthlyUnits: 50 * 60 * 60,
		concurrency: 2,
		leaseMilliseconds: 35 * 60 * 1000
	},
	voice: {
		dailyUnits: 250_000,
		monthlyUnits: 2_000_000,
		concurrency: 1,
		leaseMilliseconds: 35 * 60 * 1000
	},
	firecrawl: {
		dailyUnits: 250,
		monthlyUnits: 500,
		concurrency: 2,
		leaseMilliseconds: 3 * 60 * 1000
	},
	media: {
		dailyUnits: 2_000_000_000,
		monthlyUnits: 10_000_000_000,
		concurrency: 2,
		leaseMilliseconds: 10 * 60 * 1000
	}
};
const administratorEmails = new Set(['schauljonathan@gmail.com']);
const managedAIJSONSchema = {
	name: 'briefly_processing',
	strict: true,
	schema: {
		type: 'object',
		additionalProperties: false,
		properties: {
			short_filename: { type: 'string' },
			summaries: {
				type: 'object',
				additionalProperties: false,
				properties: {
					comprehensive: { type: 'string' },
					detailed: { type: 'string' },
					concise: { type: 'string' },
					brief: { type: 'string' }
				},
				required: ['comprehensive', 'detailed', 'concise', 'brief']
			},
			topic_name: { type: 'string' }
		},
		required: ['short_filename', 'summaries', 'topic_name']
	}
};

function managedAIKey(env) {
	const apiKey = String(env.OPENROUTER_API_KEY || '').trim();
	return apiKey || null;
}

async function scrapeWithFirecrawl(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const denied = await paidAccessResponse(request, env);
	if (denied) return denied;
	if (!paidProcessingEnabled(env)) {
		return json({ error: 'Web extraction is temporarily paused.' }, { status: 503 });
	}
	let rawURL;
	try {
		rawURL = (await request.json()).url;
		const url = new URL(rawURL);
		if (
			(url.protocol !== 'http:' && url.protocol !== 'https:') ||
			url.username ||
			url.password ||
			rawURL.length > 8_192
		) {
			throw new Error();
		}
		rawURL = url.toString();
	} catch {
		return json({ error: 'Invalid extraction URL.' }, { status: 400 });
	}
	const email = await authenticatedEmail(request, env);
	const customer = email ? await ensureAccount(env, email) : null;
	if (!customer) return json({ error: 'Authentication required.' }, { status: 401 });
	const limits = await accountServiceLimits(env, customer.account_id, 'firecrawl');
	const leaseID = await reserveServiceLease(
		env,
		customer.account_id,
		'firecrawl',
		limits
	);
	if (!leaseID) return quotaResponse('Too many web extractions are already running.');
	const usage = await consumeServiceUnits(
		env,
		customer.account_id,
		'firecrawl',
		5,
		limits
	);
	if (!usage) {
		await releaseServiceLease(env, customer.account_id, 'firecrawl', leaseID);
		return quotaResponse('The monthly web-extraction allowance has been reached.');
	}
	const apiKey = String(env.FIRECRAWL_API_KEY || '').trim();
	if (!apiKey) {
		await releaseServiceLease(env, customer.account_id, 'firecrawl', leaseID);
		return json({ error: 'Web extraction is unavailable.' }, { status: 503 });
	}
	try {
		const response = await fetch(firecrawlEndpoint, {
			method: 'POST',
			headers: {
				Authorization: `Bearer ${apiKey}`,
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				url: rawURL,
				formats: ['markdown'],
				onlyMainContent: true,
				removeBase64Images: true,
				storeInCache: false,
				timeout: 120_000
			})
		});
		return new Response(response.body, {
			status: response.status,
			headers: {
				'Cache-Control': 'no-store',
				'Content-Type': response.headers.get('Content-Type') || 'application/json'
			}
		});
	} finally {
		await releaseServiceLease(env, customer.account_id, 'firecrawl', leaseID);
	}
}

function json(value, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Content-Type', 'application/json');
	headers.set('Cache-Control', 'no-store');
	return new Response(JSON.stringify(value), { ...init, headers });
}

const sessionCookieName = 'shared_library_session';
const sessionLifetimeMilliseconds = 90 * 24 * 60 * 60 * 1000;

async function authenticatedEmail(request, env) {
	const cookie = request.headers.get('Cookie') ?? '';
	const rawToken = cookie
		.split(';')
		.map((value) => value.trim())
		.find((value) => value.startsWith(`${sessionCookieName}=`))
		?.slice(sessionCookieName.length + 1);
	if (!rawToken || !env.DB) return null;
	const tokenHash = await sha256Hex(rawToken);
	const session = await env.DB.prepare(
		`SELECT user_email, expires_at FROM app_sessions WHERE token_hash = ?`
	)
		.bind(tokenHash)
		.first();
	if (!session || Number(session.expires_at) <= Date.now()) {
		if (session) {
			await env.DB.prepare('DELETE FROM app_sessions WHERE token_hash = ?')
				.bind(tokenHash)
				.run();
		}
		return null;
	}
	return session.user_email;
}

function sessionCookie(token, maximumAgeSeconds) {
	return [
		`${sessionCookieName}=${token}`,
		'Path=/',
		'HttpOnly',
		'Secure',
		'SameSite=Lax',
		`Max-Age=${maximumAgeSeconds}`
	].join('; ');
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

async function openRouterError(response, fallback) {
	const body = await response.text();
	try {
		const value = JSON.parse(body);
		if (typeof value.error === 'string') return value.error;
		if (typeof value.error?.message === 'string') return value.error.message;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The upstream response was not JSON.
	}
	if (body.trim()) return body.trim().slice(0, 500);
	return fallback;
}

function appleAuthConfig(env) {
	const clientID = String(env.APPLE_CLIENT_ID || '').trim();
	const teamID = String(env.APPLE_TEAM_ID || '').trim();
	const keyID = String(env.APPLE_KEY_ID || '').trim();
	const privateKey = String(env.APPLE_PRIVATE_KEY || '').replaceAll('\\n', '\n').trim();
	if (
		!/^[A-Za-z0-9.-]{3,255}$/.test(clientID) ||
		!/^[A-Z0-9]{10}$/.test(teamID) ||
		!/^[A-Z0-9]{10}$/.test(keyID) ||
		!privateKey.includes('BEGIN PRIVATE KEY')
	) {
		return null;
	}
	return { clientID, teamID, keyID, privateKey };
}

function nativeAppleAuthConfig(env) {
	const clientID = String(env.APPLE_APP_BUNDLE_ID || 'fyi.readbriefly.BrieflyNative').trim();
	return /^[A-Za-z0-9.-]{3,255}$/.test(clientID) ? { clientID } : null;
}

function appStoreConfig(env) {
	const issuerID = String(env.APP_STORE_ISSUER_ID || '').trim();
	const keyID = String(env.APP_STORE_KEY_ID || '').trim();
	const privateKey = String(env.APP_STORE_PRIVATE_KEY || '').replaceAll('\\n', '\n').trim();
	const bundleID = String(env.APPLE_APP_BUNDLE_ID || 'fyi.readbriefly.BrieflyNative').trim();
	const productID = String(env.APP_STORE_PRODUCT_ID || 'fyi.readbriefly.plus.monthly').trim();
	if (
		!/^[0-9a-f-]{36}$/i.test(issuerID) ||
		!/^[A-Z0-9]{10}$/.test(keyID) ||
		!privateKey.includes('BEGIN PRIVATE KEY') ||
		!/^[A-Za-z0-9.-]{3,255}$/.test(bundleID) ||
		!/^[A-Za-z0-9._-]{3,255}$/.test(productID)
	) {
		return null;
	}
	return { issuerID, keyID, privateKey, bundleID, productID };
}

function safeReturnTo(value, fallback = '/') {
	return typeof value === 'string' && value.startsWith('/') && !value.startsWith('//')
		? value
		: fallback;
}

async function identityEmail(env, provider, subject, verifiedEmail) {
	const existing = await env.DB.prepare(
		`SELECT user_email FROM auth_identities WHERE provider = ? AND subject = ?`
	)
		.bind(provider, subject)
		.first();
	if (existing?.user_email) return existing.user_email;
	if (!verifiedEmail) return null;
	await env.DB.prepare(
		`INSERT OR IGNORE INTO auth_identities (provider, subject, user_email, created_at)
		 VALUES (?, ?, ?, ?)`
	)
		.bind(provider, subject, verifiedEmail, Date.now())
		.run();
	const identity = await env.DB.prepare(
		`SELECT user_email FROM auth_identities WHERE provider = ? AND subject = ?`
	)
		.bind(provider, subject)
		.first();
	return identity?.user_email ?? null;
}

async function authenticatedRedirect(request, env, email, returnTo, provider) {
	const { token, cookie } = await createSession(env, email);
	void token;
	const destination = new URL(safeReturnTo(returnTo), request.url);
	destination.searchParams.set(provider, 'signed-in');
	return new Response(null, {
		status: 302,
		headers: { Location: destination.toString(), 'Set-Cookie': cookie }
	});
}

async function createSession(env, email) {
	const sessionToken = randomBase64URL(32);
	await env.DB.prepare(
		`INSERT INTO app_sessions (token_hash, user_email, created_at, expires_at)
		 VALUES (?, ?, ?, ?)`
	)
		.bind(
			await sha256Hex(sessionToken),
			email,
			Date.now(),
			Date.now() + sessionLifetimeMilliseconds
		)
		.run();
	return {
		token: sessionToken,
		cookie: sessionCookie(sessionToken, Math.floor(sessionLifetimeMilliseconds / 1000))
	};
}

function pemBytes(value) {
	const encoded = value
		.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
	return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
}

async function appleClientSecret(config) {
	const now = Math.floor(Date.now() / 1000);
	const encodedHeader = bytesToBase64URL(
		new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: config.keyID }))
	);
	const encodedClaims = bytesToBase64URL(
		new TextEncoder().encode(
			JSON.stringify({
				iss: config.teamID,
				iat: now,
				exp: now + 300,
				aud: 'https://appleid.apple.com',
				sub: config.clientID
			})
		)
	);
	const key = await crypto.subtle.importKey(
		'pkcs8',
		pemBytes(config.privateKey),
		{ name: 'ECDSA', namedCurve: 'P-256' },
		false,
		['sign']
	);
	const input = `${encodedHeader}.${encodedClaims}`;
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		key,
		new TextEncoder().encode(input)
	);
	return `${input}.${bytesToBase64URL(new Uint8Array(signature))}`;
}

async function appStoreAuthorization(config) {
	const now = Math.floor(Date.now() / 1000);
	const encodedHeader = bytesToBase64URL(
		new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: config.keyID, typ: 'JWT' }))
	);
	const encodedClaims = bytesToBase64URL(
		new TextEncoder().encode(
			JSON.stringify({
				iss: config.issuerID,
				iat: now,
				exp: now + 300,
				aud: 'appstoreconnect-v1',
				bid: config.bundleID
			})
		)
	);
	const key = await crypto.subtle.importKey(
		'pkcs8',
		pemBytes(config.privateKey),
		{ name: 'ECDSA', namedCurve: 'P-256' },
		false,
		['sign']
	);
	const input = `${encodedHeader}.${encodedClaims}`;
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		key,
		new TextEncoder().encode(input)
	);
	return `${input}.${bytesToBase64URL(new Uint8Array(signature))}`;
}

function decodeJWTPart(value) {
	return JSON.parse(new TextDecoder().decode(base64URLToBytes(value)));
}

async function verifiedAppleIdentity(idToken, config, expectedNonce) {
	const parts = String(idToken || '').split('.');
	if (parts.length !== 3) return null;
	let header;
	let claims;
	try {
		header = decodeJWTPart(parts[0]);
		claims = decodeJWTPart(parts[1]);
	} catch {
		return null;
	}
	if (
		header.alg !== 'RS256' ||
		typeof header.kid !== 'string' ||
		claims.iss !== 'https://appleid.apple.com' ||
		!(claims.aud === config.clientID ||
			(Array.isArray(claims.aud) && claims.aud.includes(config.clientID))) ||
		claims.nonce !== expectedNonce ||
		Number(claims.exp) * 1000 <= Date.now()
	) {
		return null;
	}
	const keysResponse = await fetch('https://appleid.apple.com/auth/keys');
	const keys = keysResponse.ok ? (await keysResponse.json()).keys : [];
	const jwk = Array.isArray(keys) ? keys.find((key) => key?.kid === header.kid) : null;
	if (!jwk) return null;
	const key = await crypto.subtle.importKey(
		'jwk',
		jwk,
		{ name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
		false,
		['verify']
	);
	const valid = await crypto.subtle.verify(
		'RSASSA-PKCS1-v1_5',
		key,
		base64URLToBytes(parts[2]),
		new TextEncoder().encode(`${parts[0]}.${parts[1]}`)
	);
	return valid ? claims : null;
}

async function startAppleLogin(request, env) {
	const config = appleAuthConfig(env);
	if (!config) return json({ error: 'Apple sign-in is not configured.' }, { status: 503 });
	const state = randomBase64URL();
	const nonce = randomBase64URL();
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM apple_login_states WHERE created_at < ?')
			.bind(now - oauthStateLifetimeMilliseconds),
		env.DB
			.prepare(
				`INSERT INTO apple_login_states (state, nonce, return_to, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(
				state,
				nonce,
				safeReturnTo(new URL(request.url).searchParams.get('return_to')),
				now
			)
	]);
	const authorizationURL = new URL('https://appleid.apple.com/auth/authorize');
	authorizationURL.searchParams.set('client_id', config.clientID);
	authorizationURL.searchParams.set(
		'redirect_uri',
		new URL('/api/auth/apple/callback', request.url).toString()
	);
	authorizationURL.searchParams.set('response_type', 'code');
	authorizationURL.searchParams.set('response_mode', 'form_post');
	authorizationURL.searchParams.set('scope', 'name email');
	authorizationURL.searchParams.set('state', state);
	authorizationURL.searchParams.set('nonce', nonce);
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishAppleLogin(request, env) {
	let form;
	try {
		form = await request.formData();
	} catch {
		return redirectWithProviderResult(request, 'apple', 'error');
	}
	const state = form.get('state');
	const code = form.get('code');
	if (typeof state !== 'string' || typeof code !== 'string') {
		return redirectWithProviderResult(request, 'apple', 'error');
	}
	const pending = await env.DB.prepare(
		`SELECT nonce, return_to, created_at FROM apple_login_states WHERE state = ?`
	)
		.bind(state)
		.first();
	if (!pending || Date.now() - pending.created_at > oauthStateLifetimeMilliseconds) {
		return redirectWithProviderResult(request, 'apple', 'expired');
	}
	await env.DB.prepare('DELETE FROM apple_login_states WHERE state = ?').bind(state).run();
	const config = appleAuthConfig(env);
	if (!config) return redirectWithProviderResult(request, 'apple', 'error');
	const response = await fetch('https://appleid.apple.com/auth/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: config.clientID,
			client_secret: await appleClientSecret(config),
			code,
			grant_type: 'authorization_code',
			redirect_uri: new URL('/api/auth/apple/callback', request.url).toString()
		})
	});
	const value = await response.json();
	const claims = response.ok
		? await verifiedAppleIdentity(value.id_token, config, pending.nonce)
		: null;
	const verifiedEmail =
		claims &&
		(claims.email_verified === true || claims.email_verified === 'true') &&
		typeof claims.email === 'string'
			? claims.email.trim().toLowerCase()
			: '';
	const email =
		claims && typeof claims.sub === 'string'
			? await identityEmail(env, 'apple', claims.sub, verifiedEmail)
			: null;
	if (!email) return redirectWithProviderResult(request, 'apple', 'error');
	return authenticatedRedirect(request, env, email, pending.return_to, 'apple');
}

async function finishNativeAppleLogin(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid Apple credential.' }, { status: 400 });
	}
	const identityToken = typeof value?.identityToken === 'string' ? value.identityToken : '';
	const nonce = typeof value?.nonce === 'string' ? value.nonce : '';
	const config = nativeAppleAuthConfig(env);
	if (!config || !identityToken || identityToken.length > 8_192 || !nonce || nonce.length > 256) {
		return json({ error: 'Invalid Apple credential.' }, { status: 400 });
	}
	const claims = await verifiedAppleIdentity(identityToken, config, await sha256Hex(nonce));
	const verifiedEmail =
		claims &&
		(claims.email_verified === true || claims.email_verified === 'true') &&
		typeof claims.email === 'string'
			? claims.email.trim().toLowerCase()
			: '';
	const email =
		claims && typeof claims.sub === 'string'
			? await identityEmail(env, 'apple', claims.sub, verifiedEmail)
			: null;
	if (!email) return json({ error: 'Apple sign-in could not be verified.' }, { status: 401 });
	const account = await accountPayload(env, email);
	const session = await createSession(env, email);
	return json(account, { headers: { 'Set-Cookie': session.cookie } });
}

function decodedJWS(value) {
	const parts = typeof value === 'string' ? value.split('.') : [];
	if (parts.length !== 3) return null;
	try {
		return decodeJWTPart(parts[1]);
	} catch {
		return null;
	}
}

async function appStoreTransaction(env, transactionID) {
	const config = appStoreConfig(env);
	if (!config) throw new Error('App Store billing is not configured.');
	const authorization = await appStoreAuthorization(config);
	for (const base of ['https://api.storekit.apple.com', 'https://api.storekit-sandbox.apple.com']) {
		const response = await fetch(
			`${base}/inApps/v1/transactions/${encodeURIComponent(transactionID)}`,
			{ headers: { Authorization: `Bearer ${authorization}` } }
		);
		if (response.ok) {
			const value = await response.json();
			const transaction = decodedJWS(value?.signedTransactionInfo);
			if (!transaction) throw new Error('The App Store returned an invalid transaction.');
			return { config, transaction };
		}
		if (response.status !== 404) {
			throw new Error(`The App Store could not verify the transaction (${response.status}).`);
		}
	}
	return null;
}

function validAppStoreTransaction(config, transaction) {
	return (
		transaction?.bundleId === config.bundleID &&
		transaction?.productId === config.productID &&
		transaction?.type === 'Auto-Renewable Subscription' &&
		typeof transaction?.transactionId === 'string' &&
		typeof transaction?.originalTransactionId === 'string' &&
		typeof transaction?.appAccountToken === 'string' &&
		Number.isFinite(Number(transaction?.expiresDate)) &&
		Number.isFinite(Number(transaction?.signedDate))
	);
}

async function storeAppStoreTransaction(env, config, transaction) {
	if (!validAppStoreTransaction(config, transaction)) {
		throw new Error('The App Store transaction does not belong to Briefly.');
	}
	const account = await env.DB.prepare('SELECT account_id FROM accounts WHERE account_id = ?')
		.bind(transaction.appAccountToken)
		.first();
	if (!account) throw new Error('The App Store transaction is not linked to a Briefly account.');
	const now = Date.now();
	await env.DB.prepare(
		`INSERT INTO app_store_subscriptions (
			original_transaction_id, account_id, transaction_id, product_id,
			environment, expires_at, revocation_date, signed_at, created_at, updated_at
		 ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(original_transaction_id) DO UPDATE SET
			account_id = excluded.account_id,
			transaction_id = excluded.transaction_id,
			product_id = excluded.product_id,
			environment = excluded.environment,
			expires_at = excluded.expires_at,
			revocation_date = excluded.revocation_date,
			signed_at = excluded.signed_at,
			updated_at = excluded.updated_at
		 WHERE excluded.signed_at >= app_store_subscriptions.signed_at`
	)
		.bind(
			transaction.originalTransactionId,
			transaction.appAccountToken,
			transaction.transactionId,
			transaction.productId,
			transaction.environment || 'Unknown',
			Number(transaction.expiresDate),
			transaction.revocationDate == null ? null : Number(transaction.revocationDate),
			Number(transaction.signedDate),
			now,
			now
		)
		.run();
	return account;
}

async function syncAppStoreTransaction(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid App Store transaction.' }, { status: 400 });
	}
	const transactionID = typeof value?.transactionID === 'string' ? value.transactionID : '';
	if (!/^[0-9]{8,32}$/.test(transactionID)) {
		return json({ error: 'Invalid App Store transaction.' }, { status: 400 });
	}
	try {
		const result = await appStoreTransaction(env, transactionID);
		if (!result) return json({ error: 'App Store transaction not found.' }, { status: 404 });
		const account = await ensureAccount(env, email);
		if (result.transaction.appAccountToken !== account.account_id) {
			return json({ error: 'This purchase belongs to a different Briefly account.' }, { status: 403 });
		}
		await storeAppStoreTransaction(env, result.config, result.transaction);
		return json(await accountPayload(env, email));
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'App Store verification failed.' },
			{ status: 502 }
		);
	}
}

async function appStoreNotification(request, env) {
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid App Store notification.' }, { status: 400 });
	}
	const notification = decodedJWS(value?.signedPayload);
	const transaction = decodedJWS(notification?.data?.signedTransactionInfo);
	const transactionID = transaction?.transactionId;
	if (typeof transactionID !== 'string' || !/^[0-9]{8,32}$/.test(transactionID)) {
		return json({ error: 'Invalid App Store notification.' }, { status: 400 });
	}
	try {
		const result = await appStoreTransaction(env, transactionID);
		if (result) await storeAppStoreTransaction(env, result.config, result.transaction);
		return json({ received: true });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'App Store notification failed.' },
			{ status: 502 }
		);
	}
}

function redirectWithProviderResult(request, provider, result, path = '/') {
	const destination = new URL(path, request.url);
	destination.searchParams.set(provider, result);
	return Response.redirect(destination.toString(), 302);
}

async function accountStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	return json(email ? await accountPayload(env, email) : { authenticated: false });
}

async function administratorRequest(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return { response: json({ error: 'Authentication required.' }, { status: 401 }) };
	}
	if (!isAdministrator(email)) {
		return {
			response: json({ error: 'Administrator access required.' }, { status: 403 })
		};
	}
	return { email };
}

async function adminComplimentaryAccess(request, env) {
	const administrator = await administratorRequest(request, env);
	if (administrator.response) return administrator.response;
	if (request.method === 'GET') {
		const result = await env.DB.prepare(
			`SELECT user_email, granted_by, created_at
			 FROM complimentary_access
			 ORDER BY created_at DESC, user_email`
		).all();
		return json({
			emails: (result.results ?? []).map((entry) => ({
				email: entry.user_email,
				grantedBy: entry.granted_by,
				createdAt: Number(entry.created_at)
			}))
		});
	}
	if (!requireSameOrigin(request)) {
		return json({ error: 'Invalid request origin.' }, { status: 403 });
	}
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid access request.' }, { status: 400 });
	}
	const email = normalizedEmail(value?.email);
	if (email.length > 254 || !emailAddressPattern.test(email)) {
		return json({ error: 'Enter a valid email address.' }, { status: 400 });
	}
	if (request.method === 'POST') {
		const createdAt = Date.now();
		const result = await env.DB.prepare(
			`INSERT OR IGNORE INTO complimentary_access (user_email, granted_by, created_at)
			 VALUES (?, ?, ?)`
		)
			.bind(email, normalizedEmail(administrator.email), createdAt)
			.run();
		return json(
			{ email, createdAt, created: databaseChanges(result) === 1 },
			{ status: databaseChanges(result) === 1 ? 201 : 200 }
		);
	}
	if (request.method === 'DELETE') {
		const result = await env.DB.prepare(
			'DELETE FROM complimentary_access WHERE user_email = ?'
		)
			.bind(email)
			.run();
		return json({ email, removed: databaseChanges(result) === 1 });
	}
	return json({ error: 'Method not allowed.' }, { status: 405 });
}

async function adminUsage(request, env) {
	const administrator = await administratorRequest(request, env);
	if (administrator.response) return administrator.response;
	if (request.method === 'GET') {
		const day = new Date().toISOString().slice(0, 10);
		const month = `${day.slice(0, 7)}-01`;
		const accounts = await env.DB.prepare(
			'SELECT user_email, account_id FROM accounts ORDER BY user_email'
		).all();
		const usage = await env.DB.prepare(
			`SELECT account_id, service,
				MAX(CASE WHEN usage_day = ? THEN units ELSE 0 END) AS daily_units,
				SUM(units) AS monthly_units
			 FROM service_usage
			 WHERE usage_day >= ?
			 GROUP BY account_id, service`
		)
			.bind(day, month)
			.all();
		const overrides = await env.DB.prepare(
			`SELECT account_id, service, daily_units, monthly_units, concurrency
			 FROM service_limit_overrides`
		).all();
		const leases = await env.DB.prepare(
			`SELECT account_id, service, COUNT(*) AS active_leases
			 FROM service_leases
			 WHERE expires_at > ?
			 GROUP BY account_id, service`
		)
			.bind(Date.now())
			.all();
		const usageByService = new Map(
			(usage.results ?? []).map((entry) => [`${entry.account_id}:${entry.service}`, entry])
		);
		const overrideByService = new Map(
			(overrides.results ?? []).map((entry) => [
				`${entry.account_id}:${entry.service}`,
				entry
			])
		);
		const leasesByService = new Map(
			(leases.results ?? []).map((entry) => [`${entry.account_id}:${entry.service}`, entry])
		);
		return json({
			accounts: (accounts.results ?? []).map((account) => ({
				email: account.user_email,
				services: Object.entries(serviceUsageLimits).map(([service, defaults]) => {
					const key = `${account.account_id}:${service}`;
					const used = usageByService.get(key);
					const override = overrideByService.get(key);
					return {
						service,
						usage: {
							dailyUnits: Number(used?.daily_units ?? 0),
							monthlyUnits: Number(used?.monthly_units ?? 0),
							activeLeases: Number(leasesByService.get(key)?.active_leases ?? 0)
						},
						limits: {
							dailyUnits: Number(override?.daily_units ?? defaults.dailyUnits),
							monthlyUnits: Number(override?.monthly_units ?? defaults.monthlyUnits),
							concurrency: Number(override?.concurrency ?? defaults.concurrency)
						},
						custom: Boolean(override)
					};
				})
			}))
		});
	}
	if (!requireSameOrigin(request)) {
		return json({ error: 'Invalid request origin.' }, { status: 403 });
	}
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid usage limit request.' }, { status: 400 });
	}
	const email = normalizedEmail(value?.email);
	const service = typeof value?.service === 'string' ? value.service : '';
	const defaults = serviceUsageLimits[service];
	if (email.length > 254 || !emailAddressPattern.test(email) || !defaults) {
		return json({ error: 'Choose a valid account and service.' }, { status: 400 });
	}
	const account = await accountRecord(env, email);
	if (!account) return json({ error: 'Account not found.' }, { status: 404 });
	if (request.method === 'DELETE') {
		await env.DB.prepare(
			'DELETE FROM service_limit_overrides WHERE account_id = ? AND service = ?'
		)
			.bind(account.account_id, service)
			.run();
		return json({
			email,
			service,
			limits: {
				dailyUnits: defaults.dailyUnits,
				monthlyUnits: defaults.monthlyUnits,
				concurrency: defaults.concurrency
			},
			custom: false
		});
	}
	const limits = value?.limits;
	if (
		![limits?.dailyUnits, limits?.monthlyUnits, limits?.concurrency].every(
			(limit) => Number.isSafeInteger(limit) && limit >= 0
		)
	) {
		return json({ error: 'Limits must be non-negative whole numbers.' }, { status: 400 });
	}
	await env.DB.prepare(
		`INSERT INTO service_limit_overrides (
			account_id, service, daily_units, monthly_units, concurrency, updated_at
		 ) VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT(account_id, service) DO UPDATE SET
			daily_units = excluded.daily_units,
			monthly_units = excluded.monthly_units,
			concurrency = excluded.concurrency,
			updated_at = excluded.updated_at`
	)
		.bind(
			account.account_id,
			service,
			limits.dailyUnits,
			limits.monthlyUnits,
			limits.concurrency,
			Date.now()
		)
		.run();
	return json({ email, service, limits, custom: true });
}

async function feedbackBoard(request, env) {
	const email = await authenticatedEmail(request, env);
	const result = await env.DB.prepare(
		`SELECT
			item.id,
			item.title,
			item.details,
			item.created_at,
			COUNT(upvote.user_email) AS upvotes,
			MAX(CASE WHEN upvote.user_email = ? THEN 1 ELSE 0 END) AS upvoted
		 FROM feedback_items item
		 LEFT JOIN feedback_upvotes upvote ON upvote.feedback_item_id = item.id
		 GROUP BY item.id
		 ORDER BY upvotes DESC, item.created_at DESC
		 LIMIT 200`
	)
		.bind(email ?? '')
		.all();
	return json({
		authenticated: Boolean(email),
		items: (result.results ?? []).map((item) => ({
			id: item.id,
			title: item.title,
			details: item.details,
			createdAt: Number(item.created_at),
			upvotes: Number(item.upvotes),
			upvoted: Boolean(item.upvoted)
		}))
	});
}

async function createFeedback(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid feedback request.' }, { status: 400 });
	}
	const title = typeof value?.title === 'string' ? value.title.trim() : '';
	const details = typeof value?.details === 'string' ? value.details.trim() : '';
	if (title.length < 3 || title.length > 120 || details.length > 2_000) {
		return json(
			{ error: 'Use a title between 3 and 120 characters and details under 2,000 characters.' },
			{ status: 400 }
		);
	}
	const item = {
		id: crypto.randomUUID(),
		title,
		details,
		createdAt: Date.now(),
		upvotes: 1,
		upvoted: true
	};
	const inserted = await env.DB.prepare(
		`INSERT INTO feedback_items (id, user_email, title, details, created_at)
		 SELECT ?, ?, ?, ?, ?
		 WHERE (SELECT COUNT(*) FROM feedback_items WHERE user_email = ?) < ?
		   AND (
			SELECT COUNT(*) FROM feedback_items
			WHERE user_email = ? AND created_at >= ?
		   ) < ?`
	)
		.bind(
			item.id,
			email,
			title,
			details,
			item.createdAt,
			email,
			maximumFeedbackItemsPerAccount,
			email,
			item.createdAt - 24 * 60 * 60 * 1000,
			maximumFeedbackItemsPerDay
		)
		.run();
	if (databaseChanges(inserted) !== 1) {
		return quotaResponse('You can submit up to three feedback items per day.');
	}
	await env.DB.prepare(
			`INSERT INTO feedback_upvotes (feedback_item_id, user_email, created_at)
			 VALUES (?, ?, ?)`
		)
		.bind(item.id, email, item.createdAt)
		.run();
	return json(item, { status: 201 });
}

async function setFeedbackUpvote(request, env, itemID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid upvote request.' }, { status: 400 });
	}
	if (typeof value?.upvoted !== 'boolean') {
		return json({ error: 'Invalid upvote request.' }, { status: 400 });
	}
	const statement = value.upvoted
		? env.DB.prepare(
				`INSERT OR IGNORE INTO feedback_upvotes (feedback_item_id, user_email, created_at)
				 SELECT ?, ?, ? FROM feedback_items WHERE id = ?`
			).bind(itemID, email, Date.now(), itemID)
		: env.DB.prepare(
				'DELETE FROM feedback_upvotes WHERE feedback_item_id = ? AND user_email = ?'
			).bind(itemID, email);
	await statement.run();
	const result = await env.DB.prepare(
		`SELECT
			COUNT(*) AS upvotes,
			MAX(CASE WHEN user_email = ? THEN 1 ELSE 0 END) AS upvoted
		 FROM feedback_upvotes
		 WHERE feedback_item_id = ?`
	)
		.bind(email, itemID)
		.first();
	return json({
		id: itemID,
		upvotes: Number(result?.upvotes ?? 0),
		upvoted: Boolean(result?.upvoted)
	});
}

async function signOut(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const cookie = request.headers.get('Cookie') ?? '';
	const rawToken = cookie
		.split(';')
		.map((value) => value.trim())
		.find((value) => value.startsWith(`${sessionCookieName}=`))
		?.slice(sessionCookieName.length + 1);
	if (rawToken) {
		await env.DB.prepare('DELETE FROM app_sessions WHERE token_hash = ?')
			.bind(await sha256Hex(rawToken))
			.run();
	}
	return new Response(JSON.stringify({ authenticated: false }), {
		headers: {
			'Content-Type': 'application/json',
			'Cache-Control': 'no-store',
			'Set-Cookie': sessionCookie('', 0)
		}
	});
}

function databaseChanges(result) {
	return Number(result?.meta?.changes ?? result?.changes ?? 0);
}

async function accountRecord(env, email) {
	return env.DB.prepare('SELECT account_id, user_email FROM accounts WHERE user_email = ?')
		.bind(email)
		.first();
}

async function ensureAccount(env, email) {
	const existing = await accountRecord(env, email);
	if (existing) return existing;
	const now = Date.now();
	await env.DB.prepare(
		`INSERT OR IGNORE INTO accounts (user_email, account_id, created_at, updated_at)
		 VALUES (?, ?, ?, ?)`
	)
		.bind(email, crypto.randomUUID(), now, now)
		.run();
	return accountRecord(env, email);
}

async function activeAppStoreSubscription(env, accountID, now = Date.now()) {
	if (!accountID) return null;
	return env.DB.prepare(
		`SELECT original_transaction_id, transaction_id, product_id, expires_at
		 FROM app_store_subscriptions
		 WHERE account_id = ? AND expires_at > ? AND revocation_date IS NULL
		 ORDER BY expires_at DESC LIMIT 1`
	)
		.bind(accountID, now)
		.first();
}

async function accountPayload(env, email) {
	const account = await ensureAccount(env, email);
	const subscription = await activeAppStoreSubscription(env, account.account_id);
	return {
		authenticated: true,
		email,
		accountID: account.account_id,
		isAdmin: isAdministrator(email),
		entitled: Boolean(subscription) || (await hasComplimentaryPlusAccess(env, email)),
		subscription: subscription
			? { productID: subscription.product_id, expiresAt: subscription.expires_at }
			: null
	};
}

function normalizedEmail(email) {
	return String(email || '').trim().toLowerCase();
}

function isAdministrator(email) {
	return administratorEmails.has(normalizedEmail(email));
}

async function hasComplimentaryPlusAccess(env, email) {
	const normalized = normalizedEmail(email);
	if (!normalized) return false;
	if (isAdministrator(normalized)) return true;
	return Boolean(
		await env.DB.prepare(
			'SELECT user_email FROM complimentary_access WHERE user_email = ?'
		)
			.bind(normalized)
			.first()
	);
}

async function reserveManagedAIUsage(env, accountID, usageMonth, allowanceMicros) {
	const now = Date.now();
	await env.DB.prepare(
		`INSERT OR IGNORE INTO managed_ai_usage (
			account_id, usage_month, spent_micros, reserved_micros, updated_at
		) VALUES (?, ?, 0, 0, ?)`
	)
		.bind(accountID, usageMonth, now)
		.run();
	const result = await env.DB.prepare(
		`UPDATE managed_ai_usage
		 SET reserved_micros = ? - spent_micros, updated_at = ?
		 WHERE account_id = ? AND usage_month = ?
		   AND reserved_micros = 0 AND spent_micros < ?`
	)
		.bind(allowanceMicros, now, accountID, usageMonth, allowanceMicros)
		.run();
	const usage = await env.DB.prepare(
		`SELECT spent_micros, reserved_micros
		 FROM managed_ai_usage
		 WHERE account_id = ? AND usage_month = ?`
	)
		.bind(accountID, usageMonth)
		.first();
	return {
		reserved: databaseChanges(result) > 0,
		spentMicros: Number(usage?.spent_micros ?? 0),
		reservedMicros: Number(usage?.reserved_micros ?? 0)
	};
}

async function releaseManagedAIUsage(env, accountID, usageMonth) {
	await env.DB.prepare(
		`UPDATE managed_ai_usage SET reserved_micros = 0, updated_at = ?
		 WHERE account_id = ? AND usage_month = ?`
	)
		.bind(Date.now(), accountID, usageMonth)
		.run();
}

async function settleManagedAIUsage(
	env,
	accountID,
	usageMonth,
	costMicros,
	allowanceMicros
) {
	await env.DB.prepare(
		`UPDATE managed_ai_usage
		 SET spent_micros = MIN(?, spent_micros + ?),
		     reserved_micros = 0,
		     updated_at = ?
		 WHERE account_id = ? AND usage_month = ?`
	)
		.bind(allowanceMicros, costMicros, Date.now(), accountID, usageMonth)
		.run();
}

async function processWithManagedAI(request, env) {
	if (!requireSameOrigin(request)) {
		return json({ error: 'Invalid request origin.' }, { status: 403 });
	}
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ error: 'Sign in before using Briefly AI.', code: 'authentication_required' },
			{ status: 401 }
		);
	}
	const apiKey = managedAIKey(env);
	if (!apiKey) {
		return json({ error: 'Briefly AI is unavailable.' }, { status: 503 });
	}
	const complimentary = await hasComplimentaryPlusAccess(env, email);
	let customer = await accountRecord(env, email);
	if (!complimentary && !(await activeAppStoreSubscription(env, customer?.account_id))) {
		return json(
			{
				error: 'An active Briefly membership is required for Briefly AI.',
				code: 'subscription_required'
			},
			{ status: 402 }
		);
	}
	customer ??= await ensureAccount(env, email);

	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid AI request.' }, { status: 400 });
	}
	const prompt = typeof value.prompt === 'string' ? value.prompt.trim() : '';
	const format = value.format === 'json' || value.format === 'text' ? value.format : null;
	if (!prompt || prompt.length > maximumManagedAIPromptLength || !format) {
		return json({ error: 'Invalid AI prompt or output format.' }, { status: 400 });
	}

	const allowanceMicros = managedAIMonthlyAllowanceMicros;
	const usageMonth = new Date().toISOString().slice(0, 7);
	const reservation = await reserveManagedAIUsage(
		env,
		customer.account_id,
		usageMonth,
		allowanceMicros
	);
	if (!reservation.reserved) {
		return json(
			{
				error: reservation.reservedMicros
					? 'Another Briefly AI request is already running.'
					: 'Your Briefly AI allowance resets next month.',
				code: reservation.reservedMicros ? 'request_in_progress' : 'monthly_limit_reached'
			},
			{ status: 429 }
		);
	}

	let response;
	try {
		response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
			method: 'POST',
			headers: {
				Authorization: `Bearer ${apiKey}`,
				'Content-Type': 'application/json',
				'HTTP-Referer': 'https://www.readbriefly.fyi',
				'X-Title': 'Briefly'
			},
			body: JSON.stringify({
				model: managedAIModel,
				messages: [{ role: 'user', content: prompt }],
				max_tokens: format === 'json' ? 32_000 : 16_000,
				provider: { zdr: true },
				...(format === 'json'
					? {
							response_format: {
								type: 'json_schema',
								json_schema: managedAIJSONSchema
							}
						}
					: {})
			})
		});
	} catch {
		await releaseManagedAIUsage(env, customer.account_id, usageMonth);
		return json({ error: 'Briefly AI could not reach OpenRouter.' }, { status: 502 });
	}
	if (!response.ok) {
		await releaseManagedAIUsage(env, customer.account_id, usageMonth);
		return json(
			{
				error: await openRouterError(
					response,
					`OpenRouter processing failed (${response.status}).`
				)
			},
			{ status: response.status }
		);
	}

	let result;
	try {
		result = await response.json();
	} catch {
		await settleManagedAIUsage(
			env,
			customer.account_id,
			usageMonth,
			reservation.reservedMicros,
			allowanceMicros
		);
		return json({ error: 'OpenRouter returned an invalid response.' }, { status: 502 });
	}
	const reportedCost = Number(result?.usage?.cost);
	const costMicros =
		Number.isFinite(reportedCost) && reportedCost >= 0
			? Math.ceil(reportedCost * 1_000_000)
			: reservation.reservedMicros;
	await settleManagedAIUsage(
		env,
		customer.account_id,
		usageMonth,
		costMicros,
		allowanceMicros
	);
	const remainingMicros = Math.max(
		0,
		allowanceMicros -
			Math.min(allowanceMicros, reservation.spentMicros + costMicros)
	);
	const output = result?.choices?.[0]?.message?.content;
	if (typeof output !== 'string' || !output.trim()) {
		return json({ error: 'OpenRouter returned no output.' }, { status: 502 });
	}
	return json({ output, model: managedAIModel, remainingMicros });
}

async function paidAccessResponse(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ error: 'Sign in before using Briefly.', code: 'authentication_required' },
			{ status: 401 }
		);
	}
	if (await hasComplimentaryPlusAccess(env, email)) return null;
	const record = await accountRecord(env, email);
	if (await activeAppStoreSubscription(env, record?.account_id)) return null;
	return json(
		{
			error: 'An active Briefly membership is required for synchronization and sharing.',
			code: 'subscription_required'
		},
		{ status: 402 }
	);
}

function paidProcessingEnabled(env) {
	return String(env.PAID_PROCESSING_ENABLED ?? 'true').toLowerCase() !== 'false';
}

function quotaResponse(message) {
	return json(
		{ error: message, code: 'usage_limit_reached' },
		{ status: 429, headers: { 'Retry-After': '3600' } }
	);
}

async function serviceAccount(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return {
			response: json(
				{ error: 'Sign in before using Briefly.', code: 'authentication_required' },
				{ status: 401 }
			)
		};
	}
	const record = await accountRecord(env, email);
	if (
		!(await hasComplimentaryPlusAccess(env, email)) &&
		!(await activeAppStoreSubscription(env, record?.account_id))
	) {
		return {
			response: json(
				{ error: 'An active Briefly membership is required.', code: 'subscription_required' },
				{ status: 402 }
			)
		};
	}
	return { email, customer: record ?? (await ensureAccount(env, email)) };
}

async function accountServiceLimits(env, accountID, service) {
	const defaults = serviceUsageLimits[service];
	const override = await env.DB.prepare(
		`SELECT daily_units, monthly_units, concurrency
		 FROM service_limit_overrides
		 WHERE account_id = ? AND service = ?`
	)
		.bind(accountID, service)
		.first();
	if (!override) return defaults;
	return {
		...defaults,
		dailyUnits: Number(override.daily_units),
		monthlyUnits: Number(override.monthly_units),
		concurrency: Number(override.concurrency)
	};
}

async function reserveServiceLease(env, accountID, service, limits) {
	const now = Date.now();
	const leaseID = crypto.randomUUID();
	await env.DB.prepare('DELETE FROM service_leases WHERE expires_at <= ?')
		.bind(now)
		.run();
	const result = await env.DB.prepare(
		`INSERT INTO service_leases (lease_id, account_id, service, expires_at, created_at)
		 SELECT ?, ?, ?, ?, ?
		 WHERE (
			SELECT COUNT(*) FROM service_leases
			WHERE account_id = ? AND service = ? AND expires_at > ?
		 ) < ?`
	)
		.bind(
			leaseID,
			accountID,
			service,
			now + limits.leaseMilliseconds,
			now,
			accountID,
			service,
			now,
			limits.concurrency
		)
		.run();
	return databaseChanges(result) === 1 ? leaseID : null;
}

async function releaseServiceLease(env, accountID, service, leaseID) {
	await env.DB.prepare(
		'DELETE FROM service_leases WHERE lease_id = ? AND account_id = ? AND service = ?'
	)
		.bind(leaseID, accountID, service)
		.run();
}

async function validServiceLease(env, accountID, service, leaseID) {
	return env.DB.prepare(
		`SELECT lease_id FROM service_leases
		 WHERE lease_id = ? AND account_id = ? AND service = ? AND expires_at > ?`
	)
		.bind(leaseID, accountID, service, Date.now())
		.first();
}

async function consumeServiceUnits(env, accountID, service, units, limits) {
	const now = new Date();
	const day = now.toISOString().slice(0, 10);
	const month = day.slice(0, 7);
	const usage = await env.DB.prepare(
		`SELECT
			COALESCE(MAX(CASE WHEN usage_day = ? THEN units ELSE 0 END), 0) AS daily_units,
			COALESCE(SUM(CASE WHEN substr(usage_day, 1, 7) = ? THEN units ELSE 0 END), 0) AS monthly_units
		 FROM service_usage
		 WHERE account_id = ? AND service = ?`
	)
		.bind(day, month, accountID, service)
		.first();
	const dailyUnits = Number(usage?.daily_units ?? 0);
	const monthlyUnits = Number(usage?.monthly_units ?? 0);
	if (
		dailyUnits + units > limits.dailyUnits ||
		monthlyUnits + units > limits.monthlyUnits
	) {
		return null;
	}
	// ponytail: the concurrency cap bounds a monthly counter race to one in-flight request.
	const result = await env.DB.prepare(
		`INSERT INTO service_usage (account_id, service, usage_day, units, updated_at)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(account_id, service, usage_day) DO UPDATE SET
			units = service_usage.units + excluded.units,
			updated_at = excluded.updated_at
		 WHERE service_usage.units + excluded.units <= ?`
	)
		.bind(accountID, service, day, units, Date.now(), limits.dailyUnits)
		.run();
	if (databaseChanges(result) !== 1) return null;
	return {
		dailyUnits: dailyUnits + units,
		monthlyUnits: monthlyUnits + units
	};
}

async function serviceUsage(request, env) {
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid usage request.' }, { status: 400 });
	}
	const defaults = serviceUsageLimits[value?.service];
	if (!defaults || !['reserve', 'release'].includes(value?.action)) {
		return json({ error: 'Invalid usage request.' }, { status: 400 });
	}
	if (value.action === 'reserve' && !paidProcessingEnabled(env)) {
		return json({ error: 'Paid processing is temporarily paused.' }, { status: 503 });
	}
	const account = await serviceAccount(request, env);
	if (account.response) return account.response;
	const service = value.service;
	const accountID = account.customer.account_id;
	const leaseID =
		typeof value.leaseID === 'string' && /^[0-9a-f-]{36}$/i.test(value.leaseID)
			? value.leaseID
			: null;
	if (value.action === 'release') {
		if (!leaseID) return json({ error: 'Invalid usage lease.' }, { status: 400 });
		await releaseServiceLease(env, accountID, service, leaseID);
		return json({ released: true });
	}

	const limits = await accountServiceLimits(env, accountID, service);
	const units = Number(value.units ?? 0);
	if (!Number.isSafeInteger(units) || units < 0 || units > limits.dailyUnits) {
		return json({ error: 'Invalid usage amount.' }, { status: 400 });
	}
	const activeLease = leaseID
		? (await validServiceLease(env, accountID, service, leaseID))
			? leaseID
			: null
		: await reserveServiceLease(env, accountID, service, limits);
	if (!activeLease) return quotaResponse('Too many jobs are already running.');
	const usage =
		units === 0
			? { dailyUnits: 0, monthlyUnits: 0 }
			: await consumeServiceUnits(env, accountID, service, units, limits);
	if (!usage) {
		if (!leaseID) await releaseServiceLease(env, accountID, service, activeLease);
		return quotaResponse('This account has reached its processing allowance.');
	}
	return json({
		leaseID: activeLease,
		usage,
		limits: {
			dailyUnits: limits.dailyUnits,
			monthlyUnits: limits.monthlyUnits,
			concurrency: limits.concurrency
		}
	});
}

async function cleanServiceUsage(env) {
	const cutoff = new Date();
	cutoff.setUTCMonth(cutoff.getUTCMonth() - 2);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM service_leases WHERE expires_at <= ?').bind(Date.now()),
		env.DB.prepare('DELETE FROM service_usage WHERE usage_day < ?').bind(
			cutoff.toISOString().slice(0, 10)
		)
	]);
}

const shareVariants = ['brief', 'concise', 'detailed', 'comprehensive'];
const shareInputVariants = [...shareVariants, 'source'];
const maximumShareDocumentBytes = 1_000_000;
const maximumSharePayloadBytes = 3_000_000;
const maximumShareTextBytesPerAccount = 100_000_000;

function validCaptureIdentifier(value) {
	return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(value);
}

function wordCount(text) {
	return text.trim() ? text.trim().split(/\s+/u).length : 0;
}

function scheduleSharingOperation(context, task) {
	if (context?.waitUntil) context.waitUntil(task);
	else void task;
}

function validShareToken(value) {
	return typeof value === 'string' && /^[A-Za-z0-9_-]{32}$/.test(value);
}

function shareLinkURL(request, token) {
	const url = new URL('/', request.url);
	url.searchParams.set('shared', token);
	return url.toString();
}

function shareSourceString(value, maximumLength, required = false) {
	if (value === undefined && !required) return undefined;
	if (typeof value !== 'string' || value.length > maximumLength || (required && !value.trim())) {
		throw new Error('The selected document contains invalid metadata.');
	}
	return value;
}

function shareSourceStrings(value) {
	if (
		!Array.isArray(value) ||
		value.length > 100 ||
		value.some((item) => typeof item !== 'string' || item.length > 256)
	) {
		throw new Error('The selected document contains invalid metadata.');
	}
	return value;
}

function directShareSource(value, captureID) {
	if (value === undefined) return null;
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		throw new Error('The selected document is invalid.');
	}
	if (
		typeof value.filename !== 'string' ||
		!/^[^/\\]{1,255}\.md$/i.test(value.filename) ||
		!Array.isArray(value.texts) ||
		value.texts.length < 1 ||
		value.texts.length > shareInputVariants.length
	) {
		throw new Error('The selected document is invalid.');
	}
	const title = shareSourceString(value.title, 500, true);
	const excerpt = shareSourceString(value.excerpt, 2_000) ?? '';
	const documents = [];
	const variants = new Set();
	let totalBytes = 0;
	for (const document of value.texts) {
		if (
			typeof document !== 'object' ||
			document === null ||
			!shareInputVariants.includes(document.variant) ||
			variants.has(document.variant) ||
			typeof document.markdown !== 'string'
		) {
			throw new Error('The selected document is invalid.');
		}
		const byteCount = new TextEncoder().encode(document.markdown).byteLength;
		if (byteCount > maximumShareDocumentBytes) {
			throw new Error('The selected document is too large to share.');
		}
		variants.add(document.variant);
		if (document.variant === 'source') continue;
		totalBytes += byteCount;
		if (totalBytes > maximumSharePayloadBytes) {
			throw new Error('The selected document is too large to share.');
		}
		documents.push({
			variant: document.variant,
			markdown: document.markdown,
			wordCount: wordCount(document.markdown)
		});
	}
	if (!documents.length) throw new Error('The selected document has no summary to share.');
	return {
		entry: {
			captureID,
			title,
			excerpt,
			topicIDs: shareSourceStrings(value.topicIDs),
			topicNames: shareSourceStrings(value.topicNames),
			tags: shareSourceStrings(value.tags),
			sourceURL: shareSourceString(value.sourceURL, 2_048),
			createdAt: shareSourceString(value.createdAt, 64),
			updatedAt: shareSourceString(value.updatedAt, 64)
		},
		sourcePath: `library/${value.filename}`,
		documents
	};
}

function validateShareDocuments(documents) {
	let totalBytes = 0;
	for (const document of documents) {
		const byteCount = new TextEncoder().encode(document.markdown).byteLength;
		totalBytes += byteCount;
		if (byteCount > maximumShareDocumentBytes || totalBytes > maximumSharePayloadBytes) {
			throw new Error('The selected document is too large to share.');
		}
	}
	return totalBytes;
}

async function ownerShareTextBytes(env, email, excludedToken) {
	const row = await env.DB.prepare(
		`SELECT COALESCE(SUM(length(CAST(text.markdown AS BLOB))), 0) AS byte_count
		 FROM share_texts text
		 JOIN share_links link ON link.token = text.share_token
		 WHERE link.owner_email = ? AND text.share_token <> ?`
	)
		.bind(email, excludedToken)
		.first();
	return Number(row?.byte_count ?? 0);
}

async function shareLinkForOwner(env, email, captureID) {
	return env.DB.prepare(
		`SELECT token, owner_email, capture_id, generation, revision, status,
		        metadata_json, source_filename, error_message, created_at, updated_at
		 FROM share_links
		 WHERE owner_email = ? AND capture_id = ?`
	)
		.bind(email, captureID)
		.first();
}

async function shareLinkByToken(env, token) {
	return env.DB.prepare(
		`SELECT token, owner_email, capture_id, generation, revision, status,
		        metadata_json, source_filename, error_message, created_at, updated_at
		 FROM share_links
		 WHERE token = ?`
	)
		.bind(token)
		.first();
}

async function shareLinksForOwner(env, email) {
	return env.DB.prepare(
		`SELECT token, owner_email, capture_id, generation, revision, status,
		        metadata_json, source_filename, error_message, created_at, updated_at
		 FROM share_links
		 WHERE owner_email = ?
		 ORDER BY updated_at DESC
		 LIMIT ?`
	)
		.bind(email, maximumActiveShareLinks)
		.all();
}

function shareLinkResponse(request, record) {
	if (!record) return { shared: false };
	let metadata;
	try {
		metadata = record.metadata_json ? JSON.parse(record.metadata_json) : undefined;
	} catch {
		metadata = undefined;
	}
	return {
		shared: true,
		token: record.token,
		generation: record.generation,
		url: shareLinkURL(request, record.token),
		status: record.status,
		revision: Number(record.revision ?? 1),
		error: record.error_message ?? undefined,
		metadata,
		updatedAt: record.updated_at
	};
}

async function removeShareGeneration(env, token, generation) {
	await env.DB.prepare('DELETE FROM share_texts WHERE share_token = ? AND generation = ?')
		.bind(token, generation)
		.run();
}

async function removeOldShareGenerations(env, token, currentGeneration) {
	await env.DB.prepare('DELETE FROM share_texts WHERE share_token = ? AND generation <> ?')
		.bind(token, currentGeneration)
		.run();
}

async function prepareShareLink(env, email, token, captureID, generation, source) {
	try {
		if (!source?.documents?.length) throw new Error('No summary is available to share.');
		const textBytes = validateShareDocuments(source.documents);
		if (
			(await ownerShareTextBytes(env, email, token)) + textBytes >
			maximumShareTextBytesPerAccount
		) {
			throw new Error('This account has reached its public sharing storage limit.');
		}
		for (const document of source.documents) {
			await env.DB.prepare(
				`INSERT OR REPLACE INTO share_texts (
					share_token, generation, variant, markdown, word_count
				 ) VALUES (?, ?, ?, ?, ?)`
			)
				.bind(token, generation, document.variant, document.markdown, document.wordCount)
				.run();
		}
		const metadata = {
			captureID: source.entry.captureID ?? captureID,
			title: source.entry.title,
			excerpt: source.entry.excerpt,
			topicIDs: source.entry.topicIDs ?? [],
			topicNames: source.entry.topicNames ?? [],
			tags: source.entry.tags ?? [],
			sourceURL: source.entry.sourceURL,
			createdAt: source.entry.createdAt,
			updatedAt: source.entry.updatedAt
		};
		const completed = await env.DB.prepare(
			`UPDATE share_links
			 SET status = 'ready', metadata_json = ?, source_filename = ?,
			     error_message = NULL, updated_at = ?
			 WHERE token = ? AND generation = ?`
		)
			.bind(
				JSON.stringify(metadata),
				source.sourcePath.split('/').at(-1),
				new Date().toISOString(),
				token,
				generation
			)
			.run();
		if (databaseChanges(completed) === 0) {
			await removeShareGeneration(env, token, generation);
			return;
		}
		await removeOldShareGenerations(env, token, generation);
	} catch (error) {
		await env.DB.prepare(
			`UPDATE share_links
			 SET status = 'failed', error_message = ?, updated_at = ?
			 WHERE token = ? AND generation = ?`
		)
			.bind(
				error instanceof Error ? error.message : 'The share link could not be prepared.',
				new Date().toISOString(),
				token,
				generation
			)
			.run();
	}
}

async function ownerShareLinkStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!captureID) {
		const result = await shareLinksForOwner(env, email);
		return json({
			limit: maximumActiveShareLinks,
			links: (result.results ?? []).map((record) => ({
				...shareLinkResponse(request, record),
				captureID: record.capture_id
			}))
		});
	}
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	return json(shareLinkResponse(request, await shareLinkForOwner(env, email, captureID)));
}

function contentReportString(value, maximumLength, required = false) {
	if (value === undefined || value === null) {
		if (required) throw new Error('Complete every required report field.');
		return undefined;
	}
	if (typeof value !== 'string') throw new Error('The report contains invalid text.');
	const result = value.trim();
	if ((required && !result) || result.length > maximumLength) {
		throw new Error('The report contains invalid text.');
	}
	return result || undefined;
}

async function publicContentReport(request, env, token) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const share = await shareLinkByToken(env, token);
	if (!share) return json({ error: 'This share link is no longer available.' }, { status: 404 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid content report.' }, { status: 400 });
	}
	try {
		const category = contentReportString(value?.category, 32, true);
		if (!contentReportCategories.has(category)) throw new Error('Choose a valid report reason.');
		const childSafety = category === 'child-safety';
		const reporterName = contentReportString(value?.reporterName, 200, !childSafety);
		const reporterEmail = contentReportString(value?.reporterEmail, 254, !childSafety);
		if (reporterEmail && !emailAddressPattern.test(reporterEmail)) {
			throw new Error('Enter a valid email address.');
		}
		const workDescription = contentReportString(
			value?.workDescription,
			2_000,
			category === 'copyright'
		);
		const explanation = contentReportString(value?.explanation, 5_000, true);
		const variant = value?.variant;
		if (variant !== undefined && !shareVariants.includes(variant)) {
			throw new Error('Choose a valid document version.');
		}
		if (value?.goodFaith !== true) {
			throw new Error('Confirm that the report is accurate and complete.');
		}
		let metadata = {};
		try {
			metadata = JSON.parse(share.metadata_json ?? '{}');
		} catch {
			metadata = {};
		}
		const id = crypto.randomUUID();
		const createdAt = Date.now();
		const inserted = await env.DB.prepare(
			`INSERT INTO content_reports (
				id, share_token, owner_email, capture_id, share_title, reported_url,
				variant, category, reporter_name, reporter_email, work_description,
				explanation, status, created_at
			)
			SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?
			WHERE (
				SELECT COUNT(*) FROM content_reports
				WHERE share_token = ? AND created_at >= ?
			) < ?`
		)
			.bind(
				id,
				token,
				share.owner_email,
				share.capture_id,
				String(metadata.title ?? 'Shared document').slice(0, 500),
				shareLinkURL(request, token),
				variant ?? null,
				category,
				reporterName ?? null,
				reporterEmail ?? null,
				workDescription ?? null,
				explanation,
				createdAt,
				token,
				createdAt - 24 * 60 * 60 * 1000,
				maximumContentReportsPerSharePerDay
			)
			.run();
		if (databaseChanges(inserted) !== 1) {
			return json(
				{ error: 'This share has received many recent reports. Email hello@readbriefly.fyi.' },
				{ status: 429 }
			);
		}
		return json({ id, receivedAt: new Date(createdAt).toISOString() }, { status: 201 });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'Invalid content report.' },
			{ status: 400 }
		);
	}
}

async function adminContentReports(request, env, context) {
	const administrator = await administratorRequest(request, env);
	if (administrator.response) return administrator.response;
	if (request.method === 'GET') {
		const result = await env.DB.prepare(
			`SELECT id, share_token, owner_email, capture_id, share_title, reported_url,
			        variant, category, reporter_name, reporter_email, work_description,
			        explanation, status, created_at, resolved_at
			 FROM content_reports
			 ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END, created_at DESC
			 LIMIT 100`
		).all();
		return json({
			reports: (result.results ?? []).map((report) => ({
				id: report.id,
				shareToken: report.share_token,
				ownerEmail: report.owner_email,
				captureID: report.capture_id,
				shareTitle: report.share_title,
				reportedURL: report.reported_url,
				variant: report.variant ?? undefined,
				category: report.category,
				reporterName: report.reporter_name ?? undefined,
				reporterEmail: report.reporter_email ?? undefined,
				workDescription: report.work_description ?? undefined,
				explanation: report.explanation,
				status: report.status,
				createdAt: Number(report.created_at),
				resolvedAt: report.resolved_at === null ? undefined : Number(report.resolved_at)
			}))
		});
	}
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid report decision.' }, { status: 400 });
	}
	if (!uuidPattern.test(value?.id ?? '') || !['removed', 'no-action'].includes(value?.decision)) {
		return json({ error: 'Invalid report decision.' }, { status: 400 });
	}
	const report = await env.DB.prepare(
		`SELECT id, share_token, owner_email, capture_id
		 FROM content_reports WHERE id = ?`
	)
		.bind(value.id)
		.first();
	if (!report) return json({ error: 'Content report not found.' }, { status: 404 });
	const resolvedAt = Date.now();
	if (value.decision === 'removed') {
		const message = `This public share was removed after content report ${report.id}. Email hello@readbriefly.fyi to appeal.`;
		await env.DB.batch([
			env.DB.prepare('DELETE FROM share_texts WHERE share_token = ?').bind(report.share_token),
			env.DB.prepare(
				`UPDATE share_links
				 SET status = 'failed', error_message = ?, updated_at = ?
				 WHERE token = ?`
			).bind(message, new Date(resolvedAt).toISOString(), report.share_token),
			env.DB.prepare(
				`UPDATE content_reports
				 SET status = 'removed', resolved_at = ? WHERE id = ?`
			).bind(resolvedAt, report.id)
		]);
	} else {
		await env.DB.prepare(
			`UPDATE content_reports
			 SET status = 'no-action', resolved_at = ? WHERE id = ?`
		)
			.bind(resolvedAt, report.id)
			.run();
	}
	return json({ id: report.id, status: value.decision, resolvedAt });
}

async function publishShareLink(request, env, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid share-link request.' }, { status: 400 });
	}
	const captureID = value?.captureID;
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	const removed = await env.DB.prepare(
		`SELECT id FROM content_reports
		 WHERE owner_email = ? AND capture_id = ? AND status = 'removed'
		 LIMIT 1`
	)
		.bind(email, captureID)
		.first();
	if (removed) {
		return json(
			{
				error: `This document was removed after content report ${removed.id}. Email hello@readbriefly.fyi to appeal.`
			},
			{ status: 403 }
		);
	}
	let source;
	try {
		source = directShareSource(value?.source, captureID);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The selected document is invalid.' },
			{ status: 400 }
		);
	}
	if (!source) return json({ error: 'Include the document to publish.' }, { status: 400 });
	const token = randomBase64URL(24);
	const generation = crypto.randomUUID();
	const now = new Date().toISOString();
	const published = await env.DB.prepare(
		`INSERT INTO share_links (
			token, owner_email, capture_id, generation, revision, status,
			metadata_json, source_filename, error_message, created_at, updated_at
		)
		SELECT ?, ?, ?, ?, 1, 'preparing', NULL, NULL, NULL, ?, ?
		WHERE EXISTS (
			SELECT 1 FROM share_links WHERE owner_email = ? AND capture_id = ?
		) OR (
			SELECT COUNT(*) FROM share_links WHERE owner_email = ?
		) < ?
		ON CONFLICT(owner_email, capture_id) DO UPDATE SET
			generation = excluded.generation,
			revision = share_links.revision + 1,
			status = 'preparing',
			error_message = NULL,
			updated_at = excluded.updated_at`
	)
		.bind(
			token,
			email,
			captureID,
			generation,
			now,
			now,
			email,
			captureID,
			email,
			maximumActiveShareLinks
		)
		.run();
	if (Number(published?.meta?.changes ?? 0) === 0) {
		return json(
			{
				error: `You can publish up to ${maximumActiveShareLinks} active links. Stop sharing one before creating another.`,
				code: 'share_limit_reached'
			},
			{ status: 409 }
		);
	}
	const record = await shareLinkForOwner(env, email, captureID);
	scheduleSharingOperation(
		context,
		prepareShareLink(env, email, record.token, captureID, generation, source)
	);
	return json(shareLinkResponse(request, record), { status: 202 });
}

async function revokeShareLink(request, env, token, context) {
	void context;
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const record = await shareLinkByToken(env, token);
	if (!record || record.owner_email !== email) {
		return json({ error: 'Share link not found.' }, { status: 404 });
	}
	await env.DB.batch([
		env.DB.prepare('DELETE FROM share_texts WHERE share_token = ?').bind(token),
		env.DB.prepare('DELETE FROM share_links WHERE token = ? AND owner_email = ?').bind(token, email)
	]);
	return json({ revoked: true });
}

async function publicShareDocument(request, env, token) {
	const record = await shareLinkByToken(env, token);
	if (!record) return json({ error: 'This share link is no longer available.' }, { status: 404 });
	if (record.status !== 'ready') {
		return json(
			{
				status: record.status,
				error: record.status === 'failed' ? record.error_message : undefined
			},
			{ status: record.status === 'preparing' ? 202 : 409 }
		);
	}
	const textResult = await env.DB.prepare(
		`SELECT variant, markdown, word_count FROM share_texts
		 WHERE share_token = ? AND generation = ? AND variant <> 'source'`
	)
		.bind(token, record.generation)
		.all();
	let metadata = {};
	try {
		metadata = JSON.parse(record.metadata_json ?? '{}');
	} catch {
		metadata = {};
	}
	const texts = (textResult.results ?? [])
		.filter((document) => shareVariants.includes(document.variant))
		.map((document) => ({
			variant: document.variant,
			markdown: document.markdown,
			wordCount: Number(document.word_count ?? 0)
		}))
		.sort(
			(a, b) => shareVariants.indexOf(a.variant) - shareVariants.indexOf(b.variant)
		);
	return json({
		status: 'ready',
		token,
		revision: Number(record.revision ?? 1),
		...metadata,
		texts,
		updatedAt: record.updated_at
	});
}

const routeWorker = {
	async fetch(request, env, context) {
		const url = new URL(request.url);
		if (url.hostname === 'readbriefly.fyi') {
			url.hostname = 'www.readbriefly.fyi';
			return Response.redirect(url.toString(), 308);
		}
		const publicReport = url.pathname.match(
			/^\/api\/public\/shares\/([A-Za-z0-9_-]{32})\/reports$/
		);
		if (publicReport && request.method === 'POST') {
			return publicContentReport(request, env, publicReport[1]);
		}
		const publicShare = url.pathname.match(
			/^\/api\/public\/shares\/([A-Za-z0-9_-]{32})$/
		);
		if (publicShare && request.method === 'GET') {
			return publicShareDocument(request, env, publicShare[1]);
		}
		if (url.pathname === '/api/auth/status' && request.method === 'GET') {
			return accountStatus(request, env);
		}
		if (url.pathname === '/api/auth/apple/start' && request.method === 'GET') {
			return startAppleLogin(request, env);
		}
		if (url.pathname === '/api/auth/apple/callback' && request.method === 'POST') {
			return finishAppleLogin(request, env);
		}
		if (url.pathname === '/api/auth/apple/native' && request.method === 'POST') {
			return finishNativeAppleLogin(request, env);
		}
		if (url.pathname === '/api/auth/logout' && request.method === 'POST') {
			return signOut(request, env);
		}
		if (
			url.pathname === '/api/admin/complimentary-access' &&
			['GET', 'POST', 'DELETE'].includes(request.method)
		) {
			return adminComplimentaryAccess(request, env);
		}
		if (
			url.pathname === '/api/admin/usage' &&
			['GET', 'PUT', 'DELETE'].includes(request.method)
		) {
			return adminUsage(request, env);
		}
		if (
			url.pathname === '/api/admin/content-reports' &&
			['GET', 'PATCH'].includes(request.method)
		) {
			return adminContentReports(request, env, context);
		}
		if (url.pathname === '/api/feedback' && request.method === 'GET') {
			return feedbackBoard(request, env);
		}
		if (url.pathname === '/api/feedback' && request.method === 'POST') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return createFeedback(request, env);
		}
		const feedbackUpvote = url.pathname.match(
			/^\/api\/feedback\/([0-9a-f-]{36})\/upvote$/
		);
		if (feedbackUpvote && request.method === 'PUT') {
			return setFeedbackUpvote(request, env, feedbackUpvote[1]);
		}
		if (url.pathname === '/api/usage' && request.method === 'POST') {
			return serviceUsage(request, env);
		}
		if (url.pathname === '/api/billing/apple/transaction' && request.method === 'POST') {
			return syncAppStoreTransaction(request, env);
		}
		if (url.pathname === '/api/billing/apple/notifications' && request.method === 'POST') {
			return appStoreNotification(request, env);
		}
		if (url.pathname === '/api/extraction/firecrawl' && request.method === 'POST') {
			return scrapeWithFirecrawl(request, env);
		}
		if (url.pathname === '/api/ai/process' && request.method === 'POST') {
			return processWithManagedAI(request, env);
		}
		if (url.pathname === '/api/share-links' && request.method === 'GET') {
			return ownerShareLinkStatus(request, env);
		}
		if (url.pathname === '/api/share-links' && request.method === 'POST') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return publishShareLink(request, env, context);
		}
		const ownerShare = url.pathname.match(/^\/api\/share-links\/([A-Za-z0-9_-]{32})$/);
		if (ownerShare && request.method === 'DELETE') {
			return revokeShareLink(request, env, ownerShare[1], context);
		}
		if (url.pathname.startsWith('/api/')) {
			return json({ error: 'Not found.' }, { status: 404 });
		}

		return env.ASSETS.fetch(request);
	},
	async scheduled(_controller, env, context) {
		context.waitUntil(cleanServiceUsage(env));
	}
};

const contentSecurityPolicy = [
	"default-src 'self'",
	"script-src 'self'",
	"style-src 'self' 'unsafe-inline'",
	"font-src 'self'",
	"img-src 'self' data: blob:",
	"media-src 'self' blob:",
	"connect-src 'self' https://*.apple.com https://*.posthog.com",
	"frame-src https://*.apple.com",
	"object-src 'none'",
	"base-uri 'self'",
	"form-action 'self'",
	"frame-ancestors 'none'"
].join('; ');

function secureResponse(response, requestID) {
	const headers = new Headers(response.headers);
	headers.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');
	headers.set('X-Content-Type-Options', 'nosniff');
	headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
	headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()');
	headers.set('X-Frame-Options', 'DENY');
	headers.set('Content-Security-Policy', contentSecurityPolicy);
	headers.set('X-Request-ID', requestID);
	return new Response(response.body, {
		status: response.status,
		statusText: response.statusText,
		headers
	});
}

const worker = {
	async fetch(request, env, context) {
		const requestID = crypto.randomUUID();
		try {
			return secureResponse(
				await routeWorker.fetch(request, env, context),
				requestID
			);
		} catch (error) {
			console.error(
				JSON.stringify({
					level: 'error',
					requestID,
					method: request.method,
					path: new URL(request.url).pathname,
					message: error instanceof Error ? error.message : String(error)
				})
			);
			return secureResponse(
				json(
					{ error: 'Briefly could not complete this request.', requestID },
					{ status: 500 }
				),
				requestID
			);
		}
	},
	scheduled(controller, env, context) {
		return routeWorker.scheduled(controller, env, context);
	}
};

export { serviceUsageLimits, validAppStoreTransaction };
export default worker;
