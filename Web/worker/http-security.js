const sessionCookieName = 'shared_library_session';
const sessionLifetimeMilliseconds = 90 * 24 * 60 * 60 * 1000;
const uuidPattern =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailAddressPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function json(value, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Content-Type', 'application/json');
	headers.set('Cache-Control', 'no-store');
	return new Response(JSON.stringify(value), { ...init, headers });
}

function sessionCookie(token, maximumAgeSeconds) {
	return [
		sessionCookieName + '=' + token,
		'Path=/',
		'HttpOnly',
		'Secure',
		'SameSite=Lax',
		'Max-Age=' + maximumAgeSeconds
	].join('; ');
}

function sessionTokenFromRequest(request) {
	const cookie = request.headers.get('Cookie') ?? '';
	return cookie
		.split(';')
		.map((value) => value.trim())
		.find((value) => value.startsWith(sessionCookieName + '='))
		?.slice(sessionCookieName.length + 1);
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

function pemBytes(value) {
	const encoded = value
		.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
	return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
}

function decodeJWTPart(value) {
	return JSON.parse(new TextDecoder().decode(base64URLToBytes(value)));
}

function databaseChanges(result) {
	return Number(result?.meta?.changes ?? result?.changes ?? 0);
}

function normalizedEmail(email) {
	return String(email || '').trim().toLowerCase();
}

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

export {
	base64URLToBytes,
	bytesToBase64URL,
	contentSecurityPolicy,
	databaseChanges,
	decodeJWTPart,
	emailAddressPattern,
	json,
	normalizedEmail,
	pemBytes,
	randomBase64URL,
	requireSameOrigin,
	secureResponse,
	sessionCookie,
	sessionLifetimeMilliseconds,
	sessionTokenFromRequest,
	sha256Hex,
	uuidPattern
};
