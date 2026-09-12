import { json } from '../../infrastructure/http-security.js';
import { authenticatedEmail } from './session.js';
import { accountRecord, ensureAccount } from './account-operations.js';
import { isAdministrator } from './service-access.js';
import { isAppReviewAccount } from './review-access.js';

async function accountPayload(env, email) {
	const account = await ensureAccount(env, email);
	return {
		authenticated: true,
		email,
		accountID: account.account_id,
		isAdmin: isAdministrator(email),
		reviewAccess: isAppReviewAccount(env, email)
	};
}

async function accountStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	return json(email ? await accountPayload(env, email) : { authenticated: false });
}

export { accountPayload, accountRecord, accountStatus, ensureAccount };
