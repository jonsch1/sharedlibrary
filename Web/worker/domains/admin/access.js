import { databaseChanges } from '../../infrastructure/database.js';
import { emailAddressPattern, normalizedEmail } from '../../infrastructure/input-validation.js';
import { json, requireSameOrigin } from '../../infrastructure/http-security.js';
import { authenticatedEmail } from '../auth/session.js';
import { isAdministrator } from '../auth/entitlements.js';

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
			'SELECT user_email, granted_by, created_at\n' +
				'FROM complimentary_access\n' +
				'ORDER BY created_at DESC, user_email'
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
			'INSERT OR IGNORE INTO complimentary_access (user_email, granted_by, created_at)\n' +
				'VALUES (?, ?, ?)'
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

export { adminComplimentaryAccess, administratorRequest };
