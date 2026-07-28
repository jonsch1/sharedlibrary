import { ttsChargeMicros, ttsModels, ttsTopUpAmounts } from '../tts-pricing.js';

const defaultOpenRouterModel = ttsModels[0].model;
const legacyGrokVoiceModel = ttsModels[2].model;
const orpheusVoiceModel = ttsModels[1].model;
const openRouterModelVoices = new Map(
	ttsModels.map((option) => [option.model, option.voices])
);
const knownVoices = [...new Set([...openRouterModelVoices.values()].flat())];
const oauthStateLifetimeMilliseconds = 10 * 60 * 1000;
const maximumSpeechInputLength = 14_000;
const openRouterVoicePattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const ttsRequestIDPattern =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const stripeAPIBase = 'https://api.stripe.com/v1';
const stripeAPIVersion = '2026-06-24.dahlia';
const stripeWebhookToleranceSeconds = 5 * 60;
const checkoutLifetimeSeconds = 31 * 60;
const checkoutReservationLifetimeMilliseconds = 35 * 60 * 1000;
const stripeWebhookClaimLifetimeMilliseconds = 5 * 60 * 1000;
const maximumActiveShareLinks = 200;
const entitledSubscriptionStatuses = new Set(['active', 'trialing']);
const complimentaryPlusEmails = new Set(['schauljonathan@gmail.com']);
const complimentaryMonthlyTTSMicros = new Map([
	['schauljonathan@gmail.com', 10 * 100_000_000]
]);
const liveSubscriptionStatuses = new Set([
	'active',
	'trialing',
	'past_due',
	'incomplete',
	'paused'
]);
const pricingTiers = [
	{
		key: 'founding',
		name: 'Founding',
		amount: 399,
		capacity: 50,
		priceEnvironmentKey: 'STRIPE_PRICE_FOUNDING'
	},
	{
		key: 'early',
		name: 'Early',
		amount: 599,
		capacity: 100,
		priceEnvironmentKey: 'STRIPE_PRICE_EARLY'
	},
	{
		key: 'growing',
		name: 'Growing',
		amount: 799,
		capacity: 250,
		priceEnvironmentKey: 'STRIPE_PRICE_GROWING'
	},
	{
		key: 'standard',
		name: 'Standard',
		amount: 999,
		capacity: null,
		priceEnvironmentKey: 'STRIPE_PRICE_STANDARD'
	}
];

function stripeCredentials(env) {
	const secretKey = String(env.STRIPE_SECRET_KEY || '').trim();
	const webhookSecret = String(env.STRIPE_WEBHOOK_SECRET || '').trim();
	if (!/^(?:sk|rk)_(?:test|live)_/.test(secretKey) || !webhookSecret.startsWith('whsec_')) {
		return null;
	}
	return { secretKey, webhookSecret };
}

function stripeConfig(env) {
	const credentials = stripeCredentials(env);
	const productID = String(env.STRIPE_PRODUCT_PLUS || '').trim();
	const portalConfigurationID = String(env.STRIPE_PORTAL_CONFIGURATION_ID || '').trim();
	const tiers = pricingTiers.map((tier) => ({
		...tier,
		priceID: String(env[tier.priceEnvironmentKey] || '').trim()
	}));
	if (
		!credentials ||
		!/^prod_/.test(productID) ||
		!/^bpc_/.test(portalConfigurationID) ||
		tiers.some((tier) => !/^price_/.test(tier.priceID))
	) {
		return null;
	}
	return { ...credentials, productID, portalConfigurationID, tiers };
}

function managedTTSKey(env) {
	const apiKey = String(env.OPENROUTER_API_KEY || '').trim();
	return apiKey || null;
}

function ttsStripeConfig(env) {
	const credentials = stripeCredentials(env);
	const productID = String(env.STRIPE_PRODUCT_TTS || '').trim();
	if (!credentials || !/^prod_/.test(productID)) return null;
	return { ...credentials, productID };
}

function tierByKey(key) {
	return pricingTiers.find((tier) => tier.key === key) ?? null;
}

function publicTier(tier, claimed, current) {
	return {
		key: tier.key,
		name: tier.name,
		amount: tier.amount,
		currency: 'eur',
		capacity: tier.capacity,
		claimed,
		remaining: tier.capacity === null ? null : Math.max(0, tier.capacity - claimed),
		current
	};
}

function requestedOpenRouterModel(value, voice) {
	if (value === undefined) {
		if (openRouterModelVoices.get(legacyGrokVoiceModel)?.includes(voice)) {
			return legacyGrokVoiceModel;
		}
		if (openRouterModelVoices.get(orpheusVoiceModel)?.includes(voice)) {
			return orpheusVoiceModel;
		}
		return defaultOpenRouterModel;
	}
	if (typeof value !== 'string') return null;
	const model = value.trim();
	return openRouterModelVoices.has(model) ? model : null;
}

function requestedOpenRouterVoice(value) {
	if (typeof value !== 'string') return null;
	const voice = value.trim();
	return openRouterVoicePattern.test(voice) ? voice : null;
}

function voiceSupportedByModel(model, voice) {
	return openRouterModelVoices.get(model)?.includes(voice) ?? false;
}

function json(value, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Content-Type', 'application/json');
	headers.set('Cache-Control', 'no-store');
	return new Response(JSON.stringify(value), { ...init, headers });
}

const sessionCookieName = 'shared_library_session';
const sessionLifetimeMilliseconds = 90 * 24 * 60 * 60 * 1000;

async function authenticatedEmail(request, env) {
	const cookie = request.headers.get('Cookie') ?? '';
	const rawToken = cookie
		.split(';')
		.map((value) => value.trim())
		.find((value) => value.startsWith(`${sessionCookieName}=`))
		?.slice(sessionCookieName.length + 1);
	if (!rawToken || !env.DB) return null;
	await ensureSchema(env.DB);
	const tokenHash = await sha256Hex(rawToken);
	const session = await env.DB.prepare(
		`SELECT user_email, expires_at FROM app_sessions WHERE token_hash = ?`
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

function sessionCookie(token, maximumAgeSeconds) {
	return [
		`${sessionCookieName}=${token}`,
		'Path=/',
		'HttpOnly',
		'Secure',
		'SameSite=Lax',
		`Max-Age=${maximumAgeSeconds}`
	].join('; ');
}

function googleCloudProjectNumber(clientID) {
	const match = /^(\d+)(?:-|\.apps\.googleusercontent\.com$)/.exec(clientID ?? '');
	return match?.[1] ?? null;
}

function configuredGroupFolderID(env) {
	const value = String(
		env.BRIEFLY_GROUP_FOLDER_ID || env.SHARED_LIBRARY_GROUP_FOLDER_ID || ''
	).trim();
	return /^[A-Za-z0-9_-]{10,256}$/.test(value) ? value : null;
}

function requireSameOrigin(request) {
	const expected = new URL(request.url).origin;
	const origin = request.headers.get('Origin');
	return origin === expected;
}

function randomBase64URL(byteLength = 32) {
	const bytes = new Uint8Array(byteLength);
	crypto.getRandomValues(bytes);
	return bytesToBase64URL(bytes);
}

function bytesToBase64URL(bytes) {
	let binary = '';
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64URLToBytes(value) {
	const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
	const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
	const binary = atob(padded);
	return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function hexToBytes(value) {
	if (!/^[0-9a-f]{64}$/i.test(value)) {
		throw new Error('OPENROUTER_CREDENTIAL_KEY must contain 32 bytes encoded as hexadecimal.');
	}
	return Uint8Array.from(value.match(/.{2}/g), (pair) => Number.parseInt(pair, 16));
}

async function sha256Base64URL(value) {
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
	return bytesToBase64URL(new Uint8Array(digest));
}

async function sha256Hex(value) {
	const input =
		typeof value === 'string'
			? new TextEncoder().encode(value)
			: value instanceof Uint8Array
				? value
				: new Uint8Array(value);
	const digest = new Uint8Array(
		await crypto.subtle.digest('SHA-256', input)
	);
	return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function credentialEncryptionKey(env) {
	if (!env.OPENROUTER_CREDENTIAL_KEY) {
		throw new Error('OpenRouter credential encryption is not configured.');
	}
	return crypto.subtle.importKey(
		'raw',
		hexToBytes(env.OPENROUTER_CREDENTIAL_KEY),
		'AES-GCM',
		false,
		['encrypt', 'decrypt']
	);
}

async function encryptCredential(env, apiKey) {
	const initializationVector = new Uint8Array(12);
	crypto.getRandomValues(initializationVector);
	const ciphertext = await crypto.subtle.encrypt(
		{ name: 'AES-GCM', iv: initializationVector },
		await credentialEncryptionKey(env),
		new TextEncoder().encode(apiKey)
	);
	return {
		encryptedAPIKey: bytesToBase64URL(new Uint8Array(ciphertext)),
		initializationVector: bytesToBase64URL(initializationVector)
	};
}

async function decryptCredential(env, encryptedAPIKey, initializationVector) {
	const plaintext = await crypto.subtle.decrypt(
		{ name: 'AES-GCM', iv: base64URLToBytes(initializationVector) },
		await credentialEncryptionKey(env),
		base64URLToBytes(encryptedAPIKey)
	);
	return new TextDecoder().decode(plaintext);
}

async function ensureSchema(database) {
	await database.batch([
		database
			.prepare(
				`CREATE TABLE IF NOT EXISTS openrouter_credentials (
					user_email TEXT PRIMARY KEY NOT NULL,
					encrypted_api_key TEXT NOT NULL,
					initialization_vector TEXT NOT NULL,
					openrouter_user_id TEXT,
					connected_at TEXT NOT NULL,
					updated_at TEXT NOT NULL
				)`
			),
		database
			.prepare(
				`CREATE TABLE IF NOT EXISTS openrouter_oauth_states (
					state TEXT PRIMARY KEY NOT NULL,
					user_email TEXT NOT NULL,
					code_verifier TEXT NOT NULL,
					created_at INTEGER NOT NULL
				)`
			),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS google_drive_connections (
				user_email TEXT PRIMARY KEY NOT NULL,
				client_id TEXT NOT NULL,
				encrypted_client_secret TEXT NOT NULL,
				client_secret_iv TEXT NOT NULL,
				encrypted_access_token TEXT,
				access_token_iv TEXT,
				encrypted_refresh_token TEXT,
				refresh_token_iv TEXT,
				access_token_expires_at INTEGER,
				folder_id TEXT,
				connected_at TEXT,
				updated_at TEXT NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS google_oauth_states (
				state TEXT PRIMARY KEY NOT NULL,
				user_email TEXT NOT NULL,
				code_verifier TEXT NOT NULL,
				created_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS google_login_states (
				state TEXT PRIMARY KEY NOT NULL,
				code_verifier TEXT NOT NULL,
				return_to TEXT NOT NULL,
				created_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS apple_login_states (
				state TEXT PRIMARY KEY NOT NULL,
				nonce TEXT NOT NULL,
				return_to TEXT NOT NULL,
				created_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS auth_identities (
				provider TEXT NOT NULL,
				subject TEXT NOT NULL,
				user_email TEXT NOT NULL,
				created_at INTEGER NOT NULL,
				PRIMARY KEY (provider, subject)
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS app_sessions (
				token_hash TEXT PRIMARY KEY NOT NULL,
				user_email TEXT NOT NULL,
				created_at INTEGER NOT NULL,
				expires_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE INDEX IF NOT EXISTS app_sessions_user_email_idx
			 ON app_sessions (user_email)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS sync_preferences (
				user_email TEXT PRIMARY KEY NOT NULL,
				provider TEXT NOT NULL,
				updated_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS billing_customers (
				user_email TEXT PRIMARY KEY NOT NULL,
				account_id TEXT NOT NULL,
				stripe_customer_id TEXT,
				created_at INTEGER NOT NULL,
				updated_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE UNIQUE INDEX IF NOT EXISTS billing_customers_account_id_unique
			 ON billing_customers (account_id)`
		),
		database.prepare(
			`CREATE UNIQUE INDEX IF NOT EXISTS billing_customers_stripe_customer_id_unique
			 ON billing_customers (stripe_customer_id)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS billing_subscriptions (
				account_id TEXT PRIMARY KEY NOT NULL,
				stripe_subscription_id TEXT NOT NULL,
				stripe_customer_id TEXT NOT NULL,
				stripe_price_id TEXT,
				tier_key TEXT NOT NULL,
				status TEXT NOT NULL,
				status_changed_at INTEGER NOT NULL DEFAULT 0,
				stripe_created_at INTEGER NOT NULL DEFAULT 0,
				current_period_end INTEGER,
				cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
				created_at INTEGER NOT NULL,
				updated_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE UNIQUE INDEX IF NOT EXISTS billing_subscriptions_stripe_subscription_id_unique
			 ON billing_subscriptions (stripe_subscription_id)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS billing_checkout_reservations (
				reservation_id TEXT PRIMARY KEY NOT NULL,
				account_id TEXT NOT NULL,
				tier_key TEXT NOT NULL,
				stripe_session_id TEXT,
				expires_at INTEGER NOT NULL,
				created_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE UNIQUE INDEX IF NOT EXISTS billing_checkout_reservations_account_id_unique
			 ON billing_checkout_reservations (account_id)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS billing_allocations (
				reservation_id TEXT PRIMARY KEY NOT NULL,
				account_id TEXT NOT NULL,
				tier_key TEXT NOT NULL,
				allocated_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE INDEX IF NOT EXISTS billing_allocations_tier_key_idx
			 ON billing_allocations (tier_key)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS stripe_webhook_events (
				event_id TEXT PRIMARY KEY NOT NULL,
				event_type TEXT NOT NULL,
				status TEXT NOT NULL DEFAULT 'processed',
				attempts INTEGER NOT NULL DEFAULT 1,
				processed_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS tts_accounts (
				account_id TEXT PRIMARY KEY NOT NULL,
				balance_micros INTEGER NOT NULL DEFAULT 0,
				created_at INTEGER NOT NULL,
				updated_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS tts_welcome_credits (
				account_id TEXT PRIMARY KEY NOT NULL,
				stripe_checkout_session_id TEXT NOT NULL UNIQUE,
				amount_micros INTEGER NOT NULL,
				created_at INTEGER NOT NULL,
				credited_at INTEGER
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS tts_monthly_credits (
				account_id TEXT NOT NULL,
				credit_month TEXT NOT NULL,
				amount_micros INTEGER NOT NULL,
				created_at INTEGER NOT NULL,
				credited_at INTEGER,
				PRIMARY KEY (account_id, credit_month)
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS tts_topups (
				checkout_session_id TEXT PRIMARY KEY NOT NULL,
				account_id TEXT NOT NULL,
				stripe_payment_intent_id TEXT NOT NULL,
				amount_micros INTEGER NOT NULL,
				refunded_micros INTEGER NOT NULL DEFAULT 0,
				refund_status TEXT NOT NULL DEFAULT 'disabled',
				created_at INTEGER NOT NULL,
				credited_at INTEGER,
				refunded_at INTEGER
			)`
		),
		database.prepare(
			`CREATE UNIQUE INDEX IF NOT EXISTS tts_topups_stripe_payment_intent_id_unique
			 ON tts_topups (stripe_payment_intent_id)`
		),
		database.prepare(
			`CREATE INDEX IF NOT EXISTS tts_topups_account_created_idx
			 ON tts_topups (account_id, created_at)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS tts_usage (
				request_id TEXT PRIMARY KEY NOT NULL,
				account_id TEXT NOT NULL,
				model TEXT NOT NULL,
				voice TEXT NOT NULL,
				character_count INTEGER NOT NULL,
				amount_micros INTEGER NOT NULL,
				status TEXT NOT NULL,
				generation_id TEXT,
				created_at INTEGER NOT NULL,
				updated_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE INDEX IF NOT EXISTS tts_usage_account_created_idx
			 ON tts_usage (account_id, created_at)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS share_links (
				token TEXT PRIMARY KEY NOT NULL,
				owner_email TEXT NOT NULL,
				capture_id TEXT NOT NULL,
				generation TEXT NOT NULL,
				revision INTEGER NOT NULL DEFAULT 1,
				status TEXT NOT NULL,
				metadata_json TEXT,
				source_filename TEXT,
				voice TEXT NOT NULL,
				error_message TEXT,
				created_at TEXT NOT NULL,
				updated_at TEXT NOT NULL
			)`
		),
		database.prepare(
			`CREATE UNIQUE INDEX IF NOT EXISTS share_links_owner_capture_unique
			 ON share_links (owner_email, capture_id)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS share_texts (
				share_token TEXT NOT NULL,
				generation TEXT NOT NULL,
				variant TEXT NOT NULL,
				markdown TEXT NOT NULL,
				word_count INTEGER NOT NULL,
				PRIMARY KEY (share_token, generation, variant)
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS share_audio_segments (
				share_token TEXT NOT NULL,
				generation TEXT NOT NULL,
				variant TEXT NOT NULL,
				segment_index INTEGER NOT NULL,
				audio_hash TEXT NOT NULL,
				r2_key TEXT NOT NULL,
				content_type TEXT NOT NULL,
				byte_count INTEGER NOT NULL,
				voice TEXT NOT NULL,
				PRIMARY KEY (share_token, generation, variant, segment_index)
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS feedback_items (
				id TEXT PRIMARY KEY NOT NULL,
				user_email TEXT NOT NULL,
				title TEXT NOT NULL,
				details TEXT NOT NULL,
				created_at INTEGER NOT NULL
			)`
		),
		database.prepare(
			`CREATE TABLE IF NOT EXISTS feedback_upvotes (
				feedback_item_id TEXT NOT NULL,
				user_email TEXT NOT NULL,
				created_at INTEGER NOT NULL,
				PRIMARY KEY (feedback_item_id, user_email),
				FOREIGN KEY (feedback_item_id) REFERENCES feedback_items(id) ON DELETE CASCADE
			)`
		),
		database.prepare(
			`CREATE INDEX IF NOT EXISTS feedback_upvotes_item_idx
			 ON feedback_upvotes (feedback_item_id)`
		)
	]);
}

async function openRouterError(response, fallback) {
	const body = await response.text();
	try {
		const value = JSON.parse(body);
		if (typeof value.error === 'string') return value.error;
		if (typeof value.error?.message === 'string') return value.error.message;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The upstream response was not JSON.
	}
	if (body.trim()) return body.trim().slice(0, 500);
	return fallback;
}

async function connectionStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ connected: false }, { status: 401 });
	await ensureSchema(env.DB);
	const credential = await env.DB.prepare(
		`SELECT openrouter_user_id, connected_at
		 FROM openrouter_credentials
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	return json({
		connected: Boolean(credential),
		userID: credential?.openrouter_user_id ?? undefined,
		connectedAt: credential?.connected_at ?? undefined
	});
}

async function startConnection(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	const state = randomBase64URL();
	const verifier = randomBase64URL(64);
	const challenge = await sha256Base64URL(verifier);
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM openrouter_oauth_states WHERE created_at < ? OR user_email = ?')
			.bind(now - oauthStateLifetimeMilliseconds, email),
		env.DB
			.prepare(
				`INSERT INTO openrouter_oauth_states (state, user_email, code_verifier, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(state, email, verifier, now)
	]);

	const callbackURL = new URL('/api/openrouter/connect/callback', request.url);
	callbackURL.searchParams.set('state', state);
	const authorizationURL = new URL('https://openrouter.ai/auth');
	authorizationURL.searchParams.set('callback_url', callbackURL.toString());
	authorizationURL.searchParams.set('code_challenge', challenge);
	authorizationURL.searchParams.set('code_challenge_method', 'S256');
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishConnection(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);

	const url = new URL(request.url);
	const state = url.searchParams.get('state');
	const code = url.searchParams.get('code');
	if (!state || !code) return redirectWithOAuthResult(request, 'error');

	const pending = await env.DB.prepare(
		`SELECT user_email, code_verifier, created_at
		 FROM openrouter_oauth_states
		 WHERE state = ?`
	)
		.bind(state)
		.first();
	if (
		!pending ||
		pending.user_email !== email ||
		Date.now() - pending.created_at > oauthStateLifetimeMilliseconds
	) {
		return redirectWithOAuthResult(request, 'expired');
	}

	await env.DB.prepare('DELETE FROM openrouter_oauth_states WHERE state = ?').bind(state).run();
	const response = await fetch('https://openrouter.ai/api/v1/auth/keys', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			code,
			code_verifier: pending.code_verifier,
			code_challenge_method: 'S256'
		})
	});
	if (!response.ok) return redirectWithOAuthResult(request, 'error');

	const value = await response.json();
	if (typeof value.key !== 'string' || !value.key) {
		return redirectWithOAuthResult(request, 'error');
	}

	const encrypted = await encryptCredential(env, value.key);
	const timestamp = new Date().toISOString();
	await env.DB.prepare(
		`INSERT INTO openrouter_credentials (
			user_email,
			encrypted_api_key,
			initialization_vector,
			openrouter_user_id,
			connected_at,
			updated_at
		) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_email) DO UPDATE SET
			encrypted_api_key = excluded.encrypted_api_key,
			initialization_vector = excluded.initialization_vector,
			openrouter_user_id = excluded.openrouter_user_id,
			connected_at = excluded.connected_at,
			updated_at = excluded.updated_at`
	)
		.bind(
			email,
			encrypted.encryptedAPIKey,
			encrypted.initializationVector,
			typeof value.user_id === 'string' ? value.user_id : null,
			timestamp,
			timestamp
		)
		.run();
	return redirectWithOAuthResult(request, 'connected');
}

function redirectWithOAuthResult(request, result) {
	const destination = new URL('/', request.url);
	destination.searchParams.set('openrouter', result);
	return Response.redirect(destination.toString(), 302);
}

async function disconnect(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.prepare('DELETE FROM openrouter_credentials WHERE user_email = ?').bind(email).run();
	return json({ connected: false });
}

async function reserveTTSUsage(env, accountID, requestID, model, voice, characterCount, amountMicros) {
	const now = Date.now();
	const inserted = await env.DB.prepare(
		`INSERT OR IGNORE INTO tts_usage (
			request_id, account_id, model, voice, character_count, amount_micros,
			status, generation_id, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, 'pending', NULL, ?, ?)`
	)
		.bind(
			requestID,
			accountID,
			model,
			voice,
			characterCount,
			amountMicros,
			now,
			now
		)
		.run();
	if (databaseChanges(inserted) === 0) return { duplicate: true, balanceMicros: null };

	await env.DB.prepare(
		`INSERT OR IGNORE INTO tts_accounts (account_id, balance_micros, created_at, updated_at)
		 VALUES (?, 0, ?, ?)`
	)
		.bind(accountID, now, now)
		.run();
	const reserved = await env.DB.prepare(
		`UPDATE tts_accounts
		 SET balance_micros = balance_micros - ?, updated_at = ?
		 WHERE account_id = ? AND balance_micros >= ?`
	)
		.bind(amountMicros, now, accountID, amountMicros)
		.run();
	if (databaseChanges(reserved) === 0) {
		await env.DB.prepare(
			`UPDATE tts_usage SET status = 'declined', updated_at = ?
			 WHERE request_id = ? AND status = 'pending'`
		)
			.bind(now, requestID)
			.run();
		return { duplicate: false, balanceMicros: null };
	}
	await env.DB.prepare(
		`UPDATE tts_usage SET status = 'reserved', updated_at = ?
		 WHERE request_id = ? AND status = 'pending'`
	)
		.bind(now, requestID)
		.run();
	const account = await env.DB.prepare(
		'SELECT balance_micros FROM tts_accounts WHERE account_id = ?'
	)
		.bind(accountID)
		.first();
	return { duplicate: false, balanceMicros: Number(account?.balance_micros ?? 0) };
}

async function releaseTTSUsage(env, accountID, requestID, amountMicros) {
	const now = Date.now();
	await env.DB.batch([
		env.DB.prepare(
			`UPDATE tts_accounts
			 SET balance_micros = balance_micros + ?, updated_at = ?
			 WHERE account_id = ? AND EXISTS (
				SELECT 1 FROM tts_usage
				WHERE request_id = ? AND account_id = ? AND status = 'reserved'
			 )`
		).bind(amountMicros, now, accountID, requestID, accountID),
		env.DB.prepare(
			`UPDATE tts_usage SET status = 'released', updated_at = ?
			 WHERE request_id = ? AND account_id = ? AND status IN ('pending', 'reserved')`
		).bind(now, requestID, accountID)
	]);
}

async function settleTTSUsage(env, accountID, requestID, generationID) {
	await env.DB.prepare(
		`UPDATE tts_usage
		 SET status = 'settled', generation_id = ?, updated_at = ?
		 WHERE request_id = ? AND account_id = ? AND status = 'reserved'`
	)
		.bind(generationID || null, Date.now(), requestID, accountID)
		.run();
}

async function createSpeech(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const apiKey = managedTTSKey(env);
	if (!apiKey) {
		return json({ error: 'Briefly AI voice is not available yet.' }, { status: 503 });
	}
	await ensureSchema(env.DB);

	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid speech request.' }, { status: 400 });
	}
	const voice = requestedOpenRouterVoice(value.voice);
	const model = requestedOpenRouterModel(value.model, voice);
	if (
		typeof value.input !== 'string' ||
		!value.input.trim() ||
		value.input.length > maximumSpeechInputLength ||
		!voice ||
		!model ||
		!voiceSupportedByModel(model, voice)
	) {
		return json({ error: 'Invalid speech text, voice, or model.' }, { status: 400 });
	}
	const requestID = request.headers.get('X-Briefly-Request-Id');
	if (!requestID || !ttsRequestIDPattern.test(requestID)) {
		return json({ error: 'Invalid speech request identifier.' }, { status: 400 });
	}
	const characterCount = [...value.input].length;
	const amountMicros = ttsChargeMicros(model, characterCount);
	if (!amountMicros) return json({ error: 'Invalid speech price.' }, { status: 400 });
	const customer = await ensureBillingCustomer(env, email);
	await grantComplimentaryMonthlyTTSCredit(env, email, customer.account_id);
	const reservation = await reserveTTSUsage(
		env,
		customer.account_id,
		requestID,
		model,
		voice,
		characterCount,
		amountMicros
	);
	if (reservation.duplicate) {
		return json({ error: 'This speech request is already being processed.' }, { status: 409 });
	}
	if (reservation.balanceMicros === null) {
		return json(
			{ error: 'Not enough Briefly AI voice credit. Top up in Settings.' },
			{ status: 402 }
		);
	}

	let response;
	try {
		response = await fetch('https://openrouter.ai/api/v1/audio/speech', {
			method: 'POST',
			headers: {
				Authorization: `Bearer ${apiKey}`,
				'Content-Type': 'application/json',
				'X-Title': 'Briefly'
			},
			body: JSON.stringify({
				model,
				input: value.input,
				voice,
				response_format: 'mp3'
			})
		});
	} catch (error) {
		await releaseTTSUsage(env, customer.account_id, requestID, amountMicros);
		throw error;
	}
	if (!response.ok) {
		await releaseTTSUsage(env, customer.account_id, requestID, amountMicros);
		return json(
			{ error: await openRouterError(response, `OpenRouter speech failed (${response.status}).`) },
			{ status: response.status }
		);
	}

	const generationID = response.headers.get('X-Generation-Id');
	await settleTTSUsage(env, customer.account_id, requestID, generationID);
	const headers = new Headers({
		'Content-Type': response.headers.get('Content-Type') || 'audio/mpeg',
		'Cache-Control': 'private, no-store',
		'X-Briefly-TTS-Balance-Micros': String(reservation.balanceMicros)
	});
	if (generationID) headers.set('X-Generation-Id', generationID);
	return new Response(response.body, { status: 200, headers });
}

async function fetchLibrarySnapshot(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set(
		'q',
		"appProperties has { key='sharedLibraryKind' and value='library-index' } and trashed=false"
	);
	listURL.searchParams.set('fields', 'files(id,name,mimeType)');
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) {
		return json(
			{ error: response.status === 401 ? 'Connect Google Drive first.' : 'Google Drive could not be searched.' },
			{ status: response.status }
		);
	}
	const value = await response.json();
	const file = value.files?.[0];
	if (!file) {
		return json(
			{ error: 'Google Drive does not contain the library index yet. Open the Mac app and let it synchronize.' },
			{ status: 404 }
		);
	}
	response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(file.id)}?alt=media`
	);
	if (response.status === 404) {
		return json(
			{ error: 'The Google Drive library could not be found. Open the Mac app and let it upload again.' },
			{ status: 404 }
		);
	}
	if (!response.ok) {
		let value;
		try {
			value = await response.json();
		} catch {
			value = {};
		}
		return json({ error: value.message || 'The Google Drive library could not be downloaded.' }, { status: response.status });
	}
	return new Response(response.body, {
		headers: {
			'Content-Type': 'application/json',
			'Cache-Control': 'private, no-store'
		}
	});
}

function validLibraryPath(path) {
	return (
		typeof path === 'string' &&
		path.length > 0 &&
		path.length <= 1024 &&
		(path === 'topics.md' || path.startsWith('library/') || path.startsWith('podcasts/')) &&
		!path.split('/').some((component) => !component || component === '.' || component === '..')
	);
}

async function fetchLibraryFile(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const url = new URL(request.url);
	const path = url.searchParams.get('path');
	const expectedHash = url.searchParams.get('hash');
	if (!validLibraryPath(path) || !/^[a-f0-9]{64}$/.test(expectedHash || '')) {
		return json({ error: 'Invalid library file request.' }, { status: 400 });
	}

	const pathHash = await sha256Hex(path);
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set(
		'q',
		`appProperties has { key='sharedLibraryKind' and value='workspace' } and appProperties has { key='sharedLibraryPathHash' and value='${pathHash}' } and trashed=false`
	);
	listURL.searchParams.set(
		'fields',
		'files(id,mimeType,appProperties)'
	);
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) {
		return json({ error: 'Google Drive could not be searched.' }, { status: response.status });
	}
	const file = (await response.json()).files?.[0];
	if (!file || file.appProperties?.sharedLibraryContentHash !== expectedHash) {
		return json({ error: 'The requested library file is not available.' }, { status: 404 });
	}
	response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(file.id)}?alt=media`
	);
	if (!response.ok) {
		return json({ error: 'The library file could not be downloaded.' }, { status: response.status });
	}
	return new Response(response.body, {
		headers: {
			'Content-Type': file.mimeType || 'text/markdown; charset=utf-8',
			'Cache-Control': 'private, max-age=86400',
			'X-Content-Hash': expectedHash
		}
	});
}

async function driveItemsByKind(env, email, kind) {
	const items = [];
	let pageToken;
	do {
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set(
			'q',
			`appProperties has { key='sharedLibraryKind' and value='${kind}' } and trashed=false`
		);
		url.searchParams.set(
			'fields',
			'nextPageToken,files(id,name,mimeType,appProperties)'
		);
		url.searchParams.set('pageSize', '1000');
		if (pageToken) url.searchParams.set('pageToken', pageToken);
		const response = await googleDriveRequest(env, email, url);
		if (!response.ok) {
			throw new Error(`Google Drive could not inspect ${kind} files (${response.status}).`);
		}
		const value = await response.json();
		items.push(...(value.files ?? []));
		pageToken = value.nextPageToken;
	} while (pageToken);
	return items;
}

async function syncLibraryMirror(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Sign in before synchronizing.' }, { status: 401 });
	await ensureSchema(env.DB);
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid library synchronization request.' }, { status: 400 });
	}
	if (
		value?.schemaVersion !== 1 ||
		typeof value.index !== 'object' ||
		value.index?.schemaVersion !== 3 ||
		!Array.isArray(value.index.files) ||
		!Array.isArray(value.index.entries) ||
		!Array.isArray(value.files) ||
		value.files.length > 20_000
	) {
		return json({ error: 'Invalid library synchronization payload.' }, { status: 400 });
	}
	const files = [];
	let totalBytes = 0;
	for (const file of value.files) {
		if (
			!validLibraryPath(file?.path) ||
			typeof file?.content !== 'string' ||
			typeof file?.contentHash !== 'string' ||
			!/^[a-f0-9]{64}$/.test(file.contentHash)
		) {
			return json({ error: 'The library contains an invalid file.' }, { status: 400 });
		}
		const bytes = new TextEncoder().encode(file.content);
		totalBytes += bytes.byteLength;
		if (
			bytes.byteLength > 8_000_000 ||
			totalBytes > 32_000_000 ||
			(await sha256Hex(bytes)) !== file.contentHash
		) {
			return json({ error: 'The library synchronization payload is too large or invalid.' }, { status: 413 });
		}
		files.push({ path: file.path, contentHash: file.contentHash, bytes });
	}
	const indexFiles = new Map(
		value.index.files.map((file) => [file?.path, file?.contentHash])
	);
	if (
		indexFiles.size !== files.length ||
		files.some((file) => indexFiles.get(file.path) !== file.contentHash)
	) {
		return json({ error: 'The library index does not match its files.' }, { status: 400 });
	}

	try {
		const rootFolderID = await ensureDriveRootFolder(env, email);
		const [remoteFolders, remoteFiles, remoteIndexes] = await Promise.all([
			driveItemsByKind(env, email, 'folder'),
			driveItemsByKind(env, email, 'workspace'),
			driveItemsByKind(env, email, 'library-index')
		]);
		const folderIDsByHash = new Map(
			remoteFolders.flatMap((file) => {
				const hash = file.appProperties?.sharedLibraryPathHash;
				return /^[a-f0-9]{64}$/.test(hash || '') ? [[hash, file.id]] : [];
			})
		);
		const folders = new Map();
		for (const file of files) {
			const components = file.path.split('/').slice(0, -1);
			let current = '';
			for (const component of components) {
				current = current ? `${current}/${component}` : component;
				const existingID = folderIDsByHash.get(await sha256Hex(current));
				if (existingID) folders.set(current, existingID);
			}
		}
		const remoteByPathHash = new Map(
			remoteFiles.flatMap((file) => {
				const hash = file.appProperties?.sharedLibraryPathHash;
				return /^[a-f0-9]{64}$/.test(hash || '') ? [[hash, file]] : [];
			})
		);
		let uploaded = 0;
		for (const file of files) {
			const pathHash = await sha256Hex(file.path);
			const remote = remoteByPathHash.get(pathHash);
			remoteByPathHash.delete(pathHash);
			if (remote?.appProperties?.sharedLibraryContentHash === file.contentHash) continue;
			await upsertDriveFile(env, email, {
				rootFolderID,
				folders,
				path: file.path,
				bytes: file.bytes,
				existingID: remote?.id ?? null,
				kind: 'workspace'
			});
			uploaded += 1;
		}
		let deleted = 0;
		for (const stale of remoteByPathHash.values()) {
			await trashDriveFile(env, email, stale.id);
			deleted += 1;
		}
		const indexBytes = new TextEncoder().encode(JSON.stringify(value.index, null, 2));
		const indexHash = await sha256Hex(indexBytes);
		const remoteIndex = remoteIndexes[0];
		if (remoteIndex?.appProperties?.sharedLibraryContentHash !== indexHash) {
			await upsertDriveFile(env, email, {
				rootFolderID,
				folders,
				path: '.shared-library/index.json',
				bytes: indexBytes,
				existingID: remoteIndex?.id ?? null,
				kind: 'library-index'
			});
			uploaded += 1;
		}
		return json({
			uploaded,
			deleted,
			changed: uploaded + deleted,
			fileCount: files.length,
			syncedAt: new Date().toISOString()
		});
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'Google Drive synchronization failed.' },
			{ status: 502 }
		);
	}
}

function validGoogleClientID(value) {
	return (
		typeof value === 'string' &&
		value.length >= 20 &&
		value.length <= 256 &&
		value.endsWith('.apps.googleusercontent.com')
	);
}

function googleOAuthConfig(env) {
	const clientID = env.GOOGLE_DRIVE_WEB_CLIENT_ID?.trim();
	const clientSecret = env.GOOGLE_DRIVE_WEB_CLIENT_SECRET?.trim();
	if (!validGoogleClientID(clientID) || typeof clientSecret !== 'string' || clientSecret.length < 8) {
		return null;
	}
	return { clientID, clientSecret };
}

function appleAuthConfig(env) {
	const clientID = String(env.APPLE_CLIENT_ID || '').trim();
	const teamID = String(env.APPLE_TEAM_ID || '').trim();
	const keyID = String(env.APPLE_KEY_ID || '').trim();
	const privateKey = String(env.APPLE_PRIVATE_KEY || '').replaceAll('\\n', '\n').trim();
	if (
		!/^[A-Za-z0-9.-]{3,255}$/.test(clientID) ||
		!/^[A-Z0-9]{10}$/.test(teamID) ||
		!/^[A-Z0-9]{10}$/.test(keyID) ||
		!privateKey.includes('BEGIN PRIVATE KEY')
	) {
		return null;
	}
	return { clientID, teamID, keyID, privateKey };
}

function cloudKitConfig(env) {
	const containerIdentifier = String(env.CLOUDKIT_CONTAINER_ID || '').trim();
	const apiToken = String(env.CLOUDKIT_API_TOKEN || '').trim();
	const environment = env.CLOUDKIT_ENVIRONMENT === 'development' ? 'development' : 'production';
	if (!/^iCloud\.[A-Za-z0-9.-]{3,255}$/.test(containerIdentifier) || apiToken.length < 20) {
		return null;
	}
	return { containerIdentifier, apiToken, environment };
}

function safeReturnTo(value, fallback = '/') {
	return typeof value === 'string' && value.startsWith('/') && !value.startsWith('//')
		? value
		: fallback;
}

async function identityEmail(env, provider, subject, verifiedEmail) {
	const existing = await env.DB.prepare(
		`SELECT user_email FROM auth_identities WHERE provider = ? AND subject = ?`
	)
		.bind(provider, subject)
		.first();
	if (existing?.user_email) return existing.user_email;
	if (!verifiedEmail) return null;
	await env.DB.prepare(
		`INSERT OR IGNORE INTO auth_identities (provider, subject, user_email, created_at)
		 VALUES (?, ?, ?, ?)`
	)
		.bind(provider, subject, verifiedEmail, Date.now())
		.run();
	const identity = await env.DB.prepare(
		`SELECT user_email FROM auth_identities WHERE provider = ? AND subject = ?`
	)
		.bind(provider, subject)
		.first();
	return identity?.user_email ?? null;
}

async function authenticatedRedirect(request, env, email, returnTo, provider) {
	const sessionToken = randomBase64URL(32);
	await env.DB.prepare(
		`INSERT INTO app_sessions (token_hash, user_email, created_at, expires_at)
		 VALUES (?, ?, ?, ?)`
	)
		.bind(
			await sha256Hex(sessionToken),
			email,
			Date.now(),
			Date.now() + sessionLifetimeMilliseconds
		)
		.run();
	const destination = new URL(safeReturnTo(returnTo), request.url);
	destination.searchParams.set(provider, 'signed-in');
	return new Response(null, {
		status: 302,
		headers: {
			Location: destination.toString(),
			'Set-Cookie': sessionCookie(
				sessionToken,
				Math.floor(sessionLifetimeMilliseconds / 1000)
			)
		}
	});
}

async function startGoogleLogin(request, env) {
	await ensureSchema(env.DB);
	const config = googleOAuthConfig(env);
	if (!config) return json({ error: 'Google sign-in is not configured.' }, { status: 503 });
	const state = randomBase64URL();
	const verifier = randomBase64URL(64);
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM google_login_states WHERE created_at < ?')
			.bind(now - oauthStateLifetimeMilliseconds),
		env.DB
			.prepare(
				`INSERT INTO google_login_states (state, code_verifier, return_to, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(
				state,
				verifier,
				safeReturnTo(new URL(request.url).searchParams.get('return_to')),
				now
			)
	]);
	const callbackURL = new URL('/api/auth/google/callback', request.url);
	const authorizationURL = new URL('https://accounts.google.com/o/oauth2/v2/auth');
	authorizationURL.searchParams.set('client_id', config.clientID);
	authorizationURL.searchParams.set('redirect_uri', callbackURL.toString());
	authorizationURL.searchParams.set('response_type', 'code');
	authorizationURL.searchParams.set('scope', 'openid email');
	authorizationURL.searchParams.set('prompt', 'select_account');
	authorizationURL.searchParams.set('state', state);
	authorizationURL.searchParams.set('code_challenge', await sha256Base64URL(verifier));
	authorizationURL.searchParams.set('code_challenge_method', 'S256');
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishGoogleLogin(request, env) {
	await ensureSchema(env.DB);
	const url = new URL(request.url);
	const state = url.searchParams.get('state');
	const code = url.searchParams.get('code');
	if (!state || !code) return redirectWithProviderResult(request, 'google', 'error');
	const pending = await env.DB.prepare(
		`SELECT code_verifier, return_to, created_at FROM google_login_states WHERE state = ?`
	)
		.bind(state)
		.first();
	if (!pending || Date.now() - pending.created_at > oauthStateLifetimeMilliseconds) {
		return redirectWithProviderResult(request, 'google', 'expired');
	}
	await env.DB.prepare('DELETE FROM google_login_states WHERE state = ?').bind(state).run();
	const config = googleOAuthConfig(env);
	if (!config) return redirectWithProviderResult(request, 'google', 'error');
	const callbackURL = new URL('/api/auth/google/callback', request.url);
	const response = await fetch('https://oauth2.googleapis.com/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: config.clientID,
			client_secret: config.clientSecret,
			code,
			code_verifier: pending.code_verifier,
			grant_type: 'authorization_code',
			redirect_uri: callbackURL.toString()
		})
	});
	const value = await response.json();
	if (!response.ok || typeof value.access_token !== 'string') {
		return redirectWithProviderResult(request, 'google', 'error');
	}
	const profileResponse = await fetch('https://openidconnect.googleapis.com/v1/userinfo', {
		headers: { Authorization: `Bearer ${value.access_token}` }
	});
	const profile = await profileResponse.json();
	const verifiedEmail =
		profileResponse.ok &&
		profile.email_verified === true &&
		typeof profile.email === 'string'
			? profile.email.trim().toLowerCase()
			: '';
	const email =
		typeof profile.sub === 'string'
			? await identityEmail(env, 'google', profile.sub, verifiedEmail)
			: null;
	if (!email) return redirectWithProviderResult(request, 'google', 'error');
	return authenticatedRedirect(request, env, email, pending.return_to, 'google');
}

function pemBytes(value) {
	const encoded = value
		.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
	return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
}

async function appleClientSecret(config) {
	const now = Math.floor(Date.now() / 1000);
	const encodedHeader = bytesToBase64URL(
		new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: config.keyID }))
	);
	const encodedClaims = bytesToBase64URL(
		new TextEncoder().encode(
			JSON.stringify({
				iss: config.teamID,
				iat: now,
				exp: now + 300,
				aud: 'https://appleid.apple.com',
				sub: config.clientID
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
	const input = `${encodedHeader}.${encodedClaims}`;
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		key,
		new TextEncoder().encode(input)
	);
	return `${input}.${bytesToBase64URL(new Uint8Array(signature))}`;
}

function decodeJWTPart(value) {
	return JSON.parse(new TextDecoder().decode(base64URLToBytes(value)));
}

async function verifiedAppleIdentity(idToken, config, expectedNonce) {
	const parts = String(idToken || '').split('.');
	if (parts.length !== 3) return null;
	let header;
	let claims;
	try {
		header = decodeJWTPart(parts[0]);
		claims = decodeJWTPart(parts[1]);
	} catch {
		return null;
	}
	if (
		header.alg !== 'RS256' ||
		typeof header.kid !== 'string' ||
		claims.iss !== 'https://appleid.apple.com' ||
		!(claims.aud === config.clientID ||
			(Array.isArray(claims.aud) && claims.aud.includes(config.clientID))) ||
		claims.nonce !== expectedNonce ||
		Number(claims.exp) * 1000 <= Date.now()
	) {
		return null;
	}
	const keysResponse = await fetch('https://appleid.apple.com/auth/keys');
	const keys = keysResponse.ok ? (await keysResponse.json()).keys : [];
	const jwk = Array.isArray(keys) ? keys.find((key) => key?.kid === header.kid) : null;
	if (!jwk) return null;
	const key = await crypto.subtle.importKey(
		'jwk',
		jwk,
		{ name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
		false,
		['verify']
	);
	const valid = await crypto.subtle.verify(
		'RSASSA-PKCS1-v1_5',
		key,
		base64URLToBytes(parts[2]),
		new TextEncoder().encode(`${parts[0]}.${parts[1]}`)
	);
	return valid ? claims : null;
}

async function startAppleLogin(request, env) {
	await ensureSchema(env.DB);
	const config = appleAuthConfig(env);
	if (!config) return json({ error: 'Apple sign-in is not configured.' }, { status: 503 });
	const state = randomBase64URL();
	const nonce = randomBase64URL();
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM apple_login_states WHERE created_at < ?')
			.bind(now - oauthStateLifetimeMilliseconds),
		env.DB
			.prepare(
				`INSERT INTO apple_login_states (state, nonce, return_to, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(
				state,
				nonce,
				safeReturnTo(new URL(request.url).searchParams.get('return_to')),
				now
			)
	]);
	const authorizationURL = new URL('https://appleid.apple.com/auth/authorize');
	authorizationURL.searchParams.set('client_id', config.clientID);
	authorizationURL.searchParams.set(
		'redirect_uri',
		new URL('/api/auth/apple/callback', request.url).toString()
	);
	authorizationURL.searchParams.set('response_type', 'code');
	authorizationURL.searchParams.set('response_mode', 'form_post');
	authorizationURL.searchParams.set('scope', 'name email');
	authorizationURL.searchParams.set('state', state);
	authorizationURL.searchParams.set('nonce', nonce);
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishAppleLogin(request, env) {
	await ensureSchema(env.DB);
	let form;
	try {
		form = await request.formData();
	} catch {
		return redirectWithProviderResult(request, 'apple', 'error');
	}
	const state = form.get('state');
	const code = form.get('code');
	if (typeof state !== 'string' || typeof code !== 'string') {
		return redirectWithProviderResult(request, 'apple', 'error');
	}
	const pending = await env.DB.prepare(
		`SELECT nonce, return_to, created_at FROM apple_login_states WHERE state = ?`
	)
		.bind(state)
		.first();
	if (!pending || Date.now() - pending.created_at > oauthStateLifetimeMilliseconds) {
		return redirectWithProviderResult(request, 'apple', 'expired');
	}
	await env.DB.prepare('DELETE FROM apple_login_states WHERE state = ?').bind(state).run();
	const config = appleAuthConfig(env);
	if (!config) return redirectWithProviderResult(request, 'apple', 'error');
	const response = await fetch('https://appleid.apple.com/auth/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: config.clientID,
			client_secret: await appleClientSecret(config),
			code,
			grant_type: 'authorization_code',
			redirect_uri: new URL('/api/auth/apple/callback', request.url).toString()
		})
	});
	const value = await response.json();
	const claims = response.ok
		? await verifiedAppleIdentity(value.id_token, config, pending.nonce)
		: null;
	const verifiedEmail =
		claims &&
		(claims.email_verified === true || claims.email_verified === 'true') &&
		typeof claims.email === 'string'
			? claims.email.trim().toLowerCase()
			: '';
	const email =
		claims && typeof claims.sub === 'string'
			? await identityEmail(env, 'apple', claims.sub, verifiedEmail)
			: null;
	if (!email) return redirectWithProviderResult(request, 'apple', 'error');
	return authenticatedRedirect(request, env, email, pending.return_to, 'apple');
}

async function storedGoogleOAuthConfig(env, connection) {
	if (!connection?.client_id || !connection.encrypted_client_secret || !connection.client_secret_iv) {
		return null;
	}
	return {
		clientID: connection.client_id,
		clientSecret: await decryptCredential(
			env,
			connection.encrypted_client_secret,
			connection.client_secret_iv
		)
	};
}

async function googleDriveStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ configured: Boolean(googleOAuthConfig(env)), connected: false, authenticated: false },
			{ status: 401 }
		);
	}
	await ensureSchema(env.DB);
	const connection = await env.DB.prepare(
		`SELECT client_id, encrypted_refresh_token, connected_at, folder_id
		 FROM google_drive_connections
		 WHERE user_email = ?`
	)
		.bind(email)
		.first();
	const config = googleOAuthConfig(env) ?? (await storedGoogleOAuthConfig(env, connection));
	return json({
		configured: Boolean(config),
		connected: Boolean(connection?.encrypted_refresh_token),
		authenticated: true,
		email,
		folderID: connection?.folder_id ?? undefined,
		connectedAt: connection?.connected_at ?? undefined,
		callbackURL: new URL('/api/google/connect/callback', request.url).toString()
	});
}

async function startGoogleDriveConnection(request, env) {
	await ensureSchema(env.DB);
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Sign in before connecting Google Drive.' }, { status: 401 });
	const config = googleOAuthConfig(env);
	if (!config) {
		return json(
			{ error: 'Briefly has not been configured with Google Drive OAuth yet.' },
			{ status: 503 }
		);
	}

	const state = randomBase64URL();
	const verifier = randomBase64URL(64);
	const challenge = await sha256Base64URL(verifier);
	const now = Date.now();
	await env.DB.batch([
		env.DB
			.prepare('DELETE FROM google_oauth_states WHERE created_at < ? OR user_email = ?')
			.bind(now - oauthStateLifetimeMilliseconds, email),
		env.DB
			.prepare(
				`INSERT INTO google_oauth_states (state, user_email, code_verifier, created_at)
				 VALUES (?, ?, ?, ?)`
			)
			.bind(state, email, verifier, now)
	]);
	const callbackURL = new URL('/api/google/connect/callback', request.url);
	const authorizationURL = new URL('https://accounts.google.com/o/oauth2/v2/auth');
	authorizationURL.searchParams.set('client_id', config.clientID);
	authorizationURL.searchParams.set('redirect_uri', callbackURL.toString());
	authorizationURL.searchParams.set('response_type', 'code');
	authorizationURL.searchParams.set(
		'scope',
		'https://www.googleapis.com/auth/drive.file'
	);
	authorizationURL.searchParams.set('access_type', 'offline');
	authorizationURL.searchParams.set('prompt', 'consent');
	authorizationURL.searchParams.set('state', state);
	authorizationURL.searchParams.set('code_challenge', challenge);
	authorizationURL.searchParams.set('code_challenge_method', 'S256');
	return Response.redirect(authorizationURL.toString(), 302);
}

async function finishGoogleDriveConnection(request, env) {
	await ensureSchema(env.DB);
	const url = new URL(request.url);
	const state = url.searchParams.get('state');
	const code = url.searchParams.get('code');
	if (!state || !code) {
		return redirectWithProviderResult(request, 'google', 'error', '/account');
	}
	const pending = await env.DB.prepare(
		`SELECT user_email, code_verifier, created_at
		 FROM google_oauth_states WHERE state = ?`
	)
		.bind(state)
		.first();
	if (
		!pending ||
		Date.now() - pending.created_at > oauthStateLifetimeMilliseconds
	) {
		return redirectWithProviderResult(request, 'google', 'expired', '/account');
	}
	const config = googleOAuthConfig(env);
	if (!config) return redirectWithProviderResult(request, 'google', 'error', '/account');
	const callbackURL = new URL('/api/google/connect/callback', request.url);
	const response = await fetch('https://oauth2.googleapis.com/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: config.clientID,
			client_secret: config.clientSecret,
			code,
			code_verifier: pending.code_verifier,
			grant_type: 'authorization_code',
			redirect_uri: callbackURL.toString()
		})
	});
	const value = await response.json();
	if (
		!response.ok ||
		typeof value.access_token !== 'string'
	) {
		return redirectWithProviderResult(request, 'google', 'error', '/account');
	}
	const email = pending.user_email;
	const existing = await googleDriveConnection(env, email);
	const refreshToken =
		typeof value.refresh_token === 'string' && value.refresh_token
			? value.refresh_token
			: existing?.encrypted_refresh_token && existing?.refresh_token_iv
				? await decryptCredential(
						env,
						existing.encrypted_refresh_token,
						existing.refresh_token_iv
					)
				: null;
	if (!refreshToken) {
		return redirectWithProviderResult(request, 'google', 'error', '/account');
	}
	const encryptedAccess = await encryptCredential(env, value.access_token);
	const encryptedRefresh = await encryptCredential(env, refreshToken);
	const encryptedSecret = await encryptCredential(env, config.clientSecret);
	const timestamp = new Date().toISOString();
	await env.DB.batch([
		env.DB.prepare(
			`INSERT INTO google_drive_connections (
				user_email, client_id, encrypted_client_secret, client_secret_iv,
				encrypted_access_token, access_token_iv, encrypted_refresh_token,
				refresh_token_iv, access_token_expires_at, folder_id, connected_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(user_email) DO UPDATE SET
				client_id = excluded.client_id,
				encrypted_client_secret = excluded.encrypted_client_secret,
				client_secret_iv = excluded.client_secret_iv,
				encrypted_access_token = excluded.encrypted_access_token,
				access_token_iv = excluded.access_token_iv,
				encrypted_refresh_token = excluded.encrypted_refresh_token,
				refresh_token_iv = excluded.refresh_token_iv,
				access_token_expires_at = excluded.access_token_expires_at,
				connected_at = excluded.connected_at,
				updated_at = excluded.updated_at`
		).bind(
			email,
			config.clientID,
			encryptedSecret.encryptedAPIKey,
			encryptedSecret.initializationVector,
			encryptedAccess.encryptedAPIKey,
			encryptedAccess.initializationVector,
			encryptedRefresh.encryptedAPIKey,
			encryptedRefresh.initializationVector,
			Date.now() + Number(value.expires_in || 3600) * 1000,
			existing?.folder_id ?? null,
			timestamp,
			timestamp,
		),
		env.DB.prepare('DELETE FROM google_oauth_states WHERE state = ?').bind(state),
		env.DB.prepare(
				`INSERT INTO sync_preferences (user_email, provider, updated_at)
				 VALUES (?, 'google', ?)
				 ON CONFLICT(user_email) DO UPDATE SET
					provider = excluded.provider, updated_at = excluded.updated_at`
		).bind(email, Date.now())
	]);
	try {
		await ensureDriveRootFolder(env, email);
	} catch {
		// The account is still connected; the UI can retry folder setup.
	}
	return redirectWithProviderResult(request, 'google', 'connected', '/account');
}

function redirectWithProviderResult(request, provider, result, path = '/') {
	const destination = new URL(path, request.url);
	destination.searchParams.set(provider, result);
	return Response.redirect(destination.toString(), 302);
}

async function disconnectGoogleDrive(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM google_drive_connections WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM google_oauth_states WHERE user_email = ?').bind(email),
		env.DB.prepare(
			`DELETE FROM sync_preferences WHERE user_email = ? AND provider = 'google'`
		).bind(email)
	]);
	return json({ configured: Boolean(googleOAuthConfig(env)), connected: false });
}

async function setSyncProvider(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid sync provider.' }, { status: 400 });
	}
	if (value?.provider !== 'google' && value?.provider !== 'icloud') {
		return json({ error: 'Choose iCloud or Google Drive.' }, { status: 400 });
	}
	if (value.provider === 'google' && !(await googleDriveConnection(env, email))?.encrypted_refresh_token) {
		return json({ error: 'Connect Google Drive first.' }, { status: 409 });
	}
	if (value.provider === 'icloud' && !cloudKitConfig(env)) {
		return json({ error: 'iCloud sync is not configured.' }, { status: 503 });
	}
	await ensureSchema(env.DB);
	await env.DB.prepare(
			`INSERT INTO sync_preferences (user_email, provider, updated_at)
			 VALUES (?, ?, ?)
			 ON CONFLICT(user_email) DO UPDATE SET
				provider = excluded.provider, updated_at = excluded.updated_at`
	)
		.bind(email, value.provider, Date.now())
		.run();
	return json({ provider: value.provider });
}

async function disconnectICloud(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.prepare(
		`DELETE FROM sync_preferences WHERE user_email = ? AND provider = 'icloud'`
	)
		.bind(email)
		.run();
	return json({ configured: Boolean(cloudKitConfig(env)), connected: false });
}

async function iCloudConfiguration(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const config = cloudKitConfig(env);
	if (!config) return json({ error: 'iCloud sync is not configured.' }, { status: 503 });
	return json(config);
}

async function accountStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	const providers = {
		google: Boolean(googleOAuthConfig(env)),
		apple: Boolean(appleAuthConfig(env))
	};
	if (!email) return json({ authenticated: false, providers });
	const [google, preference] = await Promise.all([
		googleDriveConnection(env, email),
		env.DB.prepare(`SELECT provider FROM sync_preferences WHERE user_email = ?`)
			.bind(email)
			.first()
	]);
	const syncProvider =
		preference?.provider === 'google' || preference?.provider === 'icloud'
			? preference.provider
			: google?.encrypted_refresh_token
				? 'google'
				: null;
	return json({
		authenticated: true,
		email,
		providers,
		syncProvider,
		google: {
			configured: Boolean(googleOAuthConfig(env)),
			connected: Boolean(google?.encrypted_refresh_token),
			selected: syncProvider === 'google',
			folderID: google?.folder_id ?? undefined
		},
		icloud: {
			configured: Boolean(cloudKitConfig(env)),
			connected: syncProvider === 'icloud',
			selected: syncProvider === 'icloud'
		}
	});
}

async function feedbackBoard(request, env) {
	const email = await authenticatedEmail(request, env);
	await ensureSchema(env.DB);
	const result = await env.DB.prepare(
		`SELECT
			item.id,
			item.title,
			item.details,
			item.created_at,
			COUNT(upvote.user_email) AS upvotes,
			MAX(CASE WHEN upvote.user_email = ? THEN 1 ELSE 0 END) AS upvoted
		 FROM feedback_items item
		 LEFT JOIN feedback_upvotes upvote ON upvote.feedback_item_id = item.id
		 GROUP BY item.id
		 ORDER BY upvotes DESC, item.created_at DESC
		 LIMIT 200`
	)
		.bind(email ?? '')
		.all();
	return json({
		authenticated: Boolean(email),
		items: (result.results ?? []).map((item) => ({
			id: item.id,
			title: item.title,
			details: item.details,
			createdAt: Number(item.created_at),
			upvotes: Number(item.upvotes),
			upvoted: Boolean(item.upvoted)
		}))
	});
}

async function createFeedback(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid feedback request.' }, { status: 400 });
	}
	const title = typeof value?.title === 'string' ? value.title.trim() : '';
	const details = typeof value?.details === 'string' ? value.details.trim() : '';
	if (title.length < 3 || title.length > 120 || details.length > 2_000) {
		return json(
			{ error: 'Use a title between 3 and 120 characters and details under 2,000 characters.' },
			{ status: 400 }
		);
	}
	const item = {
		id: crypto.randomUUID(),
		title,
		details,
		createdAt: Date.now(),
		upvotes: 1,
		upvoted: true
	};
	await env.DB.batch([
		env.DB.prepare(
			`INSERT INTO feedback_items (id, user_email, title, details, created_at)
			 VALUES (?, ?, ?, ?, ?)`
		).bind(item.id, email, title, details, item.createdAt),
		env.DB.prepare(
			`INSERT INTO feedback_upvotes (feedback_item_id, user_email, created_at)
			 VALUES (?, ?, ?)`
		).bind(item.id, email, item.createdAt)
	]);
	return json(item, { status: 201 });
}

async function setFeedbackUpvote(request, env, itemID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid upvote request.' }, { status: 400 });
	}
	if (typeof value?.upvoted !== 'boolean') {
		return json({ error: 'Invalid upvote request.' }, { status: 400 });
	}
	const statement = value.upvoted
		? env.DB.prepare(
				`INSERT OR IGNORE INTO feedback_upvotes (feedback_item_id, user_email, created_at)
				 SELECT ?, ?, ? FROM feedback_items WHERE id = ?`
			).bind(itemID, email, Date.now(), itemID)
		: env.DB.prepare(
				'DELETE FROM feedback_upvotes WHERE feedback_item_id = ? AND user_email = ?'
			).bind(itemID, email);
	await statement.run();
	const result = await env.DB.prepare(
		`SELECT
			COUNT(*) AS upvotes,
			MAX(CASE WHEN user_email = ? THEN 1 ELSE 0 END) AS upvoted
		 FROM feedback_upvotes
		 WHERE feedback_item_id = ?`
	)
		.bind(email, itemID)
		.first();
	return json({
		id: itemID,
		upvotes: Number(result?.upvotes ?? 0),
		upvoted: Boolean(result?.upvoted)
	});
}

async function signOut(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const cookie = request.headers.get('Cookie') ?? '';
	const rawToken = cookie
		.split(';')
		.map((value) => value.trim())
		.find((value) => value.startsWith(`${sessionCookieName}=`))
		?.slice(sessionCookieName.length + 1);
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

function databaseChanges(result) {
	return Number(result?.meta?.changes ?? result?.changes ?? 0);
}

async function billingCustomer(env, email) {
	return env.DB.prepare(
		`SELECT c.account_id, c.stripe_customer_id,
		        s.stripe_subscription_id, s.stripe_price_id, s.tier_key,
		        s.status, s.status_changed_at, s.stripe_created_at,
		        s.current_period_end, s.cancel_at_period_end
		 FROM billing_customers c
		 LEFT JOIN billing_subscriptions s ON s.account_id = c.account_id
		 WHERE c.user_email = ?`
	)
		.bind(email)
		.first();
}

async function ensureBillingCustomer(env, email) {
	const existing = await billingCustomer(env, email);
	if (existing) return existing;
	const now = Date.now();
	await env.DB.prepare(
		`INSERT OR IGNORE INTO billing_customers (
			user_email, account_id, stripe_customer_id, created_at, updated_at
		) VALUES (?, ?, NULL, ?, ?)`
	)
		.bind(email, crypto.randomUUID(), now, now)
		.run();
	return billingCustomer(env, email);
}

async function tierClaimCount(database, tierKey, now = Date.now()) {
	const row = await database
		.prepare(
			`SELECT
				(SELECT COUNT(*) FROM billing_allocations WHERE tier_key = ?) +
				(SELECT COUNT(*) FROM billing_checkout_reservations
				 WHERE tier_key = ? AND expires_at > ?) AS claimed`
		)
		.bind(tierKey, tierKey, now)
		.first();
	return Number(row?.claimed ?? 0);
}

async function pricingAvailability(env) {
	const now = Date.now();
	if (!env.DB) {
		return pricingTiers.map((tier, index) => publicTier(tier, 0, index === 0));
	}
	await ensureSchema(env.DB);
	await env.DB.prepare('DELETE FROM billing_checkout_reservations WHERE expires_at <= ?')
		.bind(now)
		.run();
	const claims = [];
	for (const tier of pricingTiers) {
		claims.push(await tierClaimCount(env.DB, tier.key, now));
	}
	const currentIndex = pricingTiers.findIndex(
		(tier, index) => tier.capacity === null || claims[index] < tier.capacity
	);
	return pricingTiers.map((tier, index) =>
		publicTier(tier, claims[index], index === currentIndex)
	);
}

function configuredTierForRecord(record, config) {
	if (!record?.stripe_price_id || !config) return null;
	return config.tiers.find((tier) => tier.priceID === record.stripe_price_id) ?? null;
}

function hasComplimentaryPlusAccess(email) {
	return complimentaryPlusEmails.has(String(email || '').trim().toLowerCase());
}

function complimentaryMonthlyTTSAmountMicros(email) {
	return complimentaryMonthlyTTSMicros.get(String(email || '').trim().toLowerCase()) ?? 0;
}

async function grantComplimentaryMonthlyTTSCredit(env, email, accountID, now = Date.now()) {
	const amountMicros = complimentaryMonthlyTTSAmountMicros(email);
	if (!amountMicros) return;
	const creditMonth = new Date(now).toISOString().slice(0, 7);
	await env.DB.batch([
		env.DB.prepare(
			`INSERT OR IGNORE INTO tts_accounts (
				account_id, balance_micros, created_at, updated_at
			) VALUES (?, 0, ?, ?)`
		).bind(accountID, now, now),
		env.DB.prepare(
			`INSERT OR IGNORE INTO tts_monthly_credits (
				account_id, credit_month, amount_micros, created_at, credited_at
			) VALUES (?, ?, ?, ?, NULL)`
		).bind(accountID, creditMonth, amountMicros, now),
		env.DB.prepare(
			`UPDATE tts_accounts
			 SET balance_micros = balance_micros + ?, updated_at = ?
			 WHERE account_id = ? AND EXISTS (
				SELECT 1 FROM tts_monthly_credits
				WHERE account_id = ? AND credit_month = ? AND credited_at IS NULL
			 )`
		).bind(amountMicros, now, accountID, accountID, creditMonth),
		env.DB.prepare(
			`UPDATE tts_monthly_credits SET credited_at = ?
			 WHERE account_id = ? AND credit_month = ? AND credited_at IS NULL`
		).bind(now, accountID, creditMonth)
	]);
}

async function grantAllComplimentaryMonthlyTTSCredits(env) {
	await ensureSchema(env.DB);
	for (const email of complimentaryMonthlyTTSMicros.keys()) {
		const customer = await ensureBillingCustomer(env, email);
		await grantComplimentaryMonthlyTTSCredit(env, email, customer.account_id);
	}
}

function pastDueGraceMilliseconds(env) {
	const requestedDays = Number(env.STRIPE_PAST_DUE_GRACE_DAYS ?? 7);
	const days = Number.isFinite(requestedDays)
		? Math.max(0, Math.min(30, requestedDays))
		: 7;
	return days * 24 * 60 * 60 * 1000;
}

function subscriptionIsEntitled(record, config, env, now = Date.now()) {
	if (!configuredTierForRecord(record, config)) return false;
	if (entitledSubscriptionStatuses.has(record?.status)) return true;
	if (record?.status !== 'past_due') return false;
	const changedAt = Number(record.status_changed_at);
	return (
		Number.isFinite(changedAt) &&
		changedAt > 0 &&
		now - changedAt <= pastDueGraceMilliseconds(env)
	);
}

function publicSubscription(record, config) {
	if (!record?.stripe_subscription_id) return null;
	const tier = configuredTierForRecord(record, config);
	return {
		status: record.status,
		tierKey: tier?.key ?? 'unrecognized',
		tierName: tier?.name ?? 'Unrecognized',
		amount: tier?.amount ?? 0,
		currency: 'eur',
		recognized: Boolean(tier),
		cancelAtPeriodEnd: Boolean(record.cancel_at_period_end),
		currentPeriodEnd: record.current_period_end ?? null
	};
}

async function billingStatus(request, env) {
	const config = stripeConfig(env);
	const email = await authenticatedEmail(request, env);
	let record = null;
	if (email && env.DB) {
		await ensureSchema(env.DB);
		record = await billingCustomer(env, email);
	}
	const subscription = publicSubscription(record, config);
	const complimentary = hasComplimentaryPlusAccess(email);
	return json({
		configured: Boolean(config),
		authenticated: Boolean(email),
		entitled: complimentary || subscriptionIsEntitled(record, config, env),
		complimentary,
		subscription,
		tiers: await pricingAvailability(env)
	});
}

function publicTTSPrices() {
	return ttsModels.map((option) => ({
		model: option.model,
		retailCentsPerMillionCharacters: option.retailCentsPerMillionCharacters
	}));
}

async function ttsStatus(request, env) {
	const configured = Boolean(managedTTSKey(env));
	const checkoutConfigured = configured && Boolean(ttsStripeConfig(env));
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json({
			configured,
			checkoutConfigured,
			authenticated: false,
			balanceMicros: 0,
			topUpAmounts: ttsTopUpAmounts,
			prices: publicTTSPrices(),
			usage: []
		});
	}
	await ensureSchema(env.DB);
	let customer = await billingCustomer(env, email);
	if (complimentaryMonthlyTTSAmountMicros(email)) {
		customer ??= await ensureBillingCustomer(env, email);
		await grantComplimentaryMonthlyTTSCredit(env, email, customer.account_id);
	}
	if (!customer) {
		return json({
			configured,
			checkoutConfigured,
			authenticated: true,
			balanceMicros: 0,
			topUpAmounts: ttsTopUpAmounts,
			prices: publicTTSPrices(),
			usage: []
		});
	}
	const [account, usageResult] = await Promise.all([
		env.DB.prepare('SELECT balance_micros FROM tts_accounts WHERE account_id = ?')
			.bind(customer.account_id)
			.first(),
		env.DB.prepare(
			`SELECT model, character_count, amount_micros, generation_id, updated_at
			 FROM tts_usage
			 WHERE account_id = ? AND status = 'settled'
			 ORDER BY updated_at DESC
			 LIMIT 10`
		)
			.bind(customer.account_id)
			.all()
	]);
	const balanceMicros = Math.max(0, Number(account?.balance_micros ?? 0));
	return json({
		configured,
		checkoutConfigured,
		authenticated: true,
		balanceMicros,
		topUpAmounts: ttsTopUpAmounts,
		prices: publicTTSPrices(),
		usage: (usageResult.results ?? []).map((entry) => ({
			model: entry.model,
			characterCount: Number(entry.character_count),
			amountMicros: Number(entry.amount_micros),
			generationID: entry.generation_id ?? null,
			createdAt: Number(entry.updated_at)
		}))
	});
}

async function validateTTSProduct(env, productID) {
	const product = await stripeRetrieve(env, `/products/${encodeURIComponent(productID)}`);
	if (product.active === false) throw new Error('The configured AI voice product is inactive.');
}

async function createTTSCheckoutSession(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const config = ttsStripeConfig(env);
	if (!managedTTSKey(env) || !config) {
		return json({ error: 'Briefly AI voice top-ups are not configured yet.' }, { status: 503 });
	}
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Sign in to top up.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid top-up request.' }, { status: 400 });
	}
	const amountCents = Number(value.amountCents);
	const checkoutID = typeof value.checkoutID === 'string' ? value.checkoutID : '';
	if (!ttsTopUpAmounts.includes(amountCents) || !ttsRequestIDPattern.test(checkoutID)) {
		return json({ error: 'Invalid top-up amount.' }, { status: 400 });
	}
	await ensureSchema(env.DB);
	const customer = await ensureBillingCustomer(env, email);
	const origin = new URL(request.url).origin;
	const form = {
		mode: 'payment',
		'line_items[0][price_data][currency]': 'eur',
		'line_items[0][price_data][unit_amount]': String(amountCents),
		'line_items[0][price_data][tax_behavior]': 'inclusive',
		'line_items[0][price_data][product]': config.productID,
		'line_items[0][quantity]': '1',
		'automatic_tax[enabled]': 'true',
		'tax_id_collection[enabled]': 'true',
		billing_address_collection: 'required',
		client_reference_id: customer.account_id,
		success_url: `${origin}/account?tts=success`,
		cancel_url: `${origin}/account?tts=cancelled`,
		'metadata[briefly_kind]': 'tts_credit',
		'metadata[briefly_account_id]': customer.account_id,
		'metadata[briefly_credit_cents]': String(amountCents),
		'payment_intent_data[metadata][briefly_kind]': 'tts_credit',
		'payment_intent_data[metadata][briefly_account_id]': customer.account_id
	};
	if (customer.stripe_customer_id) {
		form.customer = customer.stripe_customer_id;
		form['customer_update[address]'] = 'auto';
		form['customer_update[name]'] = 'auto';
	} else {
		form.customer_email = email;
		form.customer_creation = 'always';
	}
	try {
		await validateTTSProduct(env, config.productID);
		const session = await stripeRequest(
			env,
			'/checkout/sessions',
			form,
			`briefly-tts-checkout-v3-${checkoutID}`
		);
		if (typeof session.url !== 'string') throw new Error('Stripe did not return a Checkout URL.');
		return json({ url: session.url });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The top-up checkout could not be opened.' },
			{ status: 502 }
		);
	}
}

async function paidAccessResponse(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ error: 'Sign in before using Briefly Plus.', code: 'authentication_required' },
			{ status: 401 }
		);
	}
	if (hasComplimentaryPlusAccess(email)) return null;
	const config = stripeConfig(env);
	if (!config) {
		return json(
			{
				error: 'Briefly Plus billing is temporarily unavailable.',
				code: 'billing_unavailable'
			},
			{ status: 503 }
		);
	}
	await ensureSchema(env.DB);
	const record = await billingCustomer(env, email);
	if (subscriptionIsEntitled(record, config, env)) return null;
	return json(
		{
			error: 'Briefly Plus is required for synchronization and sharing.',
			code: 'subscription_required'
		},
		{ status: 402 }
	);
}

class StripeRequestError extends Error {
	constructor(message, status, code) {
		super(message);
		this.name = 'StripeRequestError';
		this.status = status;
		this.code = code;
	}
}

function stripeHeaders(config) {
	return {
		Authorization: `Bearer ${config.secretKey}`,
		'Stripe-Version': stripeAPIVersion
	};
}

async function stripeRequest(env, path, form, idempotencyKey) {
	const config = stripeCredentials(env);
	if (!config) throw new Error('Stripe payments are not configured.');
	const headers = {
		...stripeHeaders(config),
		'Content-Type': 'application/x-www-form-urlencoded'
	};
	if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
	const response = await fetch(`${stripeAPIBase}${path}`, {
		method: 'POST',
		headers,
		body: new URLSearchParams(form)
	});
	const value = await response.json().catch(() => ({}));
	if (!response.ok) {
		const message =
			typeof value?.error?.message === 'string'
				? value.error.message
				: `Stripe could not complete the billing request (${response.status}).`;
		throw new StripeRequestError(message, response.status, value?.error?.code);
	}
	return value;
}

async function stripeRetrieve(env, path, query = {}) {
	const config = stripeCredentials(env);
	if (!config) throw new Error('Stripe payments are not configured.');
	const url = new URL(`${stripeAPIBase}${path}`);
	for (const [key, value] of Object.entries(query)) {
		if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
	}
	const response = await fetch(url, { headers: stripeHeaders(config) });
	const value = await response.json().catch(() => ({}));
	if (!response.ok) {
		const message =
			typeof value?.error?.message === 'string'
				? value.error.message
				: `Stripe could not complete the billing request (${response.status}).`;
		throw new StripeRequestError(message, response.status, value?.error?.code);
	}
	return value;
}

async function validateStripeTier(env, tier) {
	const config = stripeConfig(env);
	if (!config) throw new Error('Stripe billing is not configured.');
	const price = await stripeRetrieve(env, `/prices/${encodeURIComponent(tier.priceID)}`);
	const productID = typeof price.product === 'string' ? price.product : price.product?.id;
	if (
		price.active === false ||
		productID !== config.productID ||
		price.currency !== 'eur' ||
		Number(price.unit_amount) !== tier.amount ||
		price.type !== 'recurring' ||
		price.recurring?.interval !== 'month' ||
		Number(price.recurring?.interval_count) !== 1
	) {
		throw new Error(`The configured ${tier.name} Stripe Price does not match Briefly's billing terms.`);
	}
}

async function reservePricingTier(env, accountID) {
	const now = Date.now();
	await env.DB.prepare('DELETE FROM billing_checkout_reservations WHERE expires_at <= ?')
		.bind(now)
		.run();
	const existing = await env.DB.prepare(
		`SELECT reservation_id, account_id, tier_key, stripe_session_id, expires_at, created_at
		 FROM billing_checkout_reservations
		 WHERE account_id = ? AND expires_at > ?`
	)
		.bind(accountID, now)
		.first();
	if (existing) {
		const existingTier = tierByKey(existing.tier_key);
		if (existingTier) {
			return {
				reservationID: existing.reservation_id,
				stripeSessionID: existing.stripe_session_id,
				tier: existingTier,
				expiresAt: Number(existing.expires_at)
			};
		}
	}

	for (const tier of pricingTiers) {
		const reservationID = crypto.randomUUID();
		const expiresAt = now + checkoutReservationLifetimeMilliseconds;
		let statement;
		if (tier.capacity === null) {
			statement = env.DB.prepare(
				`INSERT OR IGNORE INTO billing_checkout_reservations (
					reservation_id, account_id, tier_key, stripe_session_id, expires_at, created_at
				) VALUES (?, ?, ?, NULL, ?, ?)`
			).bind(reservationID, accountID, tier.key, expiresAt, now);
		} else {
			statement = env.DB.prepare(
				`INSERT OR IGNORE INTO billing_checkout_reservations (
					reservation_id, account_id, tier_key, stripe_session_id, expires_at, created_at
				)
				SELECT ?, ?, ?, NULL, ?, ?
				WHERE (
					(SELECT COUNT(*) FROM billing_allocations WHERE tier_key = ?) +
					(SELECT COUNT(*) FROM billing_checkout_reservations
					 WHERE tier_key = ? AND expires_at > ?)
				) < ?`
			).bind(
				reservationID,
				accountID,
				tier.key,
				expiresAt,
				now,
				tier.key,
				tier.key,
				now,
				tier.capacity
			);
		}
		if (databaseChanges(await statement.run()) > 0) {
			return { reservationID, stripeSessionID: null, tier, expiresAt };
		}
	}
	const concurrent = await env.DB.prepare(
		`SELECT reservation_id, tier_key, stripe_session_id, expires_at
		 FROM billing_checkout_reservations
		 WHERE account_id = ? AND expires_at > ?`
	)
		.bind(accountID, now)
		.first();
	const concurrentTier = tierByKey(concurrent?.tier_key);
	if (concurrent && concurrentTier) {
		return {
			reservationID: concurrent.reservation_id,
			stripeSessionID: concurrent.stripe_session_id,
			tier: concurrentTier,
			expiresAt: Number(concurrent.expires_at)
		};
	}
	throw new Error('No Briefly Plus price is currently available.');
}

async function createCheckoutSession(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ error: 'Sign in to continue.', code: 'authentication_required' },
			{ status: 401 }
		);
	}
	if (hasComplimentaryPlusAccess(email)) {
		return json(
			{
				error: 'This account already has complimentary Briefly Plus access.',
				code: 'access_exists'
			},
			{ status: 409 }
		);
	}
	const config = stripeConfig(env);
	if (!config) {
		return json({ error: 'Briefly Plus checkout is not configured yet.' }, { status: 503 });
	}
	await ensureSchema(env.DB);
	const customer = await ensureBillingCustomer(env, email);
	if (liveSubscriptionStatuses.has(customer?.status)) {
		const recognized = Boolean(configuredTierForRecord(customer, config));
		return json(
			{
				error: recognized
					? 'This account already has Briefly Plus.'
					: 'This account has a Stripe subscription that needs support before checkout can continue.',
				code: recognized ? 'subscription_exists' : 'billing_attention_required'
			},
			{ status: 409 }
		);
	}
	let reservation = await reservePricingTier(env, customer.account_id);
	if (reservation.stripeSessionID) {
		try {
			const existingSession = await stripeRetrieve(
				env,
				`/checkout/sessions/${encodeURIComponent(reservation.stripeSessionID)}`
			);
			if (existingSession.status === 'open' && typeof existingSession.url === 'string') {
				return json({
					url: existingSession.url,
					tier: publicTier(reservation.tier, 0, true),
					reused: true
				});
			}
			if (existingSession.status === 'complete') {
				return json(
					{
						error: 'Your completed checkout is still being activated.',
						code: 'activation_pending'
					},
					{ status: 409 }
				);
			}
		} catch (error) {
			if (!(error instanceof StripeRequestError) || error.status !== 404) throw error;
		}
		await env.DB.prepare(
			'DELETE FROM billing_checkout_reservations WHERE reservation_id = ?'
		)
			.bind(reservation.reservationID)
			.run();
		reservation = await reservePricingTier(env, customer.account_id);
	}
	const configuredTier = config.tiers.find((tier) => tier.key === reservation.tier.key);
	const origin = new URL(request.url).origin;
	const form = {
		mode: 'subscription',
		'line_items[0][price]': configuredTier.priceID,
		'line_items[0][quantity]': '1',
		client_reference_id: customer.account_id,
		success_url: `${origin}/account?billing=success`,
		cancel_url: `${origin}/account?billing=cancelled`,
		expires_at: String(Math.floor(Date.now() / 1000) + checkoutLifetimeSeconds),
		'metadata[briefly_reservation_id]': reservation.reservationID,
		'metadata[briefly_tier_key]': reservation.tier.key,
		'subscription_data[metadata][briefly_account_id]': customer.account_id,
		'subscription_data[metadata][briefly_tier_key]': reservation.tier.key
	};
	if (customer.stripe_customer_id) {
		form.customer = customer.stripe_customer_id;
	} else {
		form.customer_email = email;
	}

	try {
		await validateStripeTier(env, configuredTier);
		const session = await stripeRequest(
			env,
			'/checkout/sessions',
			form,
			`briefly-checkout-v3-${reservation.reservationID}`
		);
		if (typeof session.id !== 'string' || typeof session.url !== 'string') {
			throw new Error('Stripe did not return a Checkout URL.');
		}
		await env.DB.prepare(
			`UPDATE billing_checkout_reservations
			 SET stripe_session_id = ?
			 WHERE reservation_id = ?`
		)
			.bind(session.id, reservation.reservationID)
			.run();
		return json({
			url: session.url,
			tier: publicTier(reservation.tier, 0, true)
			});
		} catch (error) {
			return json(
			{
				error:
					error instanceof Error ? error.message : 'Briefly Plus checkout could not be opened.'
			},
			{ status: 502 }
		);
	}
}

async function createBillingPortalSession(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const config = stripeConfig(env);
	if (!config) {
		return json({ error: 'Stripe billing is not configured yet.' }, { status: 503 });
	}
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const customer = await billingCustomer(env, email);
	if (!customer?.stripe_customer_id) {
		return json({ error: 'This account does not have a Stripe customer yet.' }, { status: 404 });
	}
		try {
			const portal = await stripeRequest(env, '/billing_portal/sessions', {
				customer: customer.stripe_customer_id,
				configuration: config.portalConfigurationID,
				return_url: `${new URL(request.url).origin}/`
			});
		if (typeof portal.url !== 'string') throw new Error('Stripe did not return a billing URL.');
		return json({ url: portal.url });
	} catch (error) {
		return json(
			{
				error:
					error instanceof Error ? error.message : 'The billing portal could not be opened.'
			},
			{ status: 502 }
		);
	}
}

function secureHexEqual(left, right) {
	if (left.length !== right.length) return false;
	let difference = 0;
	for (let index = 0; index < left.length; index += 1) {
		difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
	}
	return difference === 0;
}

async function hmacSHA256Hex(secret, value) {
	const key = await crypto.subtle.importKey(
		'raw',
		new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' },
		false,
		['sign']
	);
	const signature = new Uint8Array(
		await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value))
	);
	return [...signature].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function verifyStripeWebhook(rawBody, signatureHeader, secret) {
	const components = String(signatureHeader || '')
		.split(',')
		.map((part) => part.trim());
	const timestamp = components.find((part) => part.startsWith('t='))?.slice(2);
	const signatures = components
		.filter((part) => part.startsWith('v1='))
		.map((part) => part.slice(3));
	if (!/^\d+$/.test(timestamp || '') || signatures.length === 0) return false;
	const age = Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp));
	if (age > stripeWebhookToleranceSeconds) return false;
	const expected = await hmacSHA256Hex(secret, `${timestamp}.${rawBody}`);
	return signatures.some((signature) => secureHexEqual(signature, expected));
}

function subscriptionPeriodEnd(subscription) {
	const periods = Array.isArray(subscription?.items?.data)
		? subscription.items.data
				.map((item) => Number(item?.current_period_end))
				.filter((value) => Number.isFinite(value) && value > 0)
		: [];
	const rootPeriod = Number(subscription?.current_period_end);
	if (Number.isFinite(rootPeriod) && rootPeriod > 0) periods.push(rootPeriod);
	return periods.length > 0 ? Math.max(...periods) : null;
}

async function upsertStripeSubscription(env, subscription) {
	const accountID = subscription?.metadata?.briefly_account_id;
	if (typeof accountID !== 'string' || !accountID) return;
	const customerID =
		typeof subscription.customer === 'string'
			? subscription.customer
			: subscription.customer?.id;
	if (typeof customerID !== 'string' || typeof subscription.id !== 'string') return;
	const priceID = subscription?.items?.data?.[0]?.price?.id ?? null;
	const configuredTier = stripeConfig(env)?.tiers.find((tier) => tier.priceID === priceID);
	const tierKey = configuredTier?.key ?? 'unrecognized';
	const status = String(subscription.status || 'incomplete');
	const now = Date.now();
	const created = Number(subscription.created);
	const stripeCreatedAt =
		Number.isFinite(created) && created > 0 ? Math.floor(created * 1000) : now;
	await env.DB.batch([
		env.DB.prepare(
			`UPDATE billing_customers
			 SET stripe_customer_id = ?, updated_at = ?
			 WHERE account_id = ?`
		).bind(customerID, now, accountID),
		env.DB.prepare(
			`INSERT INTO billing_subscriptions (
				account_id, stripe_subscription_id, stripe_customer_id, stripe_price_id,
				tier_key, status, status_changed_at, stripe_created_at,
				current_period_end, cancel_at_period_end, created_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(account_id) DO UPDATE SET
				stripe_subscription_id = excluded.stripe_subscription_id,
				stripe_customer_id = excluded.stripe_customer_id,
				stripe_price_id = excluded.stripe_price_id,
				tier_key = excluded.tier_key,
				status_changed_at = CASE
					WHEN billing_subscriptions.status = excluded.status
					THEN billing_subscriptions.status_changed_at
					ELSE excluded.status_changed_at
				END,
				status = excluded.status,
				stripe_created_at = excluded.stripe_created_at,
				current_period_end = excluded.current_period_end,
				cancel_at_period_end = excluded.cancel_at_period_end,
				updated_at = excluded.updated_at
			WHERE excluded.stripe_created_at >= billing_subscriptions.stripe_created_at`
		).bind(
			accountID,
			subscription.id,
			customerID,
			priceID,
			tierKey,
			status,
			now,
			stripeCreatedAt,
			subscriptionPeriodEnd(subscription),
			subscription.cancel_at_period_end ? 1 : 0,
			now,
			now
		)
	]);
}

async function latestStripeSubscription(env, subscription) {
	if (typeof subscription?.id !== 'string') return null;
	try {
		return await stripeRetrieve(
			env,
			`/subscriptions/${encodeURIComponent(subscription.id)}`
		);
	} catch (error) {
		if (error instanceof StripeRequestError && error.status === 404) {
			return { ...subscription, status: 'canceled' };
		}
		throw error;
	}
}

async function completeTTSCheckout(env, eventSession) {
	if (
		eventSession?.metadata?.briefly_kind !== 'tts_credit' ||
		typeof eventSession?.id !== 'string'
	) {
		return;
	}
	const session = await stripeRetrieve(
		env,
		`/checkout/sessions/${encodeURIComponent(eventSession.id)}`
	);
	const accountID = session?.metadata?.briefly_account_id;
	const customerID =
		typeof session?.customer === 'string' ? session.customer : session?.customer?.id;
	const paymentIntentID =
		typeof session?.payment_intent === 'string'
			? session.payment_intent
			: session?.payment_intent?.id;
	const amountCents = Number(session?.metadata?.briefly_credit_cents);
	const automaticTax = session?.automatic_tax;
	const taxCents =
		automaticTax?.enabled === false
			? 0
			: automaticTax?.enabled === true && automaticTax?.status === 'complete'
				? session?.total_details?.amount_tax
				: Number.NaN;
	if (
		session?.mode !== 'payment' ||
		session?.metadata?.briefly_kind !== 'tts_credit' ||
		!['paid', 'no_payment_required'].includes(session?.payment_status) ||
		session?.currency !== 'eur' ||
		typeof session?.id !== 'string' ||
		typeof accountID !== 'string' ||
		session?.client_reference_id !== accountID ||
		typeof customerID !== 'string' ||
		typeof paymentIntentID !== 'string' ||
		!ttsTopUpAmounts.includes(amountCents) ||
		session?.amount_total !== amountCents ||
		!Number.isSafeInteger(taxCents) ||
		taxCents < 0 ||
		taxCents >= amountCents
	) {
		return;
	}
	const customer = await env.DB.prepare(
		'SELECT account_id FROM billing_customers WHERE account_id = ?'
	)
		.bind(accountID)
		.first();
	if (!customer) throw new Error('The AI voice checkout did not match a Briefly account.');
	const now = Date.now();
	const created = Number(session.created);
	const createdAt = Number.isFinite(created) && created > 0 ? Math.floor(created * 1000) : now;
	const amountMicros = (amountCents - taxCents) * 1_000_000;
	await env.DB.batch([
		env.DB.prepare(
			`UPDATE billing_customers
			 SET stripe_customer_id = COALESCE(stripe_customer_id, ?), updated_at = ?
			 WHERE account_id = ?`
		).bind(customerID, now, accountID),
		env.DB.prepare(
			`INSERT OR IGNORE INTO tts_accounts (
				account_id, balance_micros, created_at, updated_at
			) VALUES (?, 0, ?, ?)`
		).bind(accountID, now, now),
		env.DB.prepare(
			`INSERT OR IGNORE INTO tts_topups (
				checkout_session_id, account_id, stripe_payment_intent_id,
				amount_micros, refunded_micros, refund_status,
				created_at, credited_at, refunded_at
			) VALUES (?, ?, ?, ?, 0, 'disabled', ?, NULL, NULL)`
		).bind(session.id, accountID, paymentIntentID, amountMicros, createdAt),
		env.DB.prepare(
			`UPDATE tts_accounts
			 SET balance_micros = balance_micros + ?, updated_at = ?
			 WHERE account_id = ? AND EXISTS (
				SELECT 1 FROM tts_topups
				WHERE checkout_session_id = ? AND account_id = ? AND credited_at IS NULL
			 )`
		).bind(amountMicros, now, accountID, session.id, accountID),
		env.DB.prepare(
			`UPDATE tts_topups SET credited_at = ?
			 WHERE checkout_session_id = ? AND account_id = ? AND credited_at IS NULL`
		).bind(now, session.id, accountID)
	]);
}

async function completeStripeCheckout(env, session) {
	const accountID = session?.client_reference_id;
	const reservationID = session?.metadata?.briefly_reservation_id;
	const sessionTierKey =
		typeof session?.metadata?.briefly_tier_key === 'string'
			? session.metadata.briefly_tier_key
			: null;
	const customerID =
		typeof session?.customer === 'string' ? session.customer : session?.customer?.id;
	const subscriptionID =
		typeof session?.subscription === 'string'
			? session.subscription
			: session?.subscription?.id;
	if (
		typeof accountID !== 'string' ||
		typeof customerID !== 'string' ||
		typeof subscriptionID !== 'string' ||
		session?.mode !== 'subscription'
	) {
		return;
	}
	const subscription = await stripeRetrieve(
		env,
		`/subscriptions/${encodeURIComponent(subscriptionID)}`
	);
	const subscriptionCustomerID =
		typeof subscription.customer === 'string'
			? subscription.customer
			: subscription.customer?.id;
	if (
		subscription?.metadata?.briefly_account_id !== accountID ||
		subscriptionCustomerID !== customerID
	) {
		throw new Error('Stripe Checkout metadata did not match its Subscription.');
	}
	await upsertStripeSubscription(env, subscription);
	const priceID = subscription?.items?.data?.[0]?.price?.id;
	const configuredTier = stripeConfig(env)?.tiers.find((tier) => tier.priceID === priceID);
	if (!configuredTier || configuredTier.key !== sessionTierKey) return;

	const now = Date.now();
	if (
		typeof reservationID !== 'string' ||
		!reservationID ||
		!['paid', 'no_payment_required'].includes(session?.payment_status) ||
		!entitledSubscriptionStatuses.has(subscription.status)
	) {
		return;
	}
	const reservation = await env.DB.prepare(
		`SELECT account_id, tier_key, stripe_session_id
		 FROM billing_checkout_reservations
		 WHERE reservation_id = ?`
	)
		.bind(reservationID)
		.first();
	if (
		reservation &&
		(reservation.account_id !== accountID ||
			reservation.tier_key !== configuredTier.key ||
			(reservation.stripe_session_id && reservation.stripe_session_id !== session.id))
	) {
		throw new Error('Stripe Checkout did not match its Briefly tier reservation.');
	}
	const statements = [
		env.DB.prepare(
			`INSERT OR IGNORE INTO billing_allocations (
				reservation_id, account_id, tier_key, allocated_at
			) VALUES (?, ?, ?, ?)`
		).bind(reservationID, accountID, configuredTier.key, now),
		env.DB.prepare(
			'DELETE FROM billing_checkout_reservations WHERE reservation_id = ?'
		).bind(reservationID)
	];
	await env.DB.batch(statements);
}

function invoiceSubscriptionID(invoice) {
	const legacy =
		typeof invoice?.subscription === 'string'
			? invoice.subscription
			: invoice?.subscription?.id;
	if (legacy) return legacy;
	const modern = invoice?.parent?.subscription_details?.subscription;
	return typeof modern === 'string' ? modern : modern?.id;
}

async function releaseCheckoutReservation(env, session) {
	const reservationID = session?.metadata?.briefly_reservation_id;
	if (typeof reservationID === 'string') {
		await env.DB.prepare(
			'DELETE FROM billing_checkout_reservations WHERE reservation_id = ?'
		)
			.bind(reservationID)
			.run();
	}
}

async function refreshStripeSubscription(env, subscription) {
	const latest = await latestStripeSubscription(env, subscription);
	if (latest) await upsertStripeSubscription(env, latest);
}

async function processStripeEvent(env, event) {
	const object = event?.data?.object;
	if (
		event.type === 'checkout.session.completed' ||
		event.type === 'checkout.session.async_payment_succeeded'
	) {
		await completeTTSCheckout(env, object);
		await completeStripeCheckout(env, object);
		return;
	}
	if (
		event.type === 'checkout.session.expired' ||
		event.type === 'checkout.session.async_payment_failed'
	) {
		await releaseCheckoutReservation(env, object);
		return;
	}
	if (
		event.type === 'customer.subscription.created' ||
		event.type === 'customer.subscription.updated' ||
		event.type === 'customer.subscription.deleted'
	) {
		await refreshStripeSubscription(env, object);
		return;
	}
	if (event.type === 'invoice.paid' || event.type === 'invoice.payment_failed') {
		const subscriptionID = invoiceSubscriptionID(object);
		if (typeof subscriptionID === 'string') {
			await refreshStripeSubscription(env, { id: subscriptionID });
		}
	}
}

async function claimStripeWebhookEvent(env, event) {
	const now = Date.now();
	const inserted = await env.DB.prepare(
		`INSERT OR IGNORE INTO stripe_webhook_events (
			event_id, event_type, status, attempts, processed_at
		) VALUES (?, ?, 'processing', 1, ?)`
	)
		.bind(event.id, event.type, now)
		.run();
	if (databaseChanges(inserted) > 0) return 'claimed';
	const existing = await env.DB.prepare(
		`SELECT status, processed_at
		 FROM stripe_webhook_events
		 WHERE event_id = ?`
	)
		.bind(event.id)
		.first();
	if (existing?.status === 'processed') return 'processed';
	const reclaimed = await env.DB.prepare(
		`UPDATE stripe_webhook_events
		 SET event_type = ?, attempts = attempts + 1, processed_at = ?
		 WHERE event_id = ? AND status = 'processing' AND processed_at <= ?`
	)
		.bind(
			event.type,
			now,
			event.id,
			now - stripeWebhookClaimLifetimeMilliseconds
		)
		.run();
	return databaseChanges(reclaimed) > 0 ? 'claimed' : 'processing';
}

async function stripeWebhook(request, env) {
	const config = stripeCredentials(env);
	if (!config) return json({ error: 'Stripe payments are not configured.' }, { status: 503 });
	const rawBody = await request.text();
	if (
		!(await verifyStripeWebhook(
			rawBody,
			request.headers.get('Stripe-Signature'),
			config.webhookSecret
		))
	) {
		return json({ error: 'Invalid Stripe signature.' }, { status: 400 });
	}
	let event;
	try {
		event = JSON.parse(rawBody);
	} catch {
		return json({ error: 'Invalid Stripe event.' }, { status: 400 });
	}
	if (typeof event?.id !== 'string' || typeof event?.type !== 'string') {
		return json({ error: 'Invalid Stripe event.' }, { status: 400 });
	}
	await ensureSchema(env.DB);
	const claim = await claimStripeWebhookEvent(env, event);
	if (claim === 'processed') return json({ received: true, duplicate: true });
	if (claim === 'processing') {
		return json({ error: 'Stripe event is already being processed.' }, { status: 409 });
	}
	try {
		await processStripeEvent(env, event);
		await env.DB.prepare(
			`UPDATE stripe_webhook_events
			 SET status = 'processed', processed_at = ?
			 WHERE event_id = ? AND status = 'processing'`
		)
			.bind(Date.now(), event.id)
			.run();
		return json({ received: true });
	} catch (error) {
		await env.DB.prepare(
			`DELETE FROM stripe_webhook_events
			 WHERE event_id = ? AND status = 'processing'`
		)
			.bind(event.id)
			.run();
		throw error;
	}
}

async function reconcileStripeSubscriptions(env) {
	if (!stripeConfig(env)) return;
	let startingAfter;
	for (let page = 0; page < 20; page += 1) {
		const subscriptions = await stripeRetrieve(env, '/subscriptions', {
			status: 'all',
			limit: 100,
			starting_after: startingAfter
		});
		const records = Array.isArray(subscriptions?.data) ? subscriptions.data : [];
		for (const subscription of records) {
			await upsertStripeSubscription(env, subscription);
		}
		if (!subscriptions?.has_more || records.length === 0) return;
		startingAfter = records.at(-1)?.id;
		if (!startingAfter) return;
	}
	throw new Error('Stripe subscription reconciliation exceeded its safety page limit.');
}

async function releaseStaleTTSReservations(env) {
	await ensureSchema(env.DB);
	const result = await env.DB.prepare(
		`SELECT request_id, account_id, amount_micros
		 FROM tts_usage
		 WHERE status IN ('pending', 'reserved') AND updated_at <= ?
		 LIMIT 100`
	)
		.bind(Date.now() - 60 * 60 * 1000)
		.all();
	for (const entry of result.results ?? []) {
		await releaseTTSUsage(
			env,
			entry.account_id,
			entry.request_id,
			Number(entry.amount_micros)
		);
	}
}

async function googleDriveConnection(env, email) {
	return env.DB.prepare(
		`SELECT client_id, encrypted_client_secret, client_secret_iv,
		        encrypted_access_token, access_token_iv, encrypted_refresh_token,
		        refresh_token_iv, access_token_expires_at, folder_id
		 FROM google_drive_connections WHERE user_email = ?`
	)
		.bind(email)
		.first();
}

async function googleAccessToken(env, email, forceRefresh = false) {
	const connection = await googleDriveConnection(env, email);
	if (!connection?.encrypted_refresh_token || !connection.refresh_token_iv) return null;
	const shouldRefresh =
		forceRefresh ||
		!connection.encrypted_access_token ||
		!connection.access_token_iv ||
		!connection.access_token_expires_at ||
		connection.access_token_expires_at <= Date.now() + 90_000;
	if (!shouldRefresh) {
		return decryptCredential(env, connection.encrypted_access_token, connection.access_token_iv);
	}
	const [clientSecret, refreshToken] = await Promise.all([
		Promise.resolve(googleOAuthConfig(env)?.clientSecret).then(
			(secret) =>
				secret ??
				decryptCredential(
					env,
					connection.encrypted_client_secret,
					connection.client_secret_iv
				)
		),
		decryptCredential(env, connection.encrypted_refresh_token, connection.refresh_token_iv)
	]);
	const clientID = googleOAuthConfig(env)?.clientID ?? connection.client_id;
	const response = await fetch('https://oauth2.googleapis.com/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			client_id: clientID,
			client_secret: clientSecret,
			refresh_token: refreshToken,
			grant_type: 'refresh_token'
		})
	});
	const value = await response.json();
	if (!response.ok || typeof value.access_token !== 'string') return null;
	const encrypted = await encryptCredential(env, value.access_token);
	await env.DB.prepare(
		`UPDATE google_drive_connections SET
			encrypted_access_token = ?, access_token_iv = ?,
			access_token_expires_at = ?, updated_at = ?
		 WHERE user_email = ?`
	)
		.bind(
			encrypted.encryptedAPIKey,
			encrypted.initializationVector,
			Date.now() + Number(value.expires_in || 3600) * 1000,
			new Date().toISOString(),
			email
		)
		.run();
	return value.access_token;
}

async function googleDriveRequest(env, email, url, init = {}) {
	for (const forceRefresh of [false, true]) {
		const token = await googleAccessToken(env, email, forceRefresh);
		if (!token) return new Response('Google Drive is not connected.', { status: 401 });
		const headers = new Headers(init.headers);
		headers.set('Authorization', `Bearer ${token}`);
		const response = await fetch(url, { ...init, headers });
		if (response.status === 401 && !forceRefresh) continue;
		return response;
	}
	return new Response('Google Drive connection expired.', { status: 401 });
}

async function findDriveMedia(env, email, media) {
	const query = `appProperties has { key='sharedLibraryHash' and value='${media.hash}' } and appProperties has { key='sharedLibraryKind' and value='${media.kind}' } and trashed=false`;
	const url = new URL('https://www.googleapis.com/drive/v3/files');
	url.searchParams.set('q', query);
	url.searchParams.set('fields', 'files(id,name,mimeType,size)');
	url.searchParams.set('pageSize', '1');
	const response = await googleDriveRequest(env, email, url);
	if (!response.ok) return { response };
	const value = await response.json();
	return { file: value.files?.[0] ?? null };
}

async function ensureDriveRootFolder(env, email) {
	const connection = await googleDriveConnection(env, email);
	if (connection?.folder_id) return connection.folder_id;
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set('fields', 'files(id)');
	listURL.searchParams.set('pageSize', '1');
	let folderID;
	let response;
	let value;
	for (const query of [
		"appProperties has { key='sharedLibraryRoot' and value='true' } and mimeType='application/vnd.google-apps.folder' and trashed=false",
		"name='Briefly' and mimeType='application/vnd.google-apps.folder' and trashed=false",
		"name='Shared Library' and mimeType='application/vnd.google-apps.folder' and trashed=false",
		"name='Shared Library Media' and mimeType='application/vnd.google-apps.folder' and trashed=false"
	]) {
		listURL.searchParams.set('q', query);
		response = await googleDriveRequest(env, email, listURL);
		if (!response.ok) throw new Error(`Google Drive folder lookup failed (${response.status}).`);
		value = await response.json();
		folderID = value.files?.[0]?.id;
		if (folderID) break;
	}
	if (!folderID) {
		response = await googleDriveRequest(
			env,
			email,
			'https://www.googleapis.com/drive/v3/files?fields=id',
			{
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					name: 'Briefly',
					mimeType: 'application/vnd.google-apps.folder',
					appProperties: { sharedLibraryRoot: 'true' }
				})
			}
		);
		if (!response.ok) throw new Error(`Google Drive folder creation failed (${response.status}).`);
		value = await response.json();
		folderID = value.id;
	}
	await env.DB.prepare(
		`UPDATE google_drive_connections SET folder_id = ?, updated_at = ? WHERE user_email = ?`
	)
		.bind(folderID, new Date().toISOString(), email)
		.run();
	return folderID;
}

async function ensureDriveMediaFolder(env, email) {
	const rootID = await ensureDriveRootFolder(env, email);
	const pathHash = await sha256Hex('audio');
	const listURL = new URL('https://www.googleapis.com/drive/v3/files');
	listURL.searchParams.set(
		'q',
		`appProperties has { key='sharedLibraryKind' and value='folder' } and appProperties has { key='sharedLibraryPathHash' and value='${pathHash}' } and trashed=false`
	);
	listURL.searchParams.set('fields', 'files(id)');
	listURL.searchParams.set('pageSize', '1');
	let response = await googleDriveRequest(env, email, listURL);
	if (!response.ok) throw new Error(`Google Drive audio folder lookup failed (${response.status}).`);
	let value = await response.json();
	if (value.files?.[0]?.id) return value.files[0].id;
	response = await googleDriveRequest(
		env,
		email,
		'https://www.googleapis.com/drive/v3/files?fields=id',
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'audio',
				mimeType: 'application/vnd.google-apps.folder',
				parents: [rootID],
				appProperties: {
					sharedLibraryKind: 'folder',
					sharedLibraryPathHash: pathHash
				}
			})
		}
	);
	if (!response.ok) throw new Error(`Google Drive audio folder creation failed (${response.status}).`);
	value = await response.json();
	return value.id;
}

function mediaPath(url) {
	const match = url.pathname.match(/^\/api\/media\/audio\/([a-f0-9]{64})$/);
	return match ? { kind: 'audio', hash: match[1] } : null;
}

async function listDriveAudio(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const files = [];
	let pageToken;
	do {
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set(
			'q',
			"appProperties has { key='sharedLibraryKind' and value='audio' } and trashed=false"
		);
		url.searchParams.set(
			'fields',
			'nextPageToken,files(id,mimeType,size,appProperties)'
		);
		url.searchParams.set('pageSize', '1000');
		if (pageToken) url.searchParams.set('pageToken', pageToken);
		const response = await googleDriveRequest(env, email, url);
		if (!response.ok) {
			return json(
				{ error: response.status === 401 ? 'Connect Google Drive first.' : 'Google Drive audio could not be listed.' },
				{ status: response.status }
			);
		}
		const value = await response.json();
		for (const file of value.files ?? []) {
			const hash = file.appProperties?.sharedLibraryHash;
			if (!/^[a-f0-9]{64}$/.test(hash || '')) continue;
			files.push({
				hash,
				byteCount: Number(file.size || 0),
				contentType: file.mimeType || 'audio/mpeg'
			});
		}
		pageToken = value.nextPageToken;
	} while (pageToken);
	return json({ files });
}

async function downloadDriveMedia(request, env, media) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const found = await findDriveMedia(env, email, media);
	if (found.response) return found.response;
	if (!found.file) return json({ error: 'Media is not stored in Google Drive.' }, { status: 404 });
	const response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(found.file.id)}?alt=media`,
		{
			headers: request.headers.get('Range') ? { Range: request.headers.get('Range') } : {}
		}
	);
	const headers = new Headers();
	for (const name of ['Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges']) {
		const value = response.headers.get(name);
		if (value) headers.set(name, value);
	}
	headers.set('Cache-Control', 'private, max-age=86400');
	return new Response(response.body, { status: response.status, headers });
}

async function uploadDriveMedia(request, env, media) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const contentLength = Number(request.headers.get('Content-Length') || 0);
	if (contentLength > 25_000_000) {
		return json({ error: 'Media files are limited to 25 MB.' }, { status: 413 });
	}
	const existing = await findDriveMedia(env, email, media);
	if (existing.response) return existing.response;
	if (existing.file) return json({ id: existing.file.id, existed: true });
	const contentType =
		request.headers.get('Content-Type') || 'audio/mpeg';
	if (!contentType.startsWith('audio/')) {
		return json({ error: 'Only audio media is supported.' }, { status: 400 });
	}
	const bytes = await request.arrayBuffer();
	if (!bytes.byteLength || bytes.byteLength > 25_000_000) {
		return json({ error: 'Media files must be between 1 byte and 25 MB.' }, { status: 413 });
	}
	const folderID = await ensureDriveMediaFolder(env, email);
	const metadata = JSON.stringify({
		name: `${media.hash}.mp3`,
		parents: [folderID],
		appProperties: {
			sharedLibraryHash: media.hash,
			sharedLibraryKind: media.kind
		}
	});
	const boundary = `SharedLibrary-${crypto.randomUUID()}`;
	const body = new Blob([
		`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n`,
		metadata,
		`\r\n--${boundary}\r\nContent-Type: ${contentType}\r\n\r\n`,
		bytes,
		`\r\n--${boundary}--\r\n`
	]);
	const response = await googleDriveRequest(
		env,
		email,
		'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id',
		{
			method: 'POST',
			headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
			body
		}
	);
	if (!response.ok) {
		return json({ error: `Google Drive upload failed (${response.status}).` }, { status: response.status });
	}
	const value = await response.json();
	return json({ id: value.id, existed: false });
}

const shareVariants = ['brief', 'concise', 'detailed', 'comprehensive', 'source'];
const maximumShareSpeechSegmentLength = 360;
const maximumShareDocumentBytes = 8_000_000;
const maximumSharePayloadBytes = 32_000_000;

function validShareToken(value) {
	return typeof value === 'string' && /^[A-Za-z0-9_-]{32}$/.test(value);
}

function shareLinkURL(request, token) {
	const url = new URL('/', request.url);
	url.searchParams.set('shared', token);
	return url.toString();
}

function shareSourceString(value, maximumLength, required = false) {
	if (value === undefined && !required) return undefined;
	if (typeof value !== 'string' || value.length > maximumLength || (required && !value.trim())) {
		throw new Error('The selected document contains invalid metadata.');
	}
	return value;
}

function shareSourceStrings(value) {
	if (
		!Array.isArray(value) ||
		value.length > 100 ||
		value.some((item) => typeof item !== 'string' || item.length > 256)
	) {
		throw new Error('The selected document contains invalid metadata.');
	}
	return value;
}

function directShareSource(value, captureID) {
	if (value === undefined) return null;
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		throw new Error('The selected document is invalid.');
	}
	if (
		typeof value.filename !== 'string' ||
		!/^[^/\\]{1,255}\.md$/i.test(value.filename) ||
		!Array.isArray(value.texts) ||
		value.texts.length < 1 ||
		value.texts.length > shareVariants.length
	) {
		throw new Error('The selected document is invalid.');
	}
	const title = shareSourceString(value.title, 500, true);
	const excerpt = shareSourceString(value.excerpt, 2_000) ?? '';
	const documents = [];
	const variants = new Set();
	let totalBytes = 0;
	for (const document of value.texts) {
		if (
			typeof document !== 'object' ||
			document === null ||
			!shareVariants.includes(document.variant) ||
			variants.has(document.variant) ||
			typeof document.markdown !== 'string'
		) {
			throw new Error('The selected document is invalid.');
		}
		const byteCount = new TextEncoder().encode(document.markdown).byteLength;
		totalBytes += byteCount;
		if (byteCount > maximumShareDocumentBytes || totalBytes > maximumSharePayloadBytes) {
			throw new Error('The selected document is too large to share.');
		}
		variants.add(document.variant);
		documents.push({
			variant: document.variant,
			markdown: document.markdown,
			wordCount: wordCount(
				document.variant === 'source'
					? parsedMarkdownDocument(document.markdown, title).body
					: document.markdown
			)
		});
	}
	if (!variants.has('source')) throw new Error('The selected document has no source text.');
	return {
		entry: {
			captureID,
			title,
			excerpt,
			topicIDs: shareSourceStrings(value.topicIDs),
			topicNames: shareSourceStrings(value.topicNames),
			tags: shareSourceStrings(value.tags),
			sourceURL: shareSourceString(value.sourceURL, 2_048),
			createdAt: shareSourceString(value.createdAt, 64),
			updatedAt: shareSourceString(value.updatedAt, 64)
		},
		sourcePath: `library/${value.filename}`,
		documents
	};
}

async function shareLinkForOwner(env, email, captureID) {
	return env.DB.prepare(
		`SELECT token, owner_email, capture_id, generation, revision, status,
		        metadata_json, source_filename, voice, error_message, created_at, updated_at
		 FROM share_links
		 WHERE owner_email = ? AND capture_id = ?`
	)
		.bind(email, captureID)
		.first();
}

async function shareLinkByToken(env, token) {
	return env.DB.prepare(
		`SELECT token, owner_email, capture_id, generation, revision, status,
		        metadata_json, source_filename, voice, error_message, created_at, updated_at
		 FROM share_links
		 WHERE token = ?`
	)
		.bind(token)
		.first();
}

async function shareLinksForOwner(env, email) {
	return env.DB.prepare(
		`SELECT token, owner_email, capture_id, generation, revision, status,
		        metadata_json, source_filename, voice, error_message, created_at, updated_at
		 FROM share_links
		 WHERE owner_email = ?
		 ORDER BY updated_at DESC
		 LIMIT ?`
	)
		.bind(email, maximumActiveShareLinks)
		.all();
}

function shareLinkResponse(request, record) {
	if (!record) return { shared: false };
	let metadata;
	try {
		metadata = record.metadata_json ? JSON.parse(record.metadata_json) : undefined;
	} catch {
		metadata = undefined;
	}
	return {
		shared: true,
		token: record.token,
		generation: record.generation,
		url: shareLinkURL(request, record.token),
		status: record.status,
		revision: Number(record.revision ?? 1),
		error: record.error_message ?? undefined,
		metadata,
		voice: record.voice,
		updatedAt: record.updated_at
	};
}

function shareSpokenText(markdown) {
	return String(markdown ?? '')
		.replace(/^---[\s\S]*?---\s*/m, '')
		.replace(/```[\s\S]*?```/g, ' ')
		.replace(/`([^`]+)`/g, '$1')
		.replace(/!\[[^\]]*\]\([^)]+\)/g, ' ')
		.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
		.replace(/^#{1,6}\s+/gm, '')
		.replace(/^>\s?/gm, '')
		.replace(/^[*-]\s+/gm, '')
		.replace(/^\d+\.\s+/gm, '')
		.replace(/[*_~]/g, '')
		.replace(/\s+/g, ' ')
		.trim();
}

function shareSpeechChunks(text) {
	const sentences = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [text];
	const chunks = [];
	let current = '';
	const flush = () => {
		if (current.trim()) chunks.push(current.trim());
		current = '';
	};
	for (const sentence of sentences) {
		const trimmed = sentence.trim();
		if (!trimmed) continue;
		if (trimmed.length > maximumShareSpeechSegmentLength) {
			flush();
			let remaining = trimmed;
			while (remaining.length > maximumShareSpeechSegmentLength) {
				const candidate = remaining.slice(0, maximumShareSpeechSegmentLength + 1);
				const wordBoundary = candidate.lastIndexOf(' ');
				const splitAt =
					wordBoundary >= Math.floor(maximumShareSpeechSegmentLength * 0.6)
						? wordBoundary
						: maximumShareSpeechSegmentLength;
				chunks.push(remaining.slice(0, splitAt).trim());
				remaining = remaining.slice(splitAt).trim();
			}
			if (remaining) current = remaining;
		} else if (
			current &&
			current.length + trimmed.length + 1 > maximumShareSpeechSegmentLength
		) {
			flush();
			current = trimmed;
		} else {
			current = current ? `${current} ${trimmed}` : trimmed;
		}
	}
	flush();
	return chunks;
}

async function shareAudioFingerprint(text, voice, model) {
	return sha256Hex(`${model}\n${voice}\n${text}`);
}

async function driveAudioFilesByHash(env, email) {
	const files = new Map();
	let pageToken;
	do {
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set(
			'q',
			"appProperties has { key='sharedLibraryKind' and value='audio' } and trashed=false"
		);
		url.searchParams.set(
			'fields',
			'nextPageToken,files(id,mimeType,size,appProperties)'
		);
		url.searchParams.set('pageSize', '1000');
		if (pageToken) url.searchParams.set('pageToken', pageToken);
		const response = await googleDriveRequest(env, email, url);
		if (!response.ok) {
			throw new Error(`Google Drive narration could not be listed (${response.status}).`);
		}
		const value = await response.json();
		for (const file of value.files ?? []) {
			const hash = file.appProperties?.sharedLibraryHash;
			if (/^[a-f0-9]{64}$/.test(hash || '')) files.set(hash, file);
		}
		pageToken = value.nextPageToken;
	} while (pageToken);
	return files;
}

async function loadPersonalShareAfterDriveSync(env, email, captureID) {
	let lastError;
	for (let attempt = 0; attempt < 5; attempt += 1) {
		try {
			return await loadPersonalSharingItem(env, email, captureID, true);
		} catch (error) {
			lastError = error;
			if (attempt < 4) {
				const delay = Number(env.SHARE_PREPARE_RETRY_DELAY_MS ?? 1_500);
				if (delay > 0) {
					await new Promise((resolve) => setTimeout(resolve, delay));
				}
			}
		}
	}
	throw lastError;
}

async function removeShareGeneration(env, token, generation) {
	const audio = await env.DB.prepare(
		`SELECT r2_key FROM share_audio_segments
		 WHERE share_token = ? AND generation = ?`
	)
		.bind(token, generation)
		.all();
	if (env.SHARE_MEDIA) {
		await Promise.all(
			(audio.results ?? []).map((segment) => env.SHARE_MEDIA.delete(segment.r2_key))
		);
	}
	await env.DB.batch([
		env.DB.prepare(
			'DELETE FROM share_audio_segments WHERE share_token = ? AND generation = ?'
		).bind(token, generation),
		env.DB.prepare(
			'DELETE FROM share_texts WHERE share_token = ? AND generation = ?'
		).bind(token, generation)
	]);
}

async function removeOldShareGenerations(env, token, currentGeneration) {
	const audio = await env.DB.prepare(
		`SELECT DISTINCT generation, r2_key FROM share_audio_segments
		 WHERE share_token = ? AND generation <> ?`
	)
		.bind(token, currentGeneration)
		.all();
	if (env.SHARE_MEDIA) {
		await Promise.all(
			(audio.results ?? []).map((segment) => env.SHARE_MEDIA.delete(segment.r2_key))
		);
	}
	await env.DB.batch([
		env.DB.prepare(
			'DELETE FROM share_audio_segments WHERE share_token = ? AND generation <> ?'
		).bind(token, currentGeneration),
		env.DB.prepare(
			'DELETE FROM share_texts WHERE share_token = ? AND generation <> ?'
		).bind(token, currentGeneration)
	]);
}

async function prepareShareLink(
	env,
	email,
	token,
	captureID,
	generation,
	directSource = null
) {
	try {
		const personal =
			directSource ?? (await loadPersonalShareAfterDriveSync(env, email, captureID));
		let documents = directSource?.documents ?? [];
		if (!directSource) {
			const personalFiles = new Map(personal.files.map((item) => [item.path, item.file]));
			documents = [];
			for (const reference of personal.entry.texts ?? []) {
				if (!shareVariants.includes(reference?.variant) || typeof reference?.path !== 'string') {
					continue;
				}
				const file = personalFiles.get(reference.path);
				if (!file) continue;
				const markdown = new TextDecoder().decode(await downloadDriveFile(env, email, file.id));
				documents.push({
					variant: reference.variant,
					markdown,
					wordCount: wordCount(
						reference.variant === 'source'
							? parsedMarkdownDocument(markdown, personal.entry.title).body
							: markdown
					)
				});
			}
		}
		if (!documents.some((document) => document.variant === 'source')) {
			throw new Error('The source document is unavailable.');
		}

		for (const document of documents) {
			await env.DB.prepare(
				`INSERT OR REPLACE INTO share_texts (
					share_token, generation, variant, markdown, word_count
				) VALUES (?, ?, ?, ?, ?)`
			)
				.bind(
					token,
					generation,
					document.variant,
					document.markdown,
					document.wordCount
				)
				.run();
		}

		const metadata = {
			captureID: personal.entry.captureID ?? captureID,
			title: personal.entry.title,
			excerpt: personal.entry.excerpt,
			topicIDs: personal.entry.topicIDs ?? [],
			topicNames: personal.entry.topicNames ?? [],
			tags: personal.entry.tags ?? [],
			sourceURL: personal.entry.sourceURL,
			createdAt: personal.entry.createdAt,
			updatedAt: personal.entry.updatedAt
		};
		const completed = await env.DB.prepare(
			`UPDATE share_links
			 SET status = 'ready', metadata_json = ?, source_filename = ?,
			     error_message = NULL, updated_at = ?
			 WHERE token = ? AND generation = ?`
		)
			.bind(
				JSON.stringify(metadata),
				personal.sourcePath.split('/').at(-1),
				new Date().toISOString(),
				token,
				generation
			)
			.run();
		if (Number(completed?.meta?.changes ?? 0) === 0) {
			await removeShareGeneration(env, token, generation);
			return;
		}
		await removeOldShareGenerations(env, token, generation);
	} catch (error) {
		const message =
			error instanceof Error ? error.message : 'The share link could not be prepared.';
		await env.DB.prepare(
			`UPDATE share_links
			 SET status = 'failed', error_message = ?, updated_at = ?
			 WHERE token = ? AND generation = ?`
		)
			.bind(message, new Date().toISOString(), token, generation)
			.run();
	}
}

async function uploadShareAudio(request, env, token, generation, variant, index, hash) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	if (
		!/^[a-f0-9-]{36}$/.test(generation) ||
		!shareVariants.includes(variant) ||
		!Number.isSafeInteger(index) ||
		index < 0 ||
		index > 10_000 ||
		!/^[a-f0-9]{64}$/.test(hash)
	) {
		return json({ error: 'Invalid narration segment.' }, { status: 400 });
	}
	await ensureSchema(env.DB);
	const record = await shareLinkByToken(env, token);
	if (!record || record.owner_email !== email) {
		return json({ error: 'Share link not found.' }, { status: 404 });
	}
	if (record.generation !== generation) {
		return json({ error: 'This share link has been updated.' }, { status: 409 });
	}
	if (!env.SHARE_MEDIA) {
		return json({ error: 'Shared narration storage is unavailable.' }, { status: 503 });
	}
	const contentType = request.headers.get('Content-Type') || 'audio/mpeg';
	if (!contentType.startsWith('audio/')) {
		return json({ error: 'Only audio narration can be shared.' }, { status: 400 });
	}
	const bytes = await request.arrayBuffer();
	if (!bytes.byteLength || bytes.byteLength > 25_000_000) {
		return json({ error: 'Narration segments must be between 1 byte and 25 MB.' }, { status: 413 });
	}
	const voice = requestedOpenRouterVoice(request.headers.get('X-Briefly-Voice'));
	if (!voice) return json({ error: 'Choose a supported narration voice.' }, { status: 400 });
	const r2Key = `shares/${token}/${generation}/${variant}/${index}-${hash}.mp3`;
	await env.SHARE_MEDIA.put(r2Key, bytes, { httpMetadata: { contentType } });
	await env.DB.prepare(
		`INSERT OR REPLACE INTO share_audio_segments (
			share_token, generation, variant, segment_index, audio_hash,
			r2_key, content_type, byte_count, voice
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
	)
		.bind(
			token,
			generation,
			variant,
			index,
			hash,
			r2Key,
			contentType,
			bytes.byteLength,
			voice
		)
		.run();
	return json({ saved: true });
}

async function ownerShareLinkStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!captureID) {
		const result = await shareLinksForOwner(env, email);
		return json({
			limit: maximumActiveShareLinks,
			links: (result.results ?? []).map((record) => ({
				...shareLinkResponse(request, record),
				captureID: record.capture_id
			}))
		});
	}
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	return json(shareLinkResponse(request, await shareLinkForOwner(env, email, captureID)));
}

async function publishShareLink(request, env, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid share-link request.' }, { status: 400 });
	}
	const captureID = value?.captureID;
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	let source;
	try {
		source = directShareSource(value?.source, captureID);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The selected document is invalid.' },
			{ status: 400 }
		);
	}
	const token = randomBase64URL(24);
	const generation = crypto.randomUUID();
	const now = new Date().toISOString();
	const published = await env.DB.prepare(
		`INSERT INTO share_links (
			token, owner_email, capture_id, generation, revision, status,
			metadata_json, source_filename, voice, error_message, created_at, updated_at
		)
		SELECT ?, ?, ?, ?, 1, 'preparing', NULL, NULL, ?, NULL, ?, ?
		WHERE EXISTS (
			SELECT 1 FROM share_links WHERE owner_email = ? AND capture_id = ?
		) OR (
			SELECT COUNT(*) FROM share_links WHERE owner_email = ?
		) < ?
		ON CONFLICT(owner_email, capture_id) DO UPDATE SET
			generation = excluded.generation,
			revision = share_links.revision + 1,
			status = 'preparing',
			error_message = NULL,
			updated_at = excluded.updated_at`
	)
		.bind(
			token,
			email,
			captureID,
			generation,
			'af_heart',
			now,
			now,
			email,
			captureID,
			email,
			maximumActiveShareLinks
		)
		.run();
	if (Number(published?.meta?.changes ?? 0) === 0) {
		return json(
			{
				error: `You can publish up to ${maximumActiveShareLinks} active links. Stop sharing one before creating another.`,
				code: 'share_limit_reached'
			},
			{ status: 409 }
		);
	}
	const record = await shareLinkForOwner(env, email, captureID);
	scheduleSharingOperation(
		context,
		prepareShareLink(env, email, record.token, captureID, generation, source)
	);
	return json(shareLinkResponse(request, record), { status: 202 });
}

async function revokeShareLink(request, env, token, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const record = await shareLinkByToken(env, token);
	if (!record || record.owner_email !== email) {
		return json({ error: 'Share link not found.' }, { status: 404 });
	}
	const audio = await env.DB.prepare(
		'SELECT r2_key FROM share_audio_segments WHERE share_token = ?'
	)
		.bind(token)
		.all();
	await env.DB.batch([
		env.DB.prepare('DELETE FROM share_audio_segments WHERE share_token = ?').bind(token),
		env.DB.prepare('DELETE FROM share_texts WHERE share_token = ?').bind(token),
		env.DB.prepare('DELETE FROM share_links WHERE token = ? AND owner_email = ?').bind(token, email)
	]);
	if (env.SHARE_MEDIA) {
		scheduleSharingOperation(
			context,
			Promise.all(
				(audio.results ?? []).map((segment) => env.SHARE_MEDIA.delete(segment.r2_key))
			)
		);
	}
	return json({ revoked: true });
}

async function publicShareDocument(request, env, token) {
	await ensureSchema(env.DB);
	const record = await shareLinkByToken(env, token);
	if (!record) return json({ error: 'This share link is no longer available.' }, { status: 404 });
	if (record.status !== 'ready') {
		return json(
			{
				status: record.status,
				error: record.status === 'failed' ? record.error_message : undefined
			},
			{ status: record.status === 'preparing' ? 202 : 409 }
		);
	}
	const textResult = await env.DB.prepare(
		`SELECT variant, markdown, word_count FROM share_texts
		 WHERE share_token = ? AND generation = ?`
	)
		.bind(token, record.generation)
		.all();
	let metadata = {};
	try {
		metadata = JSON.parse(record.metadata_json ?? '{}');
	} catch {
		metadata = {};
	}
	const texts = (textResult.results ?? [])
		.map((document) => ({
			variant: document.variant,
			markdown:
				document.variant === 'source'
					? parsedMarkdownDocument(document.markdown, metadata.title ?? 'Shared document').body
					: document.markdown,
			wordCount: Number(document.word_count ?? 0)
		}))
		.sort(
			(a, b) => shareVariants.indexOf(a.variant) - shareVariants.indexOf(b.variant)
		);
	return json({
		status: 'ready',
		token,
		revision: Number(record.revision ?? 1),
		...metadata,
		texts,
		updatedAt: record.updated_at
	});
}

async function publicShareAudio(request, env, token, variant, index) {
	await ensureSchema(env.DB);
	const record = await shareLinkByToken(env, token);
	if (!record || record.status !== 'ready') {
		return json({ error: 'This narration is no longer available.' }, { status: 404 });
	}
	const segment = await env.DB.prepare(
		`SELECT r2_key, content_type, byte_count FROM share_audio_segments
		 WHERE share_token = ? AND generation = ? AND variant = ? AND segment_index = ?`
	)
		.bind(token, record.generation, variant, index)
		.first();
	if (!segment || !env.SHARE_MEDIA) {
		return json({ error: 'This narration is not available.' }, { status: 404 });
	}
	const object = await env.SHARE_MEDIA.get(segment.r2_key);
	if (!object) return json({ error: 'This narration is not available.' }, { status: 404 });
	const headers = new Headers({
		'Content-Type': segment.content_type || 'audio/mpeg',
		'Cache-Control': 'private, max-age=3600'
	});
	const contentLength = Number(segment.byte_count || object.size || 0);
	if (contentLength > 0) headers.set('Content-Length', String(contentLength));
	return new Response(object.body, {
		headers
	});
}

function normalizedUsername(value) {
	return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

function validUsername(value) {
	const username = normalizedUsername(value);
	return /^[a-z0-9](?:[a-z0-9_-]{0,30}[a-z0-9])?$/.test(username);
}

function googleDriveFolderID(value) {
	if (typeof value !== 'string') return null;
	const trimmed = value.trim();
	if (!trimmed) return null;
	let candidate = trimmed;
	try {
		const url = new URL(trimmed);
		const components = url.pathname.split('/').filter(Boolean);
		const index = components.indexOf('folders');
		if (index >= 0 && components[index + 1]) candidate = components[index + 1];
	} catch {
		// A bare folder ID is also valid.
	}
	return /^[A-Za-z0-9_-]{10,256}$/.test(candidate) ? candidate : null;
}

async function sharedFolderConnection(env, email) {
	return env.DB.prepare(
		`SELECT folder_id, user_id, username, connected_at
		 FROM shared_folder_connections WHERE user_email = ?`
	)
		.bind(email)
		.first();
}

async function sharedFolderStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ connected: false }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	return json({
		connected: Boolean(connection),
		folderID: connection?.folder_id ?? undefined,
		userID: connection?.user_id ?? undefined,
		username: connection?.username ?? undefined,
		connectedAt: connection?.connected_at ?? undefined
	});
}

function validSharedPath(path) {
	if (path === 'people.json') return true;
	if (typeof path !== 'string' || path.length > 2048) return false;
	const components = path.split('/');
	if (components.length !== 2 || components.some((component) => !component)) return false;
	if (components[0] === 'library') return components[1].endsWith('.md');
	if (components[0] === 'shares') return components[1].endsWith('.json');
	return false;
}

async function driveFolderMetadata(env, email, folderID) {
	const url = new URL(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(folderID)}`);
	url.searchParams.set('fields', 'id,name,mimeType,capabilities(canEdit)');
	url.searchParams.set('supportsAllDrives', 'true');
	const response = await googleDriveRequest(env, email, url);
	if (!response.ok) {
		throw new Error(
			response.status === 404
				? 'Google Drive has not granted Briefly access to that folder. Choose it with the folder picker, then try again.'
				: `The shared Google Drive folder could not be opened (${response.status}).`
		);
	}
	const folder = await response.json();
	if (folder.mimeType !== 'application/vnd.google-apps.folder') {
		throw new Error('The sharing location must be a Google Drive folder.');
	}
	if (folder.capabilities?.canEdit === false) {
		throw new Error('You need edit access to the shared Google Drive folder.');
	}
	return folder;
}

async function driveFolderChildren(env, email, parentID) {
	const files = [];
	let pageToken;
	do {
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set(
			'q',
			`'${String(parentID).replaceAll("'", "\\'")}' in parents and trashed=false`
		);
		url.searchParams.set(
			'fields',
			'nextPageToken,files(id,name,mimeType,parents,modifiedTime,appProperties)'
		);
		url.searchParams.set('pageSize', '1000');
		url.searchParams.set('supportsAllDrives', 'true');
		url.searchParams.set('includeItemsFromAllDrives', 'true');
		if (pageToken) url.searchParams.set('pageToken', pageToken);
		const response = await googleDriveRequest(env, email, url);
		if (!response.ok) {
			throw new Error(`The shared Google Drive folder could not be listed (${response.status}).`);
		}
		const value = await response.json();
		files.push(...(value.files ?? []));
		pageToken = value.nextPageToken;
	} while (pageToken);
	return files;
}

async function driveFolderTree(
	env,
	email,
	rootFolderID,
	allowedPath = validSharedPath,
	includeHiddenFolders = false
) {
	const folders = new Map([['', rootFolderID]]);
	const files = new Map();
	const queue = [{ path: '', id: rootFolderID }];
	for (let index = 0; index < queue.length; index += 1) {
		const parent = queue[index];
		for (const item of await driveFolderChildren(env, email, parent.id)) {
			if (
				typeof item.name !== 'string' ||
				!item.name ||
				item.name === '.' ||
				item.name === '..' ||
				item.name.includes('/')
			) {
				continue;
			}
			const path = parent.path ? `${parent.path}/${item.name}` : item.name;
			if (item.mimeType === 'application/vnd.google-apps.folder') {
				if (!includeHiddenFolders && path.startsWith('.')) continue;
				folders.set(path, item.id);
				queue.push({ path, id: item.id });
			} else if (allowedPath(path)) {
				files.set(path, { ...item, path });
			}
		}
	}
	return { folders, files };
}

async function shallowSharedTree(env, email, rootFolderID) {
	const folders = new Map([['', rootFolderID]]);
	const files = new Map();
	const rootChildren = await driveFolderChildren(env, email, rootFolderID);
	for (const item of rootChildren) {
		if (item.mimeType === 'application/vnd.google-apps.folder') {
			if (item.name === 'library' || item.name === 'shares') folders.set(item.name, item.id);
		} else if (item.name === 'people.json') {
			files.set('people.json', { ...item, path: 'people.json' });
		}
	}
	await Promise.all(
		['library', 'shares'].map(async (directory) => {
			const folderID = folders.get(directory);
			if (!folderID) return;
			for (const item of await driveFolderChildren(env, email, folderID)) {
				if (item.mimeType === 'application/vnd.google-apps.folder') continue;
				const path = `${directory}/${item.name}`;
				if (validSharedPath(path)) files.set(path, { ...item, path });
			}
		})
	);
	return { folders, files };
}

async function downloadDriveFile(env, email, fileID) {
	const response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileID)}?alt=media&supportsAllDrives=true`
	);
	if (!response.ok) {
		throw new Error(`A shared file could not be downloaded (${response.status}).`);
	}
	return new Uint8Array(await response.arrayBuffer());
}

function driveContentType(path) {
	if (path.endsWith('.json')) return 'application/json';
	if (path.endsWith('.md') || path.endsWith('.markdown')) return 'text/markdown';
	if (path.endsWith('.mp3')) return 'audio/mpeg';
	if (path.endsWith('.m4a')) return 'audio/mp4';
	return 'application/octet-stream';
}

async function ensureDrivePath(
	env,
	email,
	rootFolderID,
	folders,
	path,
	folderKind = 'shared-folder'
) {
	if (!path) return rootFolderID;
	let parentID = rootFolderID;
	let currentPath = '';
	for (const component of path.split('/')) {
		currentPath = currentPath ? `${currentPath}/${component}` : component;
		const existing = folders.get(currentPath);
		if (existing) {
			parentID = existing;
			continue;
		}
		const url = new URL('https://www.googleapis.com/drive/v3/files');
		url.searchParams.set('fields', 'id');
		url.searchParams.set('supportsAllDrives', 'true');
		const response = await googleDriveRequest(env, email, url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: component,
				mimeType: 'application/vnd.google-apps.folder',
				parents: [parentID],
				appProperties: {
					sharedLibraryKind: folderKind,
					sharedLibraryPathHash: await sha256Hex(currentPath)
				}
			})
		});
		if (!response.ok) {
			throw new Error(`A shared Google Drive folder could not be created (${response.status}).`);
		}
		parentID = (await response.json()).id;
		folders.set(currentPath, parentID);
	}
	return parentID;
}

async function upsertDriveFile(
	env,
	email,
	{ rootFolderID, folders, path, bytes, existingID = null, kind = 'shared-workspace' }
) {
	const components = path.split('/');
	const name = components.pop();
	const parentID = existingID
		? null
		: await ensureDrivePath(
				env,
				email,
				rootFolderID,
				folders,
				components.join('/'),
				kind === 'workspace' || kind === 'library-index' ? 'folder' : 'shared-folder'
			);
	const contentHash = await sha256Hex(bytes);
	const metadata = {
		name,
		appProperties: {
			sharedLibraryKind: kind,
			sharedLibraryPathHash: await sha256Hex(path),
			sharedLibraryContentHash: contentHash
		}
	};
	if (!existingID) metadata.parents = [parentID];
	const boundary = `SharedLibrary-${crypto.randomUUID()}`;
	const body = new Blob([
		`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n`,
		JSON.stringify(metadata),
		`\r\n--${boundary}\r\nContent-Type: ${driveContentType(path)}\r\n\r\n`,
		bytes,
		`\r\n--${boundary}--\r\n`
	]);
	const uploadURL = existingID
		? `https://www.googleapis.com/upload/drive/v3/files/${encodeURIComponent(existingID)}?uploadType=multipart&fields=id&supportsAllDrives=true`
		: 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id&supportsAllDrives=true';
	const response = await googleDriveRequest(env, email, uploadURL, {
		method: existingID ? 'PATCH' : 'POST',
		headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
		body
	});
	if (!response.ok) {
		throw new Error(`A Google Drive file could not be saved (${response.status}).`);
	}
	return { id: (await response.json()).id, contentHash, byteCount: bytes.byteLength };
}

async function trashDriveFile(env, email, fileID) {
	const response = await googleDriveRequest(
		env,
		email,
		`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileID)}?supportsAllDrives=true`,
		{
			method: 'PATCH',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ trashed: true })
		}
	);
	if (!response.ok) {
		throw new Error(`A shared Google Drive file could not be removed (${response.status}).`);
	}
}

async function registerSharedProfile(env, email, rootFolderID, username, existingUserID) {
	const tree = await shallowSharedTree(env, email, rootFolderID);
	const peopleFile = tree.files.get('people.json');
	let people = [];
	if (peopleFile) {
		try {
			const document = JSON.parse(
				new TextDecoder().decode(await downloadDriveFile(env, email, peopleFile.id))
			);
			if (document?.schemaVersion !== 2 || !Array.isArray(document.people)) {
				throw new Error('The shared people directory is not version 2.');
			}
			people = document.people;
		} catch (error) {
			throw new Error(
				error instanceof Error ? error.message : 'The shared people directory is invalid.'
			);
		}
	}
	const userID = validSharedUserID(existingUserID)
		? existingUserID
		: crypto.randomUUID().toLowerCase();
	const taken = people.find(
		(person) =>
			normalizedUsername(person?.username) === username &&
			person?.userID !== userID
	);
	if (taken) throw new Error(`@${username} is already used by another person.`);
	const now = new Date().toISOString();
	people = people
		.filter((person) => person?.userID !== userID)
		.concat({ userID, username, updatedAt: now })
		.sort((a, b) => normalizedUsername(a.username).localeCompare(normalizedUsername(b.username)));
	const document = new TextEncoder().encode(
		JSON.stringify(
			{ schemaVersion: 2, people, updatedAt: now },
			null,
			2
		)
	);
	await upsertDriveFile(env, email, {
		rootFolderID,
		folders: tree.folders,
		path: 'people.json',
		bytes: document,
		existingID: peopleFile?.id ?? null
	});
	await Promise.all([
		ensureDrivePath(env, email, rootFolderID, tree.folders, 'library'),
		ensureDrivePath(env, email, rootFolderID, tree.folders, 'shares')
	]);
	return userID;
}

async function connectSharedFolder(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid connection request.' }, { status: 400 });
	}
	const folderID = googleDriveFolderID(value?.folder);
	const username = normalizedUsername(value?.username);
	if (!folderID) return json({ error: 'Choose a valid Google Drive folder.' }, { status: 400 });
	const groupFolderID = configuredGroupFolderID(env);
	if (groupFolderID && folderID !== groupFolderID) {
		return json(
			{ error: 'Choose the predefined Briefly group folder.' },
			{ status: 400 }
		);
	}
	if (!validUsername(username)) {
		return json(
			{ error: 'Use 2–32 letters, numbers, hyphens, or underscores for the username.' },
			{ status: 400 }
		);
	}
	try {
		const folder = await driveFolderMetadata(env, email, folderID);
		const existingConnection = await sharedFolderConnection(env, email);
		const userID = await registerSharedProfile(
			env,
			email,
			folderID,
			username,
			existingConnection?.user_id
		);
		const now = new Date().toISOString();
		await env.DB.prepare(
			`INSERT INTO shared_folder_connections (
				user_email, folder_id, user_id, username, connected_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(user_email) DO UPDATE SET
				folder_id = excluded.folder_id,
				user_id = excluded.user_id,
				username = excluded.username,
				updated_at = excluded.updated_at`
		)
			.bind(email, folderID, userID, username, now, now)
			.run();
		return json({ connected: true, folderID, folderName: folder.name, userID, username });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The shared folder could not be connected.' },
			{ status: 400 }
		);
	}
}

async function disconnectSharedFolder(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM sharing_operations WHERE user_email = ?').bind(email),
		env.DB.prepare('DELETE FROM shared_folder_connections WHERE user_email = ?').bind(email)
	]);
	return json({ disconnected: true });
}

function parsedMarkdownDocument(text, fallbackTitle) {
	let title = fallbackTitle;
	let body = text;
	let captureID;
	let sourceURL;
	let topicIDs = [];
	let tags = [];
	let createdAt;
	if (text.startsWith('---')) {
		const end = text.indexOf('\n---', 3);
		if (end >= 0) {
			const frontmatter = text.slice(3, end);
			body = text.slice(end + 4).trim();
			const scalar = (name) => {
				const match = frontmatter.match(new RegExp(`^${name}:\\s*[\"']?([^\\n\"']+)[\"']?\\s*$`, 'm'));
				return match?.[1]?.trim();
			};
			title = scalar('title') || title;
			captureID = scalar('id');
			sourceURL = scalar('source_url');
			createdAt = scalar('created_at');
			const tagLine = scalar('tags');
			if (tagLine?.startsWith('[')) {
				try {
					tags = JSON.parse(tagLine.replaceAll("'", '"'));
				} catch {
					tags = [];
				}
			}
			const topicsBlock = frontmatter.match(/^topics:\s*\n((?:\s+-[^\n]+\n?)*)/m)?.[1] ?? '';
			topicIDs = [...topicsBlock.matchAll(/^\s+-\s*[\"']?([^\"'\n]+)[\"']?\s*$/gm)].map(
				(match) => match[1].trim()
			);
		}
	}
	return {
		title,
		body,
		captureID,
		sourceURL,
		topicIDs,
		topicNames: topicIDs,
		tags: Array.isArray(tags) ? tags.filter((tag) => typeof tag === 'string') : [],
		createdAt,
		excerpt: body.replace(/\s+/g, ' ').trim().slice(0, 260)
	};
}

function validCaptureIdentifier(value) {
	return (
		typeof value === 'string' &&
		value.length >= 1 &&
		value.length <= 256 &&
		/^[a-zA-Z0-9:_-]+$/.test(value)
	);
}

function validSharedUserID(value) {
	return (
		typeof value === 'string' &&
		value.length >= 1 &&
		value.length <= 128 &&
		/^[a-zA-Z0-9_-]+$/.test(value)
	);
}

async function loadSharedPeople(env, email, tree) {
	const file = tree.files.get('people.json');
	if (!file) return [];
	let document;
	try {
		document = JSON.parse(
			new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
		);
	} catch {
		throw new Error('The shared people directory is invalid.');
	}
	if (document?.schemaVersion !== 2 || !Array.isArray(document.people)) {
		throw new Error('The shared people directory is not version 2.');
	}
	const people = document.people
		.filter(
			(profile) =>
				validSharedUserID(profile?.userID) &&
				validUsername(profile?.username)
		)
		.map((profile) => ({
			userID: profile.userID,
			username: normalizedUsername(profile.username)
		}));
	return [...new Map(people.map((person) => [person.userID, person])).values()].sort(
		(a, b) => a.username.localeCompare(b.username)
	);
}

async function loadPersonalSharingItem(env, email, captureID, includeFiles = false) {
	const indexFile = await driveFileByKind(env, email, 'library-index');
	if (!indexFile) {
		throw new Error('Your personal library has not synchronized to Google Drive yet.');
	}
	let index;
	try {
		index = JSON.parse(
			new TextDecoder().decode(await downloadDriveFile(env, email, indexFile.id))
		);
	} catch {
		throw new Error('The personal library index in Google Drive is invalid.');
	}
	const entry = Array.isArray(index?.entries)
		? index.entries.find(
				(candidate) =>
					candidate?.origin === 'personal' &&
					(candidate.captureID === captureID || candidate.id === captureID)
			)
		: null;
	if (!entry) throw new Error('This document is no longer in your personal library.');
	const sourceReference = Array.isArray(entry.texts)
		? entry.texts.find(
				(text) =>
					text?.variant === 'source' &&
					typeof text.path === 'string' &&
					/^library\/[^/]+$/.test(text.path)
			)
		: null;
	if (!sourceReference) {
		throw new Error('This document has no synchronized source file to share.');
	}
	if (!includeFiles) return { entry, sourcePath: sourceReference.path, files: [] };
	const personalRootID = await ensureDriveRootFolder(env, email);
	const tree = await driveFolderTree(
		env,
		email,
		personalRootID,
		personalWorkspacePath,
		true
	);
	const paths = [
		...new Set(
			entry.texts
				.map((text) => text?.path)
				.filter((path) => typeof path === 'string' && personalWorkspacePath(path))
		)
	];
	const files = paths
		.map((path) => ({ path, file: tree.files.get(path) }))
		.filter((item) => item.file);
	if (!files.some((item) => item.path === sourceReference.path)) {
		throw new Error('The source file has not synchronized to Google Drive yet.');
	}
	return { entry, sourcePath: sourceReference.path, files };
}

async function sharedItemID(captureID) {
	if (validSharedUserID(captureID)) return captureID.toLowerCase();
	return (await sha256Hex(captureID)).slice(0, 32);
}

async function sharingReferenceForItem(env, email, tree, itemID) {
	const file = tree.files.get(`shares/${itemID}.json`);
	if (!file) return null;
	try {
		const reference = JSON.parse(
			new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
		);
		return reference?.schemaVersion === 2 &&
			reference.id === itemID &&
			reference.itemID === itemID &&
			reference.contentPath === `library/${itemID}.source.md` &&
			Array.isArray(reference.sharedWithIDs)
			? reference
			: null;
	} catch {
		throw new Error('The sharing record for this document is invalid.');
	}
}

async function sharedItemContext(env, email, connection, captureID, includePersonalFiles = false) {
	const itemID = await sharedItemID(captureID);
	const [personal, tree] = await Promise.all([
		loadPersonalSharingItem(env, email, captureID, includePersonalFiles),
		shallowSharedTree(env, email, connection.folder_id)
	]);
	const [people, reference] = await Promise.all([
		loadSharedPeople(env, email, tree),
		sharingReferenceForItem(env, email, tree, itemID)
	]);
	return { itemID, personal, tree, people, reference };
}

function sharedCompanionPaths(itemID) {
	return [
		`library/${itemID}.source.md`,
		`library/${itemID}.brief.md`,
		`library/${itemID}.concise.md`,
		`library/${itemID}.detailed.md`,
		`library/${itemID}.comprehensive.md`
	];
}

async function sharingOperation(env, email, captureID) {
	return env.DB.prepare(
		`SELECT capture_id, recipient_ids, generation, status, attempt_count, last_error, updated_at
		 FROM sharing_operations
		 WHERE user_email = ? AND capture_id = ?`
	)
		.bind(email, captureID)
		.first();
}

function sharingOperationRecipientIDs(operation) {
	try {
		const values = JSON.parse(operation?.recipient_ids ?? '[]');
		return Array.isArray(values) ? values.filter(validSharedUserID) : [];
	} catch {
		return [];
	}
}

async function enqueueSharingOperation(env, email, captureID, recipientIDs) {
	const now = new Date().toISOString();
	const generation = crypto.randomUUID();
	await env.DB.prepare(
		`INSERT INTO sharing_operations (
			user_email, capture_id, recipient_ids, generation, status,
			attempt_count, last_error, created_at, updated_at
		) VALUES (?, ?, ?, ?, 'queued', 0, NULL, ?, ?)
		ON CONFLICT(user_email, capture_id) DO UPDATE SET
			recipient_ids = excluded.recipient_ids,
			generation = excluded.generation,
			status = CASE
				WHEN sharing_operations.status = 'syncing' THEN 'syncing'
				ELSE 'queued'
			END,
			attempt_count = 0,
			last_error = NULL,
			updated_at = excluded.updated_at`
	)
		.bind(email, captureID, JSON.stringify(recipientIDs), generation, now, now)
		.run();
	return sharingOperation(env, email, captureID);
}

function scheduleSharingOperation(context, task) {
	if (context && typeof context.waitUntil === 'function') {
		context.waitUntil(task);
		return;
	}
	void task.catch(() => {});
}

async function performSharedItemUpdate(env, email, captureID, requestedIDs) {
	const connection = await sharedFolderConnection(env, email);
	if (!connection) throw new Error('Connect the shared folder first.');
	const { itemID, personal, tree, people, reference: existing } = await sharedItemContext(
		env,
		email,
		connection,
		captureID,
		true
	);
	const peopleByID = new Map(people.map((person) => [person.userID, person]));
	const recipients = requestedIDs
		.filter((id) => id !== connection.user_id)
		.map((id) => peopleByID.get(id));
	if (recipients.some((person) => !person)) {
		throw new Error('One or more people are no longer available in the shared folder.');
	}
	recipients.sort((a, b) => a.username.localeCompare(b.username));
	if (existing && existing.sharedByID !== connection.user_id) {
		throw new Error('This shared item is owned by another person.');
	}
	const now = new Date().toISOString();
	const referencePath = `shares/${itemID}.json`;
	const companionPaths = sharedCompanionPaths(itemID);
	if (recipients.length === 0) {
		await Promise.all(
			[referencePath, ...companionPaths]
				.map((path) => tree.files.get(path))
				.filter(Boolean)
				.map((file) => trashDriveFile(env, email, file.id))
		);
		return {
			shared: false,
			recipientIDs: [],
			people: people.filter((person) => person.userID !== connection.user_id)
		};
	}

	const personalFiles = new Map(personal.files.map((item) => [item.path, item.file]));
	const desired = [];
	for (const text of personal.entry.texts ?? []) {
		if (
			!['source', 'brief', 'concise', 'detailed', 'comprehensive'].includes(text?.variant) ||
			typeof text?.path !== 'string'
		) {
			continue;
		}
		const file = personalFiles.get(text.path);
		if (!file) continue;
		desired.push({
			path: `library/${itemID}.${text.variant}.md`,
			file
		});
	}
	if (!desired.some((item) => item.path === `library/${itemID}.source.md`)) {
		throw new Error('The source file has not synchronized to Google Drive yet.');
	}
	const desiredPaths = new Set(desired.map((item) => item.path));
	await Promise.all(
		companionPaths
			.filter((path) => !desiredPaths.has(path))
			.map((path) => tree.files.get(path))
			.filter(Boolean)
			.map((file) => trashDriveFile(env, email, file.id))
	);
	await ensureDrivePath(env, email, connection.folder_id, tree.folders, 'library');
	await ensureDrivePath(env, email, connection.folder_id, tree.folders, 'shares');
	for (const item of desired) {
		const bytes = await downloadDriveFile(env, email, item.file.id);
		await upsertDriveFile(env, email, {
			rootFolderID: connection.folder_id,
			folders: tree.folders,
			path: item.path,
			bytes,
			existingID: tree.files.get(item.path)?.id ?? null
		});
	}

	const sharedReference = {
		schemaVersion: 2,
		id: itemID,
		itemID,
		contentPath: `library/${itemID}.source.md`,
		sourceFilename: personal.sourcePath.split('/').at(-1),
		sharedByID: connection.user_id,
		sharedWithIDs: recipients.map((person) => person.userID),
		revision: (existing?.revision ?? 0) + 1,
		createdAt: existing?.createdAt ?? now,
		updatedAt: now
	};
	const referenceBytes = new TextEncoder().encode(JSON.stringify(sharedReference, null, 2));
	await upsertDriveFile(env, email, {
		rootFolderID: connection.folder_id,
		folders: tree.folders,
		path: referencePath,
		bytes: referenceBytes,
		existingID: tree.files.get(referencePath)?.id ?? null
	});
	return {
		shared: true,
		referenceID: itemID,
		recipientIDs: recipients.map((person) => person.userID),
		people: people.filter((person) => person.userID !== connection.user_id)
	};
}

async function processSharingOperation(env, email, captureID) {
	for (let iteration = 0; iteration < 4; iteration += 1) {
		const operation = await sharingOperation(env, email, captureID);
		if (!operation || operation.status === 'failed' || operation.status === 'syncing') return;
		const generation = operation.generation;
		const startedAt = new Date().toISOString();
		const claim = await env.DB.prepare(
			`UPDATE sharing_operations
			 SET status = 'syncing', attempt_count = attempt_count + 1, updated_at = ?
			 WHERE user_email = ? AND capture_id = ? AND generation = ? AND status = 'queued'`
		)
			.bind(startedAt, email, captureID, generation)
			.run();
		if (Number(claim?.meta?.changes ?? 0) === 0) return;

		try {
			await performSharedItemUpdate(
				env,
				email,
				captureID,
				sharingOperationRecipientIDs(operation)
			);
			const completed = await env.DB.prepare(
				`DELETE FROM sharing_operations
				 WHERE user_email = ? AND capture_id = ? AND generation = ?`
			)
				.bind(email, captureID, generation)
				.run();
			if (Number(completed?.meta?.changes ?? 0) > 0) return;
			await env.DB.prepare(
				`UPDATE sharing_operations
				 SET status = 'queued', updated_at = ?
				 WHERE user_email = ? AND capture_id = ? AND status = 'syncing'`
			)
				.bind(new Date().toISOString(), email, captureID)
				.run();
		} catch (error) {
			const message =
				error instanceof Error ? error.message : 'The document could not be shared.';
			const failed = await env.DB.prepare(
				`UPDATE sharing_operations
				 SET status = 'failed', last_error = ?, updated_at = ?
				 WHERE user_email = ? AND capture_id = ? AND generation = ?`
			)
				.bind(message, new Date().toISOString(), email, captureID, generation)
				.run();
			if (Number(failed?.meta?.changes ?? 0) > 0) return;
			await env.DB.prepare(
				`UPDATE sharing_operations
				 SET status = 'queued', updated_at = ?
				 WHERE user_email = ? AND capture_id = ? AND status = 'syncing'`
			)
				.bind(new Date().toISOString(), email, captureID)
				.run();
		}
	}
}

async function resumeSharingOperation(env, email, captureID, operation, context) {
	let resumable = operation;
	if (
		resumable?.status === 'syncing' &&
		Date.now() - Date.parse(resumable.updated_at ?? '') > 2 * 60 * 1000
	) {
		await env.DB.prepare(
			`UPDATE sharing_operations
			 SET status = 'queued', updated_at = ?
			 WHERE user_email = ? AND capture_id = ? AND generation = ? AND status = 'syncing'`
		)
			.bind(new Date().toISOString(), email, captureID, resumable.generation)
			.run();
		resumable = await sharingOperation(env, email, captureID);
	}
	if (resumable?.status === 'queued') {
		scheduleSharingOperation(context, processSharingOperation(env, email, captureID));
	}
	return resumable;
}

async function sharedItemStatus(request, env, context) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect the shared folder first.' }, { status: 409 });
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	const pending = await resumeSharingOperation(
		env,
		email,
		captureID,
		await sharingOperation(env, email, captureID),
		context
	);
	try {
		const itemContext = await sharedItemContext(env, email, connection, captureID);
		const pendingRecipientIDs = pending
			? sharingOperationRecipientIDs(pending)
			: null;
		return json({
			shared: pending ? pendingRecipientIDs.length > 0 : Boolean(itemContext.reference),
			referenceID: itemContext.reference?.id,
			recipientIDs: pendingRecipientIDs ?? itemContext.reference?.sharedWithIDs ?? [],
			people: itemContext.people.filter((person) => person.userID !== connection.user_id),
			operationStatus: pending?.status,
			operationError: pending?.last_error ?? undefined
		});
	} catch (error) {
		if (pending) {
			const recipientIDs = sharingOperationRecipientIDs(pending);
			return json({
				shared: recipientIDs.length > 0,
				recipientIDs,
				people: [],
				operationStatus: pending.status,
				operationError:
					pending.last_error ??
					(error instanceof Error ? error.message : 'Sharing details could not be refreshed.')
			});
		}
		return json(
			{ error: error instanceof Error ? error.message : 'Sharing details could not be loaded.' },
			{ status: 400 }
		);
	}
}

async function sharedOperationStatus(request, env, context) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	const operation = await resumeSharingOperation(
		env,
		email,
		captureID,
		await sharingOperation(env, email, captureID),
		context
	);
	if (!operation) return json({ status: 'complete' });
	return json({
		status: operation.status,
		error: operation.last_error ?? undefined
	});
}

async function updateSharedItem(request, env, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect the shared folder first.' }, { status: 409 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid sharing request.' }, { status: 400 });
	}
	const captureID = value?.captureID;
	if (!validCaptureIdentifier(captureID) || !Array.isArray(value?.recipientIDs)) {
		return json({ error: 'Choose a valid document and recipients.' }, { status: 400 });
	}
	const requestedIDs = [...new Set(value.recipientIDs)];
	if (requestedIDs.length > 100 || requestedIDs.some((id) => !validSharedUserID(id))) {
		return json({ error: 'One or more sharing recipients are invalid.' }, { status: 400 });
	}
	const recipientIDs = requestedIDs.filter((id) => id !== connection.user_id);
	const operation = await enqueueSharingOperation(env, email, captureID, recipientIDs);
	scheduleSharingOperation(context, processSharingOperation(env, email, captureID));
	return json(
		{
			shared: recipientIDs.length > 0,
			referenceID: recipientIDs.length > 0 ? await sharedItemID(captureID) : undefined,
			recipientIDs,
			people: [],
			operationStatus: operation?.status === 'syncing' ? 'syncing' : 'queued'
		},
		{ status: 202 }
	);
}

async function loadSharedInboxProjection(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) {
		return json({ schemaVersion: 3, generatedAt: new Date().toISOString(), files: [], entries: [] });
	}
	try {
		const [tree, inboxContext] = await Promise.all([
			shallowSharedTree(env, email, connection.folder_id),
			loadPersonalInboxState(env, email)
		]);
		const people = await loadSharedPeople(env, email, tree);
		const usernames = new Map(people.map((person) => [person.userID, person.username]));
		const referenceFiles = [...tree.files.values()].filter(
			(file) => file.path.startsWith('shares/') && file.path.endsWith('.json')
		);
		const references = (
			await Promise.all(
				referenceFiles.map(async (file) => {
					try {
						const reference = JSON.parse(
							new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
						);
						if (
							reference?.schemaVersion === 2 &&
							validSharedUserID(reference.id) &&
							reference.itemID === reference.id &&
							reference.contentPath === `library/${reference.itemID}.source.md` &&
							Array.isArray(reference.sharedWithIDs) &&
							reference.sharedWithIDs.includes(connection.user_id)
						) {
							return reference;
						}
					} catch {
						// Malformed records are excluded from the derived Inbox.
					}
					return null;
				})
			)
		).filter(Boolean);
		const pendingReferences = references.filter((reference) => {
			const decision = inboxContext.state.shares?.[reference.id];
			return !decision || Number(decision.handledRevision ?? 0) < Number(reference.revision ?? 0);
		});
		const entries = (
			await Promise.all(
				pendingReferences.map(async (reference) => {
					const source = tree.files.get(reference.contentPath);
					if (!source) return null;
					const sourceText = new TextDecoder().decode(
						await downloadDriveFile(env, email, source.id)
					);
					const metadata = parsedMarkdownDocument(
						sourceText,
						String(reference.sourceFilename ?? reference.itemID).replace(/\.[^.]+$/, '')
					);
					const texts = await Promise.all(
						['brief', 'concise', 'detailed', 'comprehensive'].map(async (variant) => {
							const summary = tree.files.get(`library/${reference.itemID}.${variant}.md`);
							if (!summary) return null;
							return {
								variant,
								text: new TextDecoder().decode(
									await downloadDriveFile(env, email, summary.id)
								)
							};
						})
					);
					texts.push({ variant: 'source', text: metadata.body });
					return {
						id: `shared:${reference.id}`,
						captureID: metadata.captureID,
						title: metadata.title,
						excerpt: metadata.excerpt,
						topicIDs: metadata.topicIDs,
						topicNames: metadata.topicNames,
						tags: metadata.tags,
						sourceURL: metadata.sourceURL,
						createdAt: metadata.createdAt ?? reference.createdAt,
						updatedAt: reference.updatedAt,
						origin: 'shared',
						sharedByUsername: usernames.get(reference.sharedByID),
						inboxReferenceID: reference.id,
						texts: texts.filter(Boolean)
					};
				})
			)
		).filter(Boolean);
		entries.sort((a, b) => String(b.updatedAt ?? '').localeCompare(String(a.updatedAt ?? '')));
		return json({
			schemaVersion: 3,
			generatedAt: new Date().toISOString(),
			files: [],
			entries
		});
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The shared Inbox could not be loaded.' },
			{ status: 502 }
		);
	}
}

async function loadPersonalInboxState(env, email) {
	const rootFolderID = await ensureDriveRootFolder(env, email);
	const folders = new Map([['', rootFolderID]]);
	const rootChildren = await driveFolderChildren(env, email, rootFolderID);
	const controlFolder = rootChildren.find(
		(item) =>
			item.name === '.shared-library' &&
			item.mimeType === 'application/vnd.google-apps.folder'
	);
	let file = null;
	if (controlFolder) {
		folders.set('.shared-library', controlFolder.id);
		file = (await driveFolderChildren(env, email, controlFolder.id)).find(
			(item) =>
				item.name === 'inbox-state.json' &&
				item.mimeType !== 'application/vnd.google-apps.folder'
		) ?? null;
	}
	let state = {
		schemaVersion: 1,
		shares: {},
		updatedAt: new Date().toISOString()
	};
	if (file) {
		try {
			const value = JSON.parse(
				new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
			);
			if (value?.schemaVersion !== 1 || typeof value.shares !== 'object' || !value.shares) {
				throw new Error('The personal Inbox state is invalid.');
			}
			state = value;
		} catch (error) {
			throw new Error(
				error instanceof Error ? error.message : 'The personal Inbox state is invalid.'
			);
		}
	}
	return { rootFolderID, folders, file, state };
}

async function markPersonalInbox(env, email, reference, disposition) {
	const context = await loadPersonalInboxState(env, email);
	const now = new Date().toISOString();
	context.state.shares[reference.id] = {
		disposition,
		handledRevision: Number(reference.revision ?? 0),
		updatedAt: now
	};
	context.state.updatedAt = now;
	await upsertDriveFile(env, email, {
		rootFolderID: context.rootFolderID,
		folders: context.folders,
		path: '.shared-library/inbox-state.json',
		bytes: new TextEncoder().encode(JSON.stringify(context.state, null, 2)),
		existingID: context.file?.id ?? null,
		kind: 'workspace'
	});
}

async function sharedReferenceByID(env, email, connection, referenceID) {
	const tree = await shallowSharedTree(env, email, connection.folder_id);
	const file = tree.files.get(`shares/${referenceID}.json`);
	if (!file) throw new Error('This Inbox item is no longer available.');
	const reference = JSON.parse(
		new TextDecoder().decode(await downloadDriveFile(env, email, file.id))
	);
	if (
		reference?.schemaVersion !== 2 ||
		reference.id !== referenceID ||
		reference.itemID !== referenceID ||
		!Array.isArray(reference.sharedWithIDs) ||
		!reference.sharedWithIDs.includes(connection.user_id)
	) {
		throw new Error('This Inbox reference is invalid.');
	}
	return { tree, reference };
}

async function dismissInboxReference(request, env, referenceID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect a shared folder first.' }, { status: 409 });
	try {
		const { reference } = await sharedReferenceByID(env, email, connection, referenceID);
		await markPersonalInbox(env, email, reference, 'dismissed');
		return json({ dismissed: true });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The Inbox item could not be dismissed.' },
			{ status: 400 }
		);
	}
}

/*
 * Inbox state deliberately lives in the recipient's personal workspace.
 * The shared folder contains only people.json, shares/*.json, and library/*.md.
 */

function rewriteCaptureID(sourceText, captureID, shareID, shareRevision) {
	if (!sourceText.startsWith('---')) return sourceText;
	const end = sourceText.indexOf('\n---', 3);
	if (end < 0) return sourceText;
	let updated = sourceText.slice(0, end);
	for (const [key, value] of [
		['id', captureID],
		['shared_from', shareID],
		['shared_revision', String(shareRevision)]
	]) {
		updated = new RegExp(`^${key}:`, 'm').test(updated)
			? updated.replace(new RegExp(`^${key}:.*$`, 'm'), `${key}: "${value}"`)
			: `${updated}\n${key}: "${value}"`;
	}
	return updated + sourceText.slice(end);
}

function personalWorkspacePath(path) {
	return (
		path === 'topics.md' ||
		path === '.shared-library/inbox-state.json' ||
		(path.startsWith('library/') && path.endsWith('.md'))
	);
}

async function driveFileByKind(env, email, kind) {
	const url = new URL('https://www.googleapis.com/drive/v3/files');
	url.searchParams.set(
		'q',
		`appProperties has { key='sharedLibraryKind' and value='${kind}' } and trashed=false`
	);
	url.searchParams.set('fields', 'files(id,name,mimeType,parents,appProperties)');
	url.searchParams.set('pageSize', '1');
	url.searchParams.set('supportsAllDrives', 'true');
	url.searchParams.set('includeItemsFromAllDrives', 'true');
	const response = await googleDriveRequest(env, email, url);
	if (!response.ok) throw new Error(`Google Drive could not find the library index (${response.status}).`);
	return (await response.json()).files?.[0] ?? null;
}

function wordCount(text) {
	return text.trim() ? text.trim().split(/\s+/).length : 0;
}

async function updatePersonalDriveIndexAfterImport(
	env,
	email,
	{ personalRootID, personalTree, copied, captureID, sourceDestination, sourceText }
) {
	const currentIndexFile = await driveFileByKind(env, email, 'library-index');
	let index = {
		schemaVersion: 3,
		generatedAt: new Date().toISOString(),
		files: [],
		entries: []
	};
	if (currentIndexFile) {
		try {
			const value = JSON.parse(
				new TextDecoder().decode(await downloadDriveFile(env, email, currentIndexFile.id))
			);
			if (
				value?.schemaVersion === 3 &&
				Array.isArray(value.files) &&
				Array.isArray(value.entries)
			) {
				index = value;
			}
		} catch {
			// A fresh index is safer than publishing malformed metadata.
		}
	}
	const copiedPaths = new Set(copied.map((file) => file.path));
	index.files = [
		...index.files.filter((file) => !copiedPaths.has(file.path)),
		...copied.map((file) => ({
			path: file.path,
			contentHash: file.contentHash,
			byteCount: file.byteCount
		}))
	].sort((a, b) => a.path.localeCompare(b.path));
	const metadata = parsedMarkdownDocument(
		sourceText,
		sourceDestination.split('/').at(-1)?.replace(/\.[^.]+$/, '') || 'Shared item'
	);
	const texts = [];
	for (const file of copied) {
		let variant;
		if (file.path === sourceDestination) variant = 'source';
		else if (file.path.includes('/summaries/brief/')) variant = 'brief';
		else if (file.path.includes('/summaries/concise/')) variant = 'concise';
		else if (file.path.includes('/summaries/detailed/')) variant = 'detailed';
		else if (file.path.includes('/summaries/comprehensive/')) variant = 'comprehensive';
		else if (file.path.includes('/summaries/')) variant = 'concise';
		if (!variant || texts.some((text) => text.variant === variant)) continue;
		const text =
			variant === 'source'
				? metadata.body
				: new TextDecoder().decode(file.bytes);
		texts.push({
			variant,
			path: file.path,
			contentHash: file.contentHash,
			wordCount: wordCount(text)
		});
	}
	const entry = {
		id: `personal:${captureID}`,
		captureID,
		title: metadata.title,
		excerpt: metadata.excerpt,
		topicIDs: metadata.topicIDs,
		topicNames: metadata.topicNames,
		tags: metadata.tags,
		sourceURL: metadata.sourceURL,
		createdAt: metadata.createdAt,
		updatedAt: new Date().toISOString(),
		origin: 'personal',
		texts
	};
	index.entries = [
		...index.entries.filter(
			(candidate) => candidate.id !== entry.id && candidate.captureID !== captureID
		),
		entry
	].sort((a, b) => String(b.updatedAt ?? b.createdAt ?? '').localeCompare(
		String(a.updatedAt ?? a.createdAt ?? '')
	));
	index.schemaVersion = 3;
	index.generatedAt = new Date().toISOString();
	await upsertDriveFile(env, email, {
		rootFolderID: personalRootID,
		folders: personalTree.folders,
		path: '.shared-library/index.json',
		bytes: new TextEncoder().encode(JSON.stringify(index, null, 2)),
		existingID: currentIndexFile?.id ?? null,
		kind: 'library-index'
	});
}

async function storeDriveAudioBytes(env, email, hash, bytes, contentType) {
	const existing = await findDriveMedia(env, email, { kind: 'audio', hash });
	if (existing.response) {
		throw new Error(`Google Drive narration lookup failed (${existing.response.status}).`);
	}
	if (existing.file) return existing.file.id;
	const folderID = await ensureDriveMediaFolder(env, email);
	const metadata = JSON.stringify({
		name: `${hash}.mp3`,
		parents: [folderID],
		appProperties: {
			sharedLibraryHash: hash,
			sharedLibraryKind: 'audio'
		}
	});
	const boundary = `SharedLibrary-${crypto.randomUUID()}`;
	const body = new Blob([
		`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n`,
		metadata,
		`\r\n--${boundary}\r\nContent-Type: ${contentType}\r\n\r\n`,
		bytes,
		`\r\n--${boundary}--\r\n`
	]);
	const response = await googleDriveRequest(
		env,
		email,
		'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id',
		{
			method: 'POST',
			headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
			body
		}
	);
	if (!response.ok) {
		throw new Error(`Google Drive narration upload failed (${response.status}).`);
	}
	return (await response.json()).id;
}

async function copyShareAudioToDrive(env, email, token, generation) {
	if (!env.SHARE_MEDIA) return;
	const result = await env.DB.prepare(
		`SELECT audio_hash, r2_key, content_type FROM share_audio_segments
		 WHERE share_token = ? AND generation = ?
		 ORDER BY variant, segment_index`
	)
		.bind(token, generation)
		.all();
	for (const segment of result.results ?? []) {
		const object = await env.SHARE_MEDIA.get(segment.r2_key);
		if (!object) continue;
		const bytes = new Uint8Array(await object.arrayBuffer());
		await storeDriveAudioBytes(
			env,
			email,
			segment.audio_hash,
			bytes,
			segment.content_type || 'audio/mpeg'
		);
	}
}

async function importPublicShare(request, env, token, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const record = await shareLinkByToken(env, token);
	if (!record || record.status !== 'ready') {
		return json({ error: 'This share link is no longer available.' }, { status: 404 });
	}
	try {
		const textResult = await env.DB.prepare(
			`SELECT variant, markdown FROM share_texts
			 WHERE share_token = ? AND generation = ?`
		)
			.bind(token, record.generation)
			.all();
		const documents = new Map(
			(textResult.results ?? []).map((document) => [document.variant, document.markdown])
		);
		const sourceText = documents.get('source');
		if (!sourceText) throw new Error('The shared source document is unavailable.');
		const preference = await env.DB.prepare(
			`SELECT provider FROM sync_preferences WHERE user_email = ?`
		)
			.bind(email)
			.first();
		if (preference?.provider === 'icloud') {
			let metadata = {};
			try {
				metadata = JSON.parse(record.metadata_json ?? '{}');
			} catch {
				metadata = {};
			}
			const audio = await env.DB.prepare(
				`SELECT variant, segment_index, audio_hash, content_type, byte_count, voice
				 FROM share_audio_segments
				 WHERE share_token = ? AND generation = ?
				 ORDER BY variant, segment_index`
			)
				.bind(token, record.generation)
				.all();
			return json({
				provider: 'icloud',
				source: {
					token,
					revision: Number(record.revision ?? 1),
					filename: record.source_filename,
					metadata,
					texts: [...documents].map(([variant, markdown]) => ({ variant, markdown })),
					audio: (audio.results ?? []).map((segment) => ({
						...segment,
						url: `/api/public/shares/${token}/audio/${segment.variant}/${segment.segment_index}`
					}))
				}
			});
		}
		const personalRootID = await ensureDriveRootFolder(env, email);
		const personalTree = await driveFolderTree(
			env,
			email,
			personalRootID,
			personalWorkspacePath,
			true
		);
		const safeSourceFilename =
			typeof record.source_filename === 'string' &&
			/^[^/\\]+\.md$/i.test(record.source_filename)
				? record.source_filename
				: `${record.capture_id}.md`;
		const base = safeSourceFilename.replace(/\.[^.]+$/, '');
		const extension = safeSourceFilename.includes('.')
			? `.${safeSourceFilename.split('.').at(-1)}`
			: '.md';
		let filename = safeSourceFilename;
		for (let index = 1; personalTree.files.has(`library/${filename}`); index += 1) {
			filename = `${base}${index === 1 ? '-shared' : `-shared-${index}`}${extension}`;
		}
		const captureID = crypto.randomUUID().toLowerCase();
		const rewrittenSource = new TextEncoder().encode(
			rewriteCaptureID(sourceText, captureID, token, record.revision)
		);
		const sourceDestination = `library/${filename}`;
		const copied = [
			{
				path: sourceDestination,
				bytes: rewrittenSource,
				...(await upsertDriveFile(env, email, {
					rootFolderID: personalRootID,
					folders: personalTree.folders,
					path: sourceDestination,
					bytes: rewrittenSource,
					kind: 'workspace'
				}))
			}
		];
		for (const variant of ['brief', 'concise', 'detailed', 'comprehensive']) {
			const markdown = documents.get(variant);
			if (typeof markdown !== 'string') continue;
			const destination = `library/summaries/${variant}/${filename}`;
			const bytes = new TextEncoder().encode(markdown);
			copied.push({
				path: destination,
				bytes,
				...(await upsertDriveFile(env, email, {
					rootFolderID: personalRootID,
					folders: personalTree.folders,
					path: destination,
					bytes,
					kind: 'workspace'
				}))
			});
		}
		await updatePersonalDriveIndexAfterImport(env, email, {
			personalRootID,
			personalTree,
			copied,
			captureID,
			sourceDestination,
			sourceText: new TextDecoder().decode(rewrittenSource)
		});
		scheduleSharingOperation(
			context,
			copyShareAudioToDrive(env, email, token, record.generation)
		);
		return json({ saved: true, path: sourceDestination, captureID });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The shared document could not be saved.' },
			{ status: 400 }
		);
	}
}

async function saveInboxReference(request, env, referenceID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	await ensureSchema(env.DB);
	const connection = await sharedFolderConnection(env, email);
	if (!connection) return json({ error: 'Connect a shared folder first.' }, { status: 409 });
	try {
		const { tree: sharedTree, reference } = await sharedReferenceByID(
			env,
			email,
			connection,
			referenceID
		);
		const sourceFile = sharedTree.files.get(reference.contentPath);
		if (!sourceFile) throw new Error('The shared source file is no longer available.');
		const personalRootID = await ensureDriveRootFolder(env, email);
		const personalTree = await driveFolderTree(
			env,
			email,
			personalRootID,
			personalWorkspacePath,
			true
		);
		const originalFilename =
			typeof reference.sourceFilename === 'string' &&
			/^[^/]+\.md$/i.test(reference.sourceFilename)
				? reference.sourceFilename
				: `${reference.itemID}.md`;
		const base = originalFilename.replace(/\.[^.]+$/, '');
		const extension = originalFilename.includes('.') ? `.${originalFilename.split('.').at(-1)}` : '';
		let filename = originalFilename;
		for (let index = 1; personalTree.files.has(`library/${filename}`); index += 1) {
			filename = `${base}${index === 1 ? '-shared' : `-shared-${index}`}${extension}`;
		}
		const captureID = crypto.randomUUID().toLowerCase();
		const copied = [];
		const sourceBytes = await downloadDriveFile(env, email, sourceFile.id);
		const rewrittenSource = new TextEncoder().encode(
			rewriteCaptureID(
				new TextDecoder().decode(sourceBytes),
				captureID,
				reference.id,
				reference.revision
			)
		);
		const sourceDestination = `library/${filename}`;
		copied.push({
			path: sourceDestination,
			bytes: rewrittenSource,
			...(await upsertDriveFile(env, email, {
				rootFolderID: personalRootID,
				folders: personalTree.folders,
				path: sourceDestination,
				bytes: rewrittenSource,
				kind: 'workspace'
			}))
		});
		for (const variant of ['brief', 'concise', 'detailed', 'comprehensive']) {
			const sourcePath = `library/${reference.itemID}.${variant}.md`;
			const summary = sharedTree.files.get(sourcePath);
			if (!summary) continue;
			const destination = `library/summaries/${variant}/${filename}`;
			const bytes = await downloadDriveFile(env, email, summary.id);
			copied.push({
				path: destination,
				bytes,
				...(await upsertDriveFile(env, email, {
					rootFolderID: personalRootID,
					folders: personalTree.folders,
					path: destination,
					bytes,
					kind: 'workspace'
				}))
			});
		}
		await updatePersonalDriveIndexAfterImport(env, email, {
			personalRootID,
			personalTree,
			copied,
			captureID,
			sourceDestination,
			sourceText: new TextDecoder().decode(rewrittenSource)
		});
		await markPersonalInbox(env, email, reference, 'saved');
		return json({ saved: true, path: sourceDestination, captureID });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The Inbox item could not be saved.' },
			{ status: 400 }
		);
	}
}

const worker = {
	async fetch(request, env, context) {
		const url = new URL(request.url);
		const publicShare = url.pathname.match(
			/^\/api\/public\/shares\/([A-Za-z0-9_-]{32})$/
		);
		if (publicShare && request.method === 'GET') {
			return publicShareDocument(request, env, publicShare[1]);
		}
		const publicShareImport = url.pathname.match(
			/^\/api\/public\/shares\/([A-Za-z0-9_-]{32})\/import$/
		);
		if (publicShareImport && request.method === 'POST') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return importPublicShare(request, env, publicShareImport[1], context);
		}
		if (url.pathname === '/api/auth/status' && request.method === 'GET') {
			return accountStatus(request, env);
		}
		if (url.pathname === '/api/auth/google/start' && request.method === 'GET') {
			return startGoogleLogin(request, env);
		}
		if (url.pathname === '/api/auth/google/callback' && request.method === 'GET') {
			return finishGoogleLogin(request, env);
		}
		if (url.pathname === '/api/auth/apple/start' && request.method === 'GET') {
			return startAppleLogin(request, env);
		}
		if (url.pathname === '/api/auth/apple/callback' && request.method === 'POST') {
			return finishAppleLogin(request, env);
		}
		if (url.pathname === '/api/auth/logout' && request.method === 'POST') {
			return signOut(request, env);
		}
		if (url.pathname === '/api/feedback' && request.method === 'GET') {
			return feedbackBoard(request, env);
		}
		if (url.pathname === '/api/feedback' && request.method === 'POST') {
			return createFeedback(request, env);
		}
		const feedbackUpvote = url.pathname.match(
			/^\/api\/feedback\/([0-9a-f-]{36})\/upvote$/
		);
		if (feedbackUpvote && request.method === 'PUT') {
			return setFeedbackUpvote(request, env, feedbackUpvote[1]);
		}
		if (url.pathname === '/api/billing/status' && request.method === 'GET') {
			return billingStatus(request, env);
		}
		if (url.pathname === '/api/billing/checkout' && request.method === 'POST') {
			return createCheckoutSession(request, env);
		}
		if (url.pathname === '/api/billing/portal' && request.method === 'POST') {
			return createBillingPortalSession(request, env);
		}
		if (url.pathname === '/api/billing/webhook' && request.method === 'POST') {
			return stripeWebhook(request, env);
		}
		if (url.pathname === '/api/library' && request.method === 'GET') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return fetchLibrarySnapshot(request, env);
		}
		if (url.pathname === '/api/library/file' && request.method === 'GET') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return fetchLibraryFile(request, env);
		}
		if (url.pathname === '/api/library/sync' && request.method === 'POST') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return syncLibraryMirror(request, env);
		}
		if (url.pathname === '/api/share-links' && request.method === 'GET') {
			return ownerShareLinkStatus(request, env);
		}
		if (url.pathname === '/api/share-links' && request.method === 'POST') {
			const denied = await paidAccessResponse(request, env);
			if (denied) return denied;
			return publishShareLink(request, env, context);
		}
		const ownerShare = url.pathname.match(/^\/api\/share-links\/([A-Za-z0-9_-]{32})$/);
		if (ownerShare && request.method === 'DELETE') {
			return revokeShareLink(request, env, ownerShare[1], context);
		}
		if (url.pathname === '/api/google/status' && request.method === 'GET') {
			return googleDriveStatus(request, env);
		}
		if (url.pathname === '/api/google/connect/start' && request.method === 'GET') {
			return startGoogleDriveConnection(request, env);
		}
		if (url.pathname === '/api/google/connect/callback' && request.method === 'GET') {
			return finishGoogleDriveConnection(request, env);
		}
		if (url.pathname === '/api/google/disconnect' && request.method === 'POST') {
			return disconnectGoogleDrive(request, env);
		}
		if (url.pathname === '/api/icloud/config' && request.method === 'GET') {
			return iCloudConfiguration(request, env);
		}
		if (url.pathname === '/api/icloud/disconnect' && request.method === 'POST') {
			return disconnectICloud(request, env);
		}
		if (url.pathname === '/api/sync/provider' && request.method === 'POST') {
			return setSyncProvider(request, env);
		}
		if (url.pathname.startsWith('/api/')) {
			return json({ error: 'Not found.' }, { status: 404 });
		}

		const response = await env.ASSETS.fetch(request);
		if (response.status !== 404 || request.method !== 'GET') return response;
		const acceptsHTML = request.headers.get('accept')?.includes('text/html') ?? false;
		if (!acceptsHTML) return response;
		return env.ASSETS.fetch(new Request(new URL('/', request.url), request));
	},
	async scheduled(_controller, env, context) {
		context.waitUntil(
			Promise.all([
				reconcileStripeSubscriptions(env),
				releaseStaleTTSReservations(env)
			])
		);
	}
};

export default worker;
