import {
	json,
	requireSameOrigin,
	sessionCookie,
	sessionLifetimeMilliseconds,
	sessionTokenFromRequest
} from '../../infrastructure/http-security.js';
import { randomBase64URL, sha256Hex } from '../../infrastructure/crypto.js';

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

export { authenticatedEmail, createSession, signOut };
