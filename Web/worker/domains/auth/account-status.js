import { json } from '../../infrastructure/http-security.js';
import { authenticatedEmail } from './session.js';
import { accountRecord, ensureAccount } from './account-operations.js';
import {
	activeAppStoreSubscription,
	hasComplimentaryPlusAccess,
	isAdministrator
} from './entitlements.js';

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

async function accountStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	return json(email ? await accountPayload(env, email) : { authenticated: false });
}

export { accountPayload, accountRecord, accountStatus, ensureAccount };
