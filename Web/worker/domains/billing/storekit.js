import {
	json,
	requireSameOrigin
} from '../../infrastructure/http-security.js';
import { base64URLToBytes, bytesToBase64URL, decodeJWTPart, pemBytes } from '../../infrastructure/crypto.js';
import { accountPayload } from '../auth/account-status.js';
import { accountRecord, ensureAccount } from '../auth/account-operations.js';
import { authenticatedEmail } from '../auth/session.js';

function appStoreConfig(env) {
	const issuerID = String(env.APP_STORE_ISSUER_ID || '').trim();
	const keyID = String(env.APP_STORE_KEY_ID || '').trim();
	const privateKey = String(env.APP_STORE_PRIVATE_KEY || '').replaceAll('\\n', '\n').trim();
	const bundleID = String(env.APPLE_APP_BUNDLE_ID || 'fyi.readbriefly.BrieflyNative').trim();
	const productID = String(env.APP_STORE_PRODUCT_ID || 'fyi.readbriefly.plus.monthly').trim();

	if (
		!/^[0-9a-f-]{36}$/i.test(issuerID) ||
		!/^[A-Z0-9]{10}$/.test(keyID) ||
		!privateKey.includes('BEGIN PRIVATE KEY') ||
		!/^[A-Za-z0-9.-]{3,255}$/.test(bundleID) ||
		!/^[A-Za-z0-9._-]{3,255}$/.test(productID)
	) {
		return null;
	}
	return { issuerID, keyID, privateKey, bundleID, productID };
}

async function appStoreAuthorization(config) {
	const now = Math.floor(Date.now() / 1000);
	const encodedHeader = bytesToBase64URL(
		new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: config.keyID, typ: 'JWT' }))
	);
	const encodedClaims = bytesToBase64URL(
		new TextEncoder().encode(
			JSON.stringify({
				iss: config.issuerID,
				iat: now,
				exp: now + 300,
				aud: 'appstoreconnect-v1',
				bid: config.bundleID
			})
		)
	);
	const key = await crypto.subtle.importKey(
		'pkcs8',
		pemBytes(config.privateKey),
		{ name: 'ECDSA', namedCurve: 'P-256' },
		false,
		['sign']
	);
	const input = encodedHeader + '.' + encodedClaims;
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		key,
		new TextEncoder().encode(input)
	);
	return input + '.' + bytesToBase64URL(new Uint8Array(signature));
}

function decodedJWS(value) {
	const parts = typeof value === 'string' ? value.split('.') : [];
	if (parts.length !== 3) return null;
	try {
		return decodeJWTPart(parts[1]);
	} catch {
		return null;
	}
}

async function appStoreTransaction(env, transactionID) {
	const config = appStoreConfig(env);
	if (!config) throw new Error('App Store billing is not configured.');
	const authorization = await appStoreAuthorization(config);
	for (const base of ['https://api.storekit.apple.com', 'https://api.storekit-sandbox.apple.com']) {
		const response = await fetch(
			base + '/inApps/v1/transactions/' + encodeURIComponent(transactionID),
			{ headers: { Authorization: 'Bearer ' + authorization } }
		);
		if (response.ok) {
			const value = await response.json();
			const transaction = decodedJWS(value?.signedTransactionInfo);
			if (!transaction) throw new Error('The App Store returned an invalid transaction.');
			return { config, transaction };
		}
		if (response.status !== 404) {
			throw new Error('The App Store could not verify the transaction (' + response.status + ').');
		}
	}
	return null;
}

function validAppStoreTransaction(config, transaction) {
	return (
		transaction?.bundleId === config.bundleID &&
		transaction?.productId === config.productID &&
		transaction?.type === 'Auto-Renewable Subscription' &&
		typeof transaction?.transactionId === 'string' &&
		typeof transaction?.originalTransactionId === 'string' &&
		typeof transaction?.appAccountToken === 'string' &&
		Number.isFinite(Number(transaction?.expiresDate)) &&
		Number.isFinite(Number(transaction?.signedDate))
	);
}

async function storeAppStoreTransaction(env, config, transaction) {
	if (!validAppStoreTransaction(config, transaction)) {
		throw new Error('The App Store transaction does not belong to Briefly.');
	}
	const account = await accountRecord(env, transaction.appAccountToken);
	if (!account) throw new Error('The App Store transaction is not linked to a Briefly account.');
	const now = Date.now();
	await env.DB.prepare(
		'INSERT INTO app_store_subscriptions (\n' +
			'original_transaction_id, account_id, transaction_id, product_id,\n' +
			'environment, expires_at, revocation_date, signed_at, created_at, updated_at\n' +
			') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\n' +
			'ON CONFLICT(original_transaction_id) DO UPDATE SET\n' +
			'account_id = excluded.account_id,\n' +
			'transaction_id = excluded.transaction_id,\n' +
			'product_id = excluded.product_id,\n' +
			'environment = excluded.environment,\n' +
			'expires_at = excluded.expires_at,\n' +
			'revocation_date = excluded.revocation_date,\n' +
			'signed_at = excluded.signed_at,\n' +
			'updated_at = excluded.updated_at\n' +
			'WHERE excluded.signed_at >= app_store_subscriptions.signed_at'
	)
		.bind(
			transaction.originalTransactionId,
			transaction.appAccountToken,
			transaction.transactionId,
			transaction.productId,
			transaction.environment || 'Unknown',
			Number(transaction.expiresDate),
			transaction.revocationDate == null ? null : Number(transaction.revocationDate),
			Number(transaction.signedDate),
			now,
			now
		)
		.run();
	return account;
}

async function syncAppStoreTransaction(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid App Store transaction.' }, { status: 400 });
	}
	const transactionID = typeof value?.transactionID === 'string' ? value.transactionID : '';
	if (!/^[0-9]{8,32}$/.test(transactionID)) {
		return json({ error: 'Invalid App Store transaction.' }, { status: 400 });
	}
	try {
		const result = await appStoreTransaction(env, transactionID);
		if (!result) return json({ error: 'App Store transaction not found.' }, { status: 404 });
		const account = await ensureAccount(env, email);
		if (result.transaction.appAccountToken !== account.account_id) {
			return json({ error: 'This purchase belongs to a different Briefly account.' }, { status: 403 });
		}
		await storeAppStoreTransaction(env, result.config, result.transaction);
		return json(await accountPayload(env, email));
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'App Store verification failed.' },
			{ status: 502 }
		);
	}
}

async function appStoreNotification(request, env) {
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid App Store notification.' }, { status: 400 });
	}
	const notification = decodedJWS(value?.signedPayload);
	const transaction = decodedJWS(notification?.data?.signedTransactionInfo);
	const transactionID = transaction?.transactionId;
	if (typeof transactionID !== 'string' || !/^[0-9]{8,32}$/.test(transactionID)) {
		return json({ error: 'Invalid App Store notification.' }, { status: 400 });
	}
	try {
		const result = await appStoreTransaction(env, transactionID);
		if (result) await storeAppStoreTransaction(env, result.config, result.transaction);
		return json({ received: true });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'App Store notification failed.' },
			{ status: 502 }
		);
	}
}

export { appStoreNotification, syncAppStoreTransaction, validAppStoreTransaction };
