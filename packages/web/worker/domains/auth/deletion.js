import { json, sessionCookie } from '../../infrastructure/http-security.js';
import { accountRecord } from './account-operations.js';
import { revokeAppleAuthorizationForEmail } from './apple.js';
import { isAppReviewAccount } from './review-access.js';
import { authenticatedMutation } from './session.js';

async function deleteAccount(request, env) {
	const authentication = await authenticatedMutation(request, env);
	if (authentication.response) return authentication.response;
	const { email } = authentication;
	const account = await accountRecord(env, email);

	try {
		if (
			!isAppReviewAccount(env, email) &&
			!(await revokeAppleAuthorizationForEmail(env, email))
		) {
			return json(
				{ error: 'Sign out and sign in again before deleting your Briefly account.' },
				{ status: 409 }
			);
		}
	} catch (error) {
		return json(
			{
				error:
					error instanceof Error
						? error.message
						: 'Apple account authorization could not be revoked.'
			},
			{ status: 502 }
		);
	}

	const shares = await env.DB.prepare('SELECT token FROM share_links WHERE owner_email = ?')
		.bind(email)
		.all();
	const statements = [];
	for (const share of shares.results ?? []) {
		statements.push(
			env.DB.prepare('DELETE FROM share_texts WHERE share_token = ?').bind(share.token)
		);
	}
	statements.push(
		env.DB
			.prepare('DELETE FROM feedback_upvotes WHERE feedback_item_id IN (SELECT id FROM feedback_items WHERE user_email = ?)')
			.bind(email),
		env.DB.prepare('DELETE FROM feedback_upvotes WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM feedback_items WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM share_links WHERE owner_email = ?').bind(email),
		env.DB.prepare('DELETE FROM service_access WHERE user_email = ?').bind(email),
		env.DB
			.prepare('UPDATE service_access SET granted_by = \'deleted-account\' WHERE granted_by = ?')
			.bind(email)
	);
	if (account?.account_id) {
		for (const table of [
			'managed_ai_usage',
			'service_usage',
			'service_limit_overrides',
			'service_leases'
		]) {
			statements.push(
				env.DB.prepare('DELETE FROM ' + table + ' WHERE account_id = ?').bind(account.account_id)
			);
		}
	}
	statements.push(
		env.DB
			.prepare(
				'DELETE FROM apple_authorizations WHERE subject IN (SELECT subject FROM auth_identities WHERE provider = \'apple\' AND user_email = ?)'
			)
			.bind(email),
		env.DB.prepare('DELETE FROM auth_identities WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM app_sessions WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM accounts WHERE user_email = ?').bind(email)
	);
	await env.DB.batch(statements);

	return json(
		{
			deleted: true,
			retained: ['content moderation records']
		},
		{ headers: { 'Set-Cookie': sessionCookie('', 0) } }
	);
}

export { deleteAccount };
