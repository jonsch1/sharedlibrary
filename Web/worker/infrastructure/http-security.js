const sessionCookieName = 'shared_library_session';
const sessionLifetimeMilliseconds = 90 * 24 * 60 * 60 * 1000;

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

function sameOriginResponse(request) {
	return requireSameOrigin(request)
		? null
		: json({ error: 'Invalid request origin.' }, { status: 403 });
}

async function requestJSON(request) {
	try {
		return await request.json();
	} catch {
		return undefined;
	}
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
	contentSecurityPolicy,
	json,
	requireSameOrigin,
	requestJSON,
	sameOriginResponse,
	secureResponse,
	sessionCookie,
	sessionLifetimeMilliseconds,
	sessionTokenFromRequest
};
