import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';
import worker from './index.js';

class MockStatement {
	constructor(database, sql) {
		this.database = database;
		this.sql = sql;
		this.arguments = [];
	}

	bind(...values) {
		this.arguments = values;
		return this;
	}

		async first() {
			if (this.sql.includes('AS claimed')) {
				const tierKey = this.arguments[0];
				const now = Number(this.arguments[2]);
				const allocations = [...this.database.billingAllocations.values()].filter(
					(record) => record.tier_key === tierKey
				).length;
				const reservations = [...this.database.checkoutReservations.values()].filter(
					(record) => record.tier_key === tierKey && record.expires_at > now
				).length;
				return { claimed: allocations + reservations };
			}
			if (this.sql.includes('FROM billing_customers c')) {
				const customer = this.database.billingCustomers.get(this.arguments[0]);
				if (!customer) return null;
				const subscription = this.database.billingSubscriptions.get(customer.account_id);
				return { ...customer, ...(subscription ?? {}) };
			}
			if (this.sql.includes('FROM billing_checkout_reservations')) {
				if (this.sql.includes('WHERE reservation_id = ?')) {
					return (
						[...this.database.checkoutReservations.values()].find(
							(record) => record.reservation_id === this.arguments[0]
						) ?? null
					);
				}
				return this.database.checkoutReservations.get(this.arguments[0]) ?? null;
			}
			if (this.sql.includes('FROM openrouter_oauth_states')) {
			return this.database.pendingOAuthState;
		}
		if (this.sql.includes('FROM openrouter_credentials')) {
			return this.database.credential;
		}
		if (this.sql.includes('FROM share_links')) {
			if (this.sql.includes('owner_email = ? AND capture_id = ?')) {
				return (
					[...this.database.shareLinks.values()].find(
						(record) =>
							record.owner_email === this.arguments[0] &&
							record.capture_id === this.arguments[1]
					) ?? null
				);
			}
			return this.database.shareLinks.get(this.arguments[0]) ?? null;
		}
			if (this.sql.includes('FROM stripe_webhook_events')) {
				return this.database.stripeWebhookEvents.get(this.arguments[0]) ?? null;
			}
			if (this.sql.includes('FROM app_sessions')) {
				return {
					user_email: 'reader@example.com',
					expires_at: Date.now() + 60_000
				};
			}
		return null;
	}

	async all() {
		if (this.sql.includes('FROM share_texts')) {
			return {
				results: this.database.shareTexts.filter(
					(row) =>
						row.share_token === this.arguments[0] &&
						(this.arguments.length < 2 || row.generation === this.arguments[1])
				)
			};
		}
		if (this.sql.includes('FROM share_audio_segments')) {
			return {
				results: this.database.shareAudioSegments.filter(
					(row) =>
						row.share_token === this.arguments[0] &&
						(this.arguments.length < 2 || row.generation === this.arguments[1])
				)
			};
		}
		return { results: [] };
	}

	async run() {
		let changes = 0;
			if (this.sql.includes('INSERT INTO openrouter_oauth_states')) {
			this.database.oauthState = {
				state: this.arguments[0],
				userEmail: this.arguments[1],
				verifier: this.arguments[2],
				createdAt: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('DELETE FROM openrouter_credentials')) {
			this.database.credential = null;
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO openrouter_credentials')) {
			this.database.savedCredential = {
				userEmail: this.arguments[0],
				encryptedAPIKey: this.arguments[1],
				initializationVector: this.arguments[2],
				openRouterUserID: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO share_links')) {
			const existing = [...this.database.shareLinks.values()].find(
				(record) =>
					record.owner_email === this.arguments[1] &&
					record.capture_id === this.arguments[2]
			);
			const record = {
				token: existing?.token ?? this.arguments[0],
				owner_email: this.arguments[1],
				capture_id: this.arguments[2],
				generation: this.arguments[3],
				revision: (existing?.revision ?? 0) + 1,
				status: 'preparing',
				metadata_json: existing?.metadata_json ?? null,
				source_filename: existing?.source_filename ?? null,
				voice: this.arguments[4],
				error_message: null,
				created_at: existing?.created_at ?? this.arguments[5],
				updated_at: this.arguments[6]
			};
			this.database.shareLinks.set(record.token, record);
			changes = 1;
		}
		if (this.sql.includes("SET status = 'failed'")) {
			const record = this.database.shareLinks.get(this.arguments[2]);
			if (record && record.generation === this.arguments[3]) {
				record.status = 'failed';
				record.error_message = this.arguments[0];
				record.updated_at = this.arguments[1];
				changes = 1;
			}
		}
			if (this.sql.includes('INSERT OR IGNORE INTO billing_customers')) {
				const [userEmail, accountID, createdAt, updatedAt] = this.arguments;
				if (!this.database.billingCustomers.has(userEmail)) {
					this.database.billingCustomers.set(userEmail, {
						user_email: userEmail,
						account_id: accountID,
						stripe_customer_id: null,
						created_at: createdAt,
						updated_at: updatedAt
					});
					changes = 1;
				}
			}
			if (
				this.sql.includes('DELETE FROM billing_checkout_reservations') &&
				this.sql.includes('expires_at <= ?')
			) {
				for (const [accountID, reservation] of this.database.checkoutReservations) {
					if (reservation.expires_at <= Number(this.arguments[0])) {
						this.database.checkoutReservations.delete(accountID);
						changes += 1;
					}
				}
			}
			if (this.sql.includes('INSERT OR IGNORE INTO billing_checkout_reservations')) {
				const [reservationID, accountID, tierKey, expiresAt, createdAt] = this.arguments;
				if (!this.database.checkoutReservations.has(accountID)) {
					this.database.checkoutReservations.set(accountID, {
						reservation_id: reservationID,
						account_id: accountID,
						tier_key: tierKey,
						stripe_session_id: null,
						expires_at: expiresAt,
						created_at: createdAt
					});
					changes = 1;
				}
			}
			if (
				this.sql.includes('UPDATE billing_checkout_reservations') &&
				this.sql.includes('SET stripe_session_id')
			) {
				const reservation = [...this.database.checkoutReservations.values()].find(
					(record) => record.reservation_id === this.arguments[1]
				);
				if (reservation) {
					reservation.stripe_session_id = this.arguments[0];
					changes = 1;
				}
			}
			if (
				this.sql.includes('DELETE FROM billing_checkout_reservations') &&
				this.sql.includes('reservation_id = ?')
			) {
				const entry = [...this.database.checkoutReservations.entries()].find(
					([, record]) => record.reservation_id === this.arguments[0]
				);
				if (entry) {
					this.database.checkoutReservations.delete(entry[0]);
					changes = 1;
				}
			}
			if (
				this.sql.includes('UPDATE billing_customers') &&
				this.sql.includes('SET stripe_customer_id')
			) {
				const customer = [...this.database.billingCustomers.values()].find(
					(record) => record.account_id === this.arguments[2]
				);
				if (customer) {
					customer.stripe_customer_id = this.arguments[0];
					customer.updated_at = this.arguments[1];
					changes = 1;
				}
			}
			if (this.sql.includes('INSERT INTO billing_subscriptions')) {
				const [
					accountID,
					subscriptionID,
					customerID,
					priceID,
					tierKey,
					status,
					statusChangedAt,
					stripeCreatedAt,
					currentPeriodEnd,
					cancelAtPeriodEnd,
					createdAt,
					updatedAt
				] = this.arguments;
				const existing = this.database.billingSubscriptions.get(accountID);
				if (!existing || stripeCreatedAt >= existing.stripe_created_at) {
					this.database.billingSubscriptions.set(accountID, {
						account_id: accountID,
						stripe_subscription_id: subscriptionID,
						stripe_customer_id: customerID,
						stripe_price_id: priceID,
						tier_key: tierKey,
						status,
						status_changed_at:
							existing?.status === status ? existing.status_changed_at : statusChangedAt,
						stripe_created_at: stripeCreatedAt,
						current_period_end: currentPeriodEnd,
						cancel_at_period_end: cancelAtPeriodEnd,
						created_at: existing?.created_at ?? createdAt,
						updated_at: updatedAt
					});
					changes = 1;
				}
			}
			if (this.sql.includes('INSERT OR IGNORE INTO billing_allocations')) {
				if (!this.database.billingAllocations.has(this.arguments[0])) {
					this.database.billingAllocations.set(this.arguments[0], {
						reservation_id: this.arguments[0],
						account_id: this.arguments[1],
						tier_key: this.arguments[2],
						allocated_at: this.arguments[3]
					});
					changes = 1;
				}
			}
			if (this.sql.includes('DELETE FROM share_links')) {
			const record = this.database.shareLinks.get(this.arguments[0]);
			if (record && record.owner_email === this.arguments[1]) {
				this.database.shareLinks.delete(this.arguments[0]);
				changes = 1;
			}
		}
			if (this.sql.includes('INSERT OR IGNORE INTO stripe_webhook_events')) {
				if (!this.database.stripeWebhookEvents.has(this.arguments[0])) {
					this.database.stripeWebhookEvents.set(this.arguments[0], {
						event_id: this.arguments[0],
						event_type: this.arguments[1],
						status: 'processing',
						attempts: 1,
						processed_at: this.arguments[2]
					});
					changes = 1;
				}
			}
			if (
				this.sql.includes('UPDATE stripe_webhook_events') &&
				this.sql.includes("SET status = 'processed'")
			) {
				const record = this.database.stripeWebhookEvents.get(this.arguments[1]);
				if (record?.status === 'processing') {
					record.status = 'processed';
					record.processed_at = this.arguments[0];
					changes = 1;
				}
			}
			if (
				this.sql.includes('DELETE FROM stripe_webhook_events') &&
				this.sql.includes("status = 'processing'")
			) {
				const record = this.database.stripeWebhookEvents.get(this.arguments[0]);
				if (record?.status === 'processing') {
					this.database.stripeWebhookEvents.delete(this.arguments[0]);
					changes = 1;
				}
			}
		return { success: true, meta: { changes } };
	}
}

class MockDatabase {
	credential = null;
	oauthState = null;
	pendingOAuthState = null;
	savedCredential = null;
	shareLinks = new Map();
	shareTexts = [];
	shareAudioSegments = [];
	stripeWebhookEvents = new Map();
	billingCustomers = new Map();
	billingSubscriptions = new Map();
	checkoutReservations = new Map();
	billingAllocations = new Map();

	prepare(sql) {
		return new MockStatement(this, sql);
	}

	async batch(statements) {
		for (const statement of statements) await statement.run();
		return statements.map(() => ({ success: true }));
	}
}

function environment(database = new MockDatabase()) {
	return {
		DB: database,
		OPENROUTER_CREDENTIAL_KEY: '0'.repeat(64),
		GOOGLE_DRIVE_WEB_CLIENT_ID:
			'123456789-sharedlibrary.apps.googleusercontent.com',
		GOOGLE_DRIVE_WEB_CLIENT_SECRET: 'central-google-secret',
		SHARED_LIBRARY_GROUP_FOLDER_ID: '1ConfiguredGroupFolder234567890',
		SHARE_PREPARE_RETRY_DELAY_MS: 0,
		ASSETS: {
			async fetch() {
				return new Response('asset', { status: 200 });
			}
		}
	};
}

function stripeEnvironment(database = new MockDatabase()) {
	return {
		...environment(database),
		STRIPE_SECRET_KEY: 'sk_test_briefly',
		STRIPE_WEBHOOK_SECRET: 'whsec_briefly_test',
		STRIPE_PRODUCT_PLUS: 'prod_briefly_plus',
		STRIPE_PORTAL_CONFIGURATION_ID: 'bpc_briefly_plus',
		STRIPE_PRICE_FOUNDING: 'price_founding',
		STRIPE_PRICE_EARLY: 'price_early',
		STRIPE_PRICE_GROWING: 'price_growing',
		STRIPE_PRICE_STANDARD: 'price_standard',
		BRIEFLY_BILLING_ENABLED: 'true'
	};
}

function authenticatedRequest(path, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Cookie', 'shared_library_session=test-session');
	return new Request(`https://library.example${path}`, { ...init, headers });
}

function base64URL(bytes) {
	return Buffer.from(bytes)
		.toString('base64')
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/g, '');
}

async function encryptedOpenRouterCredential(apiKey) {
	const initializationVector = new Uint8Array(12).fill(7);
	const key = await crypto.subtle.importKey(
		'raw',
		new Uint8Array(32),
		{ name: 'AES-GCM' },
		false,
		['encrypt']
	);
	const encrypted = await crypto.subtle.encrypt(
		{ name: 'AES-GCM', iv: initializationVector },
		key,
		new TextEncoder().encode(apiKey)
	);
	return {
		encrypted_api_key: base64URL(new Uint8Array(encrypted)),
		initialization_vector: base64URL(initializationVector)
	};
}

function signedStripeRequest(event, secret, timestamp = Math.floor(Date.now() / 1000)) {
	const body = JSON.stringify(event);
	const signature = createHmac('sha256', secret)
		.update(`${timestamp}.${body}`)
		.digest('hex');
	return new Request('https://library.example/api/billing/webhook', {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'Stripe-Signature': `t=${timestamp},v1=${signature}`
		},
		body
	});
}

test('connection status never exposes the stored credential', async () => {
	const database = new MockDatabase();
	database.credential = {
		openrouter_user_id: 'user_123',
		connected_at: '2026-07-23T07:00:00Z',
		encrypted_api_key: 'ciphertext',
		initialization_vector: 'iv'
	};
	const response = await worker.fetch(
		authenticatedRequest('/api/openrouter/status'),
		environment(database)
	);
	assert.equal(response.status, 200);
	assert.deepEqual(await response.json(), {
		connected: true,
		userID: 'user_123',
		connectedAt: '2026-07-23T07:00:00Z'
	});
});

test('Google Drive setup is centrally configured without exposing OAuth credentials', async () => {
	const env = environment();
	const googleResponse = await worker.fetch(authenticatedRequest('/api/google/status'), env);
	assert.equal(googleResponse.status, 200);
	const googleStatus = await googleResponse.json();
	assert.equal(googleStatus.configured, true);
	assert.equal(googleStatus.connected, false);
	assert.equal(
		googleStatus.callbackURL,
		'https://library.example/api/google/connect/callback'
	);
	assert.equal('clientID' in googleStatus, false);
	assert.equal('clientSecret' in googleStatus, false);
});

test('Google sign-in is available without an existing Sites account session', async () => {
	const env = environment();
	const statusResponse = await worker.fetch(
		new Request('https://library.example/api/google/status'),
		env
	);
	assert.equal(statusResponse.status, 401);
	assert.deepEqual(await statusResponse.json(), {
		configured: true,
		connected: false,
		authenticated: false
	});
	const startResponse = await worker.fetch(
		new Request('https://library.example/api/auth/google/start'),
		env
	);
	assert.equal(startResponse.status, 302);
	assert.equal(new URL(startResponse.headers.get('location')).hostname, 'accounts.google.com');
});

test('billing publishes the launch ladder without enforcing an unconfigured checkout', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/billing/status'),
		environment()
	);
	assert.equal(response.status, 200);
	const status = await response.json();
	assert.equal(status.configured, false);
	assert.equal(status.entitled, true);
	assert.deepEqual(
		status.tiers.map((tier) => [tier.key, tier.amount, tier.capacity, tier.current]),
		[
			['founding', 399, 50, true],
			['early', 599, 100, false],
			['growing', 799, 250, false],
			['standard', 999, null, false]
		]
	);
});

test('client-supplied identity headers cannot impersonate a Briefly account', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/auth/status', {
			headers: { 'oai-authenticated-user-email': 'victim@example.com' }
		}),
		environment()
	);
	assert.equal(response.status, 200);
	assert.deepEqual(await response.json(), { authenticated: false });
});

test('enabled billing fails closed when Stripe configuration is incomplete', async () => {
	const response = await worker.fetch(authenticatedRequest('/api/library'), {
		...environment(),
		BRIEFLY_BILLING_ENABLED: 'true'
	});
	assert.equal(response.status, 503);
	assert.equal((await response.json()).code, 'billing_unavailable');
});

test('configured Stripe checkout requires an authenticated Briefly account', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/billing/checkout', {
			method: 'POST',
			headers: { Origin: 'https://library.example' }
		}),
		stripeEnvironment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), {
		error: 'Sign in with Google to continue.',
		code: 'authentication_required'
	});
});

test('checkout validates its Price, pins the API version, and reuses one open Session', async () => {
	const database = new MockDatabase();
	const env = stripeEnvironment(database);
	const originalFetch = globalThis.fetch;
	const stripeRequests = [];
	globalThis.fetch = async (input, init = {}) => {
		const url = new URL(input);
		stripeRequests.push({ url, init });
		if (url.pathname === '/v1/prices/price_founding') {
			return Response.json({
				id: 'price_founding',
				active: true,
				product: 'prod_briefly_plus',
				currency: 'eur',
				unit_amount: 399,
				type: 'recurring',
				recurring: { interval: 'month', interval_count: 1 }
			});
		}
		if (url.pathname === '/v1/checkout/sessions' && init.method === 'POST') {
			return Response.json({
				id: 'cs_test_briefly',
				url: 'https://checkout.stripe.test/c/pay/cs_test_briefly'
			});
		}
		if (url.pathname === '/v1/checkout/sessions/cs_test_briefly') {
			return Response.json({
				id: 'cs_test_briefly',
				status: 'open',
				url: 'https://checkout.stripe.test/c/pay/cs_test_briefly'
			});
		}
		return Response.json({ error: { message: 'Unexpected Stripe request.' } }, { status: 500 });
	};
	try {
		const request = () =>
			authenticatedRequest('/api/billing/checkout', {
				method: 'POST',
				headers: { Origin: 'https://library.example' }
			});
		const first = await worker.fetch(request(), env);
		const second = await worker.fetch(request(), env);
		assert.equal(first.status, 200);
		assert.equal(second.status, 200);
		assert.equal((await first.json()).url, 'https://checkout.stripe.test/c/pay/cs_test_briefly');
		assert.equal((await second.json()).reused, true);
		const creations = stripeRequests.filter(
			({ url, init }) => url.pathname === '/v1/checkout/sessions' && init.method === 'POST'
		);
		assert.equal(creations.length, 1);
		assert.equal(creations[0].init.headers['Stripe-Version'], '2026-06-24.dahlia');
		assert.match(creations[0].init.headers['Idempotency-Key'], /^briefly-checkout-/);
		const form = creations[0].init.body;
		assert.equal(form.get('payment_method_types[0]'), 'card');
		assert.equal(form.get('automatic_tax[enabled]'), 'true');
		assert.equal(form.get('line_items[0][price]'), 'price_founding');
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test('active subscriptions on unknown Prices never grant Plus entitlement', async () => {
	const database = new MockDatabase();
	database.billingCustomers.set('reader@example.com', {
		user_email: 'reader@example.com',
		account_id: 'account-reader',
		stripe_customer_id: 'cus_reader'
	});
	database.billingSubscriptions.set('account-reader', {
		account_id: 'account-reader',
		stripe_subscription_id: 'sub_unknown',
		stripe_customer_id: 'cus_reader',
		stripe_price_id: 'price_not_briefly',
		tier_key: 'unrecognized',
		status: 'active',
		status_changed_at: Date.now(),
		stripe_created_at: Date.now(),
		current_period_end: null,
		cancel_at_period_end: 0
	});
	const response = await worker.fetch(
		authenticatedRequest('/api/billing/status'),
		stripeEnvironment(database)
	);
	const status = await response.json();
	assert.equal(status.entitled, false);
	assert.equal(status.subscription.recognized, false);
});

test('configured Plus routes reject free accounts without blocking public readers', async () => {
	const env = stripeEnvironment();
	const privateResponse = await worker.fetch(
		authenticatedRequest('/api/library'),
		env
	);
	assert.equal(privateResponse.status, 402);
	assert.equal((await privateResponse.json()).code, 'subscription_required');

	const publicResponse = await worker.fetch(
		new Request(`https://library.example/api/public/shares/${'A'.repeat(32)}`),
		env
	);
	assert.equal(publicResponse.status, 404);
});

test('Stripe webhooks require a current raw-body signature and are idempotent', async () => {
	const database = new MockDatabase();
	const env = stripeEnvironment(database);
	const event = {
		id: 'evt_checkout_expired',
		type: 'checkout.session.expired',
		data: {
			object: {
				metadata: { briefly_reservation_id: 'reservation-1' }
			}
		}
	};
	const invalidResponse = await worker.fetch(
		new Request('https://library.example/api/billing/webhook', {
			method: 'POST',
			headers: { 'Stripe-Signature': 't=1,v1=invalid' },
			body: JSON.stringify(event)
		}),
		env
	);
	assert.equal(invalidResponse.status, 400);

	const acceptedResponse = await worker.fetch(
		signedStripeRequest(event, env.STRIPE_WEBHOOK_SECRET),
		env
	);
	assert.equal(acceptedResponse.status, 200);
	assert.deepEqual(await acceptedResponse.json(), { received: true });

	const duplicateResponse = await worker.fetch(
		signedStripeRequest(event, env.STRIPE_WEBHOOK_SECRET),
		env
	);
	assert.equal(duplicateResponse.status, 200);
	assert.deepEqual(await duplicateResponse.json(), { received: true, duplicate: true });
});

test('out-of-order subscription events refresh Stripe and cannot resurrect cancelled access', async () => {
	const database = new MockDatabase();
	database.billingCustomers.set('reader@example.com', {
		user_email: 'reader@example.com',
		account_id: 'account-reader',
		stripe_customer_id: 'cus_reader'
	});
	const env = stripeEnvironment(database);
	const originalFetch = globalThis.fetch;
	let latestStatus = 'active';
	globalThis.fetch = async (input) => {
		const url = new URL(input);
		assert.equal(url.pathname, '/v1/subscriptions/sub_reader');
		return Response.json({
			id: 'sub_reader',
			customer: 'cus_reader',
			status: latestStatus,
			created: 1_785_000_000,
			cancel_at_period_end: false,
			metadata: { briefly_account_id: 'account-reader', briefly_tier_key: 'founding' },
			items: {
				data: [
					{
						price: { id: 'price_founding' },
						current_period_end: 1_790_000_000
					}
				]
			}
		});
	};
	const deliver = async (id, type) =>
		worker.fetch(
			signedStripeRequest(
				{
					id,
					type,
					data: { object: { id: 'sub_reader' } }
				},
				env.STRIPE_WEBHOOK_SECRET
			),
			env
		);
	try {
		assert.equal((await deliver('evt_active', 'customer.subscription.updated')).status, 200);
		assert.equal(database.billingSubscriptions.get('account-reader').status, 'active');
		latestStatus = 'canceled';
		assert.equal((await deliver('evt_deleted', 'customer.subscription.deleted')).status, 200);
		assert.equal(database.billingSubscriptions.get('account-reader').status, 'canceled');
		assert.equal((await deliver('evt_old_created', 'customer.subscription.created')).status, 200);
		assert.equal(database.billingSubscriptions.get('account-reader').status, 'canceled');
		const billing = await worker.fetch(authenticatedRequest('/api/billing/status'), env);
		assert.equal((await billing.json()).entitled, false);
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test('desktop library uploads validate the index before touching Drive', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/library/sync', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				schemaVersion: 1,
				index: {
					schemaVersion: 3,
					generatedAt: new Date().toISOString(),
					files: [
						{
							path: 'library/example.md',
							contentHash: 'a'.repeat(64),
							byteCount: 7
						}
					],
					entries: []
				},
				files: [
					{
						path: 'library/example.md',
						contentHash: 'a'.repeat(64),
						content: 'example'
					}
				]
			})
		}),
		environment()
	);
	assert.equal(response.status, 413);
});

test('group-folder sharing endpoints are no longer exposed', async () => {
	for (const path of ['/api/sharing/status', '/api/inbox']) {
		const response = await worker.fetch(authenticatedRequest(path), environment());
		assert.equal(response.status, 404);
	}
});

test('publishing creates a stable 192-bit capability link and returns immediately', async () => {
	const database = new MockDatabase();
	let backgroundTask;
	const response = await worker.fetch(
		authenticatedRequest('/api/share-links', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				captureID: 'capture-1',
				voice: 'eve'
			})
		}),
		environment(database),
		{
			waitUntil(task) {
				backgroundTask = task;
			}
		}
	);
	assert.equal(response.status, 202);
	const published = await response.json();
	assert.equal(published.shared, true);
	assert.equal(published.status, 'preparing');
	assert.match(published.token, /^[A-Za-z0-9_-]{32}$/);
	assert.equal(
		published.url,
		`https://library.example/?shared=${published.token}`
	);
	assert.ok(backgroundTask);
	await backgroundTask;

	const statusResponse = await worker.fetch(
		authenticatedRequest('/api/share-links?captureID=capture-1'),
		environment(database)
	);
	assert.equal(statusResponse.status, 200);
	const status = await statusResponse.json();
	assert.equal(status.shared, true);
	assert.equal(status.token, published.token);
});

test('a ready share document is readable anonymously at all stored conciseness levels', async () => {
	const database = new MockDatabase();
	const token = 'A'.repeat(32);
	database.shareLinks.set(token, {
		token,
		owner_email: 'reader@example.com',
		capture_id: 'capture-1',
		generation: 'generation-1',
		revision: 2,
		status: 'ready',
		metadata_json: JSON.stringify({
			title: 'Shared research',
			excerpt: 'A short excerpt',
			topicNames: ['Research']
		}),
		source_filename: 'shared-research.md',
		voice: 'eve',
		error_message: null,
		created_at: '2026-07-23T10:00:00Z',
		updated_at: '2026-07-23T11:00:00Z'
	});
	database.shareTexts = [
		{
			share_token: token,
			generation: 'generation-1',
			variant: 'brief',
			markdown: 'Brief text',
			word_count: 2
		},
		{
			share_token: token,
			generation: 'generation-1',
			variant: 'source',
			markdown: '---\ntitle: Shared research\n---\nOriginal text',
			word_count: 2
		}
	];
	const response = await worker.fetch(
		new Request(`https://library.example/api/public/shares/${token}`),
		environment(database)
	);
	assert.equal(response.status, 200);
	const document = await response.json();
	assert.equal(document.title, 'Shared research');
	assert.equal(document.revision, 2);
	assert.deepEqual(
		document.texts.map((text) => [text.variant, text.markdown]),
		[
			['brief', 'Brief text'],
			['source', 'Original text']
		]
	);
});

test('Google authorization uses the central web client with each user account', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/google/connect/start'),
		environment()
	);
	assert.equal(response.status, 302);
	const authorizationURL = new URL(response.headers.get('location'));
	assert.equal(authorizationURL.hostname, 'accounts.google.com');
	assert.equal(
		authorizationURL.searchParams.get('client_id'),
		'123456789-sharedlibrary.apps.googleusercontent.com'
	);
	assert.equal(
		authorizationURL.searchParams.get('scope'),
		'openid email https://www.googleapis.com/auth/drive.file'
	);
});

test('library file access rejects paths outside the mirrored workspace', async () => {
	const response = await worker.fetch(
		authenticatedRequest(
			`/api/library/file?path=${encodeURIComponent('../secrets.md')}&hash=${'a'.repeat(64)}`
		),
		environment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), { error: 'Invalid library file request.' });
});

test('audio mirror listing requires an authenticated account', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/media/audio'),
		environment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), { error: 'Authentication required.' });
});

test('GitHub endpoints are no longer exposed', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/github/status'),
		environment()
	);
	assert.equal(response.status, 404);
});

test('OAuth start keeps the verifier server-side and sends only its challenge', async () => {
	const database = new MockDatabase();
	const response = await worker.fetch(
		authenticatedRequest('/api/openrouter/connect/start'),
		environment(database)
	);
	assert.equal(response.status, 302);
	assert.ok(database.oauthState?.verifier);
	const authorizationURL = new URL(response.headers.get('location'));
	assert.equal(authorizationURL.origin, 'https://openrouter.ai');
	assert.equal(authorizationURL.pathname, '/auth');
	assert.equal(authorizationURL.searchParams.get('code_challenge_method'), 'S256');
	assert.notEqual(
		authorizationURL.searchParams.get('code_challenge'),
		database.oauthState.verifier
	);
	assert.ok(
		authorizationURL.searchParams
			.get('callback_url')
			?.startsWith('https://library.example/api/openrouter/connect/callback?state=')
	);
});

test('OAuth callback encrypts the user-controlled key before storage', async (context) => {
	const database = new MockDatabase();
	database.pendingOAuthState = {
		user_email: 'reader@example.com',
		code_verifier: 'server-side-verifier',
		created_at: Date.now()
	};
	context.mock.method(globalThis, 'fetch', async (input) => {
		assert.equal(String(input), 'https://openrouter.ai/api/v1/auth/keys');
		return Response.json({ key: 'sk-or-private', user_id: 'openrouter-user' });
	});

	const response = await worker.fetch(
		authenticatedRequest('/api/openrouter/connect/callback?state=pending&code=authorization'),
		environment(database)
	);
	assert.equal(response.status, 302);
	assert.equal(database.savedCredential?.userEmail, 'reader@example.com');
	assert.equal(database.savedCredential?.openRouterUserID, 'openrouter-user');
	assert.notEqual(database.savedCredential?.encryptedAPIKey, 'sk-or-private');
	assert.ok(database.savedCredential?.initializationVector);
});

test('credential and media mutations reject cross-origin requests', async () => {
	const env = environment();
	const mutations = [
		{ path: '/api/tts', body: { input: 'Hello', voice: 'eve' } },
		{ path: '/api/openrouter/disconnect' },
		{
			path: `/api/media/audio/${'a'.repeat(64)}`,
			body: new Uint8Array([1, 2, 3]),
			contentType: 'audio/mpeg'
		},
		{
			path: '/api/share-links',
			body: { captureID: 'capture-1', voice: 'eve' }
		},
		{
			path: `/api/public/shares/${'A'.repeat(32)}/import`
		}
	];
	for (const mutation of mutations) {
		const body =
			mutation.body instanceof Uint8Array
				? mutation.body
				: mutation.body
					? JSON.stringify(mutation.body)
					: undefined;
		const response = await worker.fetch(
			authenticatedRequest(mutation.path, {
				method: mutation.path.startsWith('/api/media/') ? 'PUT' : 'POST',
				headers: {
					Origin: 'https://attacker.example',
					'Content-Type': mutation.contentType ?? 'application/json'
				},
				body
			}),
			env
		);
		assert.equal(response.status, 403);
	}
});

test('speech requires an account-bound OpenRouter connection', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({ input: 'Hello', voice: 'af_heart' })
		}),
		environment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), { error: 'OpenRouter is not connected.' });
});

test('speech rejects malformed model identifiers before making a provider request', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({
				input: 'Hello',
				voice: 'alloy',
				model: 'not a model slug'
			})
		}),
		environment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), {
		error: 'Invalid speech text, voice, or model.'
	});
});

test('speech accepts provider-specific voice identifiers', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({
				input: 'Hello',
				voice: 'af_heart',
				model: 'hexgrad/kokoro-82m'
			})
		}),
		environment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), { error: 'OpenRouter is not connected.' });
});

test('speech rejects models outside the three quality tiers', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({
				input: 'Hello',
				voice: 'coral',
				model: 'openai/gpt-4o-mini-tts'
			})
		}),
		environment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), {
		error: 'Invalid speech text, voice, or model.'
	});
});

test('speech rejects a voice that does not belong to the selected quality', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({
				input: 'Hello',
				voice: 'eve',
				model: 'hexgrad/kokoro-82m'
			})
		}),
		environment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), {
		error: 'Invalid speech text, voice, or model.'
	});
});

test('speech forwards provider audio progressively', async (context) => {
	const database = new MockDatabase();
	database.credential = await encryptedOpenRouterCredential('sk-or-streaming');
	let providerController;
	context.mock.method(globalThis, 'fetch', async (input, init) => {
		assert.equal(String(input), 'https://openrouter.ai/api/v1/audio/speech');
		assert.equal(init.headers.Authorization, 'Bearer sk-or-streaming');
		assert.deepEqual(JSON.parse(init.body), {
			model: 'x-ai/grok-voice-tts-1.0',
			input: 'A longer streaming example.',
			voice: 'eve',
			response_format: 'mp3'
		});
		return new Response(
			new ReadableStream({
				start(controller) {
					providerController = controller;
					controller.enqueue(new Uint8Array([1, 2, 3]));
				}
			}),
			{
				headers: {
					'Content-Type': 'audio/mpeg',
					'X-Generation-Id': 'generation-1'
				}
			}
		);
	});

	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: { Origin: 'https://library.example', 'Content-Type': 'application/json' },
			body: JSON.stringify({
				input: 'A longer streaming example.',
				voice: 'eve',
				model: 'x-ai/grok-voice-tts-1.0'
			})
		}),
		environment(database)
	);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get('X-Generation-Id'), 'generation-1');
	const reader = response.body.getReader();
	assert.deepEqual(await reader.read(), {
		done: false,
		value: new Uint8Array([1, 2, 3])
	});
	providerController.enqueue(new Uint8Array([4, 5]));
	providerController.close();
	assert.deepEqual(await reader.read(), {
		done: false,
		value: new Uint8Array([4, 5])
	});
	assert.deepEqual(await reader.read(), { done: true, value: undefined });
});
