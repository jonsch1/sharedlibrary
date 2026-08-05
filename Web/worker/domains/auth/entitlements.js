import { json } from '../../infrastructure/http-security.js';
import { normalizedEmail } from '../../infrastructure/input-validation.js';
import { accountRecord } from './account-operations.js';
import { authenticatedEmail } from './session.js';

const administratorEmails = new Set(['schauljonathan@gmail.com']);

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

export {
	activeAppStoreSubscription,
	hasComplimentaryPlusAccess,
	isAdministrator,
	paidAccessResponse
};
