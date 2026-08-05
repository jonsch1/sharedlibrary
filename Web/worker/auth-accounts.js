import {
	base64URLToBytes,
	bytesToBase64URL,
	decodeJWTPart,
	json,
	normalizedEmail,
	pemBytes,
	randomBase64URL,
	requireSameOrigin,
	sessionCookie,
	sessionLifetimeMilliseconds,
	sessionTokenFromRequest,
	sha256Hex
} from './http-security.js';

const oauthStateLifetimeMilliseconds = 10 * 60 * 1000;
const administratorEmails = new Set(['schauljonathan@gmail.com']);

async function authenticatedEmail(request, env) {
	const rawToken = sessionTokenFromRequest(request);
	if (!rawToken || !env.DB) return null;
	const tokenHash = await sha256Hex(rawToken);
	const session = await env.DB.prepare(
		'SELECT user_email, expires_at FROM app_sessions WHERE token_hash = ?'
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

function safeReturnTo(value, fallback = '/') {
	return typeof value === 'string' && value.startsWith('/') && !value.startsWith('//')
		? value
		: fallback;
}

async function identityEmail(env, provider, subject, verifiedEmail) {
	const existing = await env.DB.prepare(
		'SELECT user_email FROM auth_identities WHERE provider = ? AND subject = ?'
	)
		.bind(provider, subject)
		.first();
	if (existing?.user_email) return existing.user_email;
	if (!verifiedEmail) return null;
	await env.DB.prepare(
		'INSERT OR IGNORE INTO auth_identities (provider, subject, user_email, created_at)\n' +
			'VALUES (?, ?, ?, ?)'
	)
		.bind(provider, subject, verifiedEmail, Date.now())
		.run();
	const identity = await env.DB.prepare(
		'SELECT user_email FROM auth_identities WHERE provider = ? AND subject = ?'
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
		'INSERT INTO app_sessions (token_hash, user_email, created_at, expires_at)\n' +
			'VALUES (?, ?, ?, ?)'
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
	const input = encodedHeader + '.' + encodedClaims;
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		key,
		new TextEncoder().encode(input)
	);
	return input + '.' + bytesToBase64URL(new Uint8Array(signature));
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
		new TextEncoder().encode(parts[0] + '.' + parts[1])
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
				'INSERT INTO apple_login_states (state, nonce, return_to, created_at)\n' +
					'VALUES (?, ?, ?, ?)'
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
		'SELECT nonce, return_to, created_at FROM apple_login_states WHERE state = ?'
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

function redirectWithProviderResult(request, provider, result, path = '/') {
	const destination = new URL(path, request.url);
	destination.searchParams.set(provider, result);
	return Response.redirect(destination.toString(), 302);
}

async function accountStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	return json(email ? await accountPayload(env, email) : { authenticated: false });
}

function accountRecord(env, email) {
	return env.DB.prepare('SELECT account_id, user_email FROM accounts WHERE user_email = ?')
		.bind(email)
		.first();
}

async function ensureAccount(env, email) {
	const existing = await accountRecord(env, email);
	if (existing) return existing;
	const now = Date.now();
	await env.DB.prepare(
		'INSERT OR IGNORE INTO accounts (user_email, account_id, created_at, updated_at)\n' +
			'VALUES (?, ?, ?, ?)'
	)
		.bind(email, crypto.randomUUID(), now, now)
		.run();
	return accountRecord(env, email);
}

async function activeAppStoreSubscription(env, accountID, now = Date.now()) {
	if (!accountID) return null;
	return env.DB.prepare(
		'SELECT original_transaction_id, transaction_id, product_id, expires_at\n' +
			'FROM app_store_subscriptions\n' +
			'WHERE account_id = ? AND expires_at > ? AND revocation_date IS NULL\n' +
			'ORDER BY expires_at DESC LIMIT 1'
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

async function signOut(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const rawToken = sessionTokenFromRequest(request);
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

export {
	accountPayload,
	accountRecord,
	accountStatus,
	activeAppStoreSubscription,
	authenticatedEmail,
	ensureAccount,
	finishAppleLogin,
	finishNativeAppleLogin,
	hasComplimentaryPlusAccess,
	isAdministrator,
	paidAccessResponse,
	signOut,
	startAppleLogin
};
