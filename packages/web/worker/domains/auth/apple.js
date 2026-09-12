import { json, requestJSON, sameOriginResponse } from '../../infrastructure/http-security.js';
import {
	base64URLToBytes,
	bytesToBase64URL,
	decodeJWTPart,
	pemBytes,
	randomBase64URL,
	sha256Hex
} from '../../infrastructure/crypto.js';
import { accountPayload } from './account-status.js';
import { createSession } from './session.js';

const oauthStateLifetimeMilliseconds = 10 * 60 * 1000;
const appleStateCookieName = '__Host-briefly_apple_state';

function appleTokenConfig(env, clientID) {
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

function appleAuthConfig(env) {
	return appleTokenConfig(env, String(env.APPLE_CLIENT_ID || '').trim());
}

function nativeAppleAuthConfig(env) {
	const clientID = String(env.APPLE_APP_BUNDLE_ID || 'fyi.readbriefly.BrieflyNative').trim();
	return appleTokenConfig(env, clientID);
}

function safeReturnTo(value, baseURL) {
	if (typeof value !== 'string' || !value.startsWith('/')) return '/';
	try {
		const origin = new URL(baseURL).origin;
		const destination = new URL(value, origin);
		return destination.origin === origin
			? destination.pathname + destination.search + destination.hash
			: '/';
	} catch {
		return '/';
	}
}

function appleStateCookie(state, maximumAgeSeconds) {
	// Apple's form_post callback is cross-site, so the binding must use SameSite=None.
	return `${appleStateCookieName}=${state}; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=${maximumAgeSeconds}`;
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
	const destination = new URL(safeReturnTo(returnTo, request.url), request.url);
	destination.searchParams.set(provider, 'signed-in');
	const headers = new Headers({ Location: destination.toString(), 'Set-Cookie': cookie });
	headers.append('Set-Cookie', appleStateCookie('', 0));
	return new Response(null, {
		status: 302,
		headers
	});
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

async function exchangeAppleAuthorizationCode(config, code, redirectURI) {
	const body = new URLSearchParams({
		client_id: config.clientID,
		client_secret: await appleClientSecret(config),
		code,
		grant_type: 'authorization_code'
	});
	if (redirectURI) body.set('redirect_uri', redirectURI);
	const response = await fetch('https://appleid.apple.com/auth/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body
	});
	let value = {};
	try {
		value = await response.json();
	} catch {
		value = {};
	}
	return { response, value };
}

async function storeAppleAuthorization(env, subject, clientID, refreshToken) {
	if (
		typeof subject !== 'string' ||
		!subject ||
		typeof refreshToken !== 'string' ||
		!refreshToken
	) {
		throw new Error('Apple did not return a revocable authorization.');
	}
	const now = Date.now();
	await env.DB.prepare(
		'INSERT INTO apple_authorizations (subject, client_id, refresh_token, created_at, updated_at)\n' +
			'VALUES (?, ?, ?, ?, ?)\n' +
			'ON CONFLICT(subject) DO UPDATE SET\n' +
			'client_id = excluded.client_id,\n' +
			'refresh_token = excluded.refresh_token,\n' +
			'updated_at = excluded.updated_at'
	)
		.bind(subject, clientID, refreshToken, now, now)
		.run();
}

async function revokeAppleAuthorizationForEmail(env, email) {
	const authorization = await env.DB.prepare(
		'SELECT authorization.client_id, authorization.refresh_token\n' +
			'FROM auth_identities AS identity\n' +
			'JOIN apple_authorizations AS authorization ON authorization.subject = identity.subject\n' +
			'WHERE identity.provider = \'apple\' AND identity.user_email = ?\n' +
			'LIMIT 1'
	)
		.bind(email)
		.first();
	if (!authorization?.refresh_token || !authorization?.client_id) return false;
	const config = appleTokenConfig(env, authorization.client_id);
	if (!config) throw new Error('Apple account revocation is not configured.');
	const response = await fetch('https://appleid.apple.com/auth/revoke', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: config.clientID,
			client_secret: await appleClientSecret(config),
			token: authorization.refresh_token,
			token_type_hint: 'refresh_token'
		})
	});
	if (!response.ok) {
		throw new Error('Apple could not revoke this account authorization.');
	}
	return true;
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
				safeReturnTo(new URL(request.url).searchParams.get('return_to'), request.url),
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
	return new Response(null, {
		status: 302,
		headers: {
			Location: authorizationURL.toString(),
			'Set-Cookie': appleStateCookie(state, oauthStateLifetimeMilliseconds / 1000)
		}
	});
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
	const browserState = (request.headers.get('Cookie') ?? '')
		.split(';')
		.map((cookie) => cookie.trim())
		.find((cookie) => cookie.startsWith(appleStateCookieName + '='))
		?.slice(appleStateCookieName.length + 1);
	if (!browserState || browserState !== state) {
		return redirectWithProviderResult(request, 'apple', 'error');
	}
	const pending = await env.DB.prepare(
		'DELETE FROM apple_login_states WHERE state = ? AND created_at >= ?\n' +
			'RETURNING nonce, return_to'
	)
		.bind(state, Date.now() - oauthStateLifetimeMilliseconds)
		.first();
	if (!pending) {
		return redirectWithProviderResult(request, 'apple', 'expired');
	}
	const config = appleAuthConfig(env);
	if (!config) return redirectWithProviderResult(request, 'apple', 'error');
	const { response, value } = await exchangeAppleAuthorizationCode(
		config,
		code,
		new URL('/api/auth/apple/callback', request.url).toString()
	);
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
	try {
		await storeAppleAuthorization(env, claims.sub, config.clientID, value.refresh_token);
	} catch {
		return redirectWithProviderResult(request, 'apple', 'error');
	}
	return authenticatedRedirect(request, env, email, pending.return_to, 'apple');
}

async function finishNativeAppleLogin(request, env) {
	const originError = sameOriginResponse(request);
	if (originError) return originError;
	const value = await requestJSON(request);
	if (value === undefined) {
		return json({ error: 'Invalid Apple credential.' }, { status: 400 });
	}
	const identityToken = typeof value?.identityToken === 'string' ? value.identityToken : '';
	const authorizationCode =
		typeof value?.authorizationCode === 'string' ? value.authorizationCode : '';
	const nonce = typeof value?.nonce === 'string' ? value.nonce : '';
	const config = nativeAppleAuthConfig(env);
	if (
		!config ||
		!identityToken ||
		identityToken.length > 8_192 ||
		!authorizationCode ||
		authorizationCode.length > 4_096 ||
		!nonce ||
		nonce.length > 256
	) {
		return json({ error: 'Invalid Apple credential.' }, { status: 400 });
	}
	const claims = await verifiedAppleIdentity(identityToken, config, await sha256Hex(nonce));
	const exchanged = await exchangeAppleAuthorizationCode(config, authorizationCode);
	const exchangedClaims = exchanged.response.ok
		? await verifiedAppleIdentity(exchanged.value?.id_token, config, await sha256Hex(nonce))
		: null;
	if (!claims || !exchangedClaims || claims.sub !== exchangedClaims.sub) {
		return json({ error: 'Apple sign-in could not be verified.' }, { status: 401 });
	}
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
	try {
		await storeAppleAuthorization(
			env,
			claims.sub,
			config.clientID,
			exchanged.value?.refresh_token
		);
	} catch {
		return json({ error: 'Apple sign-in could not be completed.' }, { status: 502 });
	}
	const account = await accountPayload(env, email);
	const session = await createSession(env, email);
	return json(account, { headers: { 'Set-Cookie': session.cookie } });
}

function redirectWithProviderResult(request, provider, result, path = '/') {
	const destination = new URL(safeReturnTo(path, request.url), request.url);
	destination.searchParams.set(provider, result);
	return new Response(null, {
		status: 302,
		headers: {
			Location: destination.toString(),
			'Set-Cookie': appleStateCookie('', 0)
		}
	});
}

export {
	finishAppleLogin,
	finishNativeAppleLogin,
	revokeAppleAuthorizationForEmail,
	startAppleLogin
};
