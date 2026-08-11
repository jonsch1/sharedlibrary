import { sha256Hex } from '../../infrastructure/crypto.js';
import {
	json,
	requestJSON,
	sameOriginResponse
} from '../../infrastructure/http-security.js';
import { normalizedEmail } from '../../infrastructure/input-validation.js';
import { ensureAccount } from './account-operations.js';
import { createSession } from './session.js';

function appReviewEmail(env) {
	return normalizedEmail(env.APP_REVIEW_USERNAME);
}

function isAppReviewAccount(env, email) {
	const configuredEmail = appReviewEmail(env);
	return Boolean(configuredEmail) && normalizedEmail(email) === configuredEmail;
}

async function validAppReviewCredentials(env, username, password) {
	const configuredHash = String(env.APP_REVIEW_CREDENTIAL_HASH || '')
		.trim()
		.toLowerCase();
	if (!configuredHash || !/^[0-9a-f]{64}$/.test(configuredHash)) return false;
	if (!isAppReviewAccount(env, username)) return false;
	return (await sha256Hex(`${normalizedEmail(username)}\0${password}`)) === configuredHash;
}

async function signInForAppReview(request, env) {
	const originError = sameOriginResponse(request);
	if (originError) return originError;

	const body = await requestJSON(request);
	const username = normalizedEmail(body?.username);
	const password = typeof body?.password === 'string' ? body.password : '';
	if (
		!username ||
		!password ||
		username.length > 254 ||
		password.length > 256 ||
		!(await validAppReviewCredentials(env, username, password))
	) {
		return json({ error: 'The App Review credentials are invalid.' }, { status: 401 });
	}

	const account = await ensureAccount(env, username);
	const session = await createSession(env, username);
	return json(
		{
			authenticated: true,
			entitled: true,
			reviewAccess: true,
			email: username,
			accountID: account.account_id,
			isAdmin: false,
			subscription: null
		},
		{ headers: { 'Set-Cookie': session.cookie } }
	);
}

export { appReviewEmail, isAppReviewAccount, signInForAppReview };
