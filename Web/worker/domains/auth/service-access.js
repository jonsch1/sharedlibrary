import { json } from '../../infrastructure/http-security.js';
import { normalizedEmail } from '../../infrastructure/input-validation.js';
import { isAppReviewAccount } from './review-access.js';
import { authenticatedEmail } from './session.js';

const administratorEmails = new Set(['schauljonathan@gmail.com']);

function isAdministrator(email) {
	return administratorEmails.has(normalizedEmail(email));
}

async function hasHostedServiceAccess(env, email) {
	const normalized = normalizedEmail(email);
	if (!normalized) return false;
	if (isAppReviewAccount(env, normalized) || isAdministrator(normalized)) return true;
	return Boolean(
		await env.DB.prepare('SELECT user_email FROM service_access WHERE user_email = ?')
			.bind(normalized)
			.first()
	);
}

async function hostedServiceAccessResponse(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ error: 'Sign in before using Briefly.', code: 'authentication_required' },
			{ status: 401 }
		);
	}
	if (await hasHostedServiceAccess(env, email)) return null;
	return json(
		{
			error: 'Hosted processing is unavailable for this account.',
			code: 'service_access_required'
		},
		{ status: 403 }
	);
}

export { hasHostedServiceAccess, hostedServiceAccessResponse, isAdministrator };
