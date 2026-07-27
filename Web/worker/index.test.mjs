import assert from 'node:assert/strict';
import { createHmac, generateKeyPairSync, sign as signBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import worker from './index.js';
import { hasSameLibraryContent } from '../src/lib/library.ts';
import { ttsModels } from '../tts-pricing.js';

test('iCloud setup verifies the remote library before reporting success', async () => {
	const [setup, reader] = await Promise.all([
		readFile(new URL('../src/routes/icloud/+page.svelte', import.meta.url), 'utf8'),
		readFile(new URL('../src/routes/+page.svelte', import.meta.url), 'utf8')
	]);
	assert.match(
		setup,
		/const projection = await fetchICloudLibraryIndex\(\);[\s\S]+await selectICloudSync\(\)/
	);
	assert.match(setup, /projection \? 'connected' : 'empty'/);
	assert.match(reader, /if \(!syncedProjection\) \{[\s\S]+emptyICloudLibraryMessage/);
	assert.match(reader, /Authorize iCloud on this browser/);
});

test('library projection comparison ignores sync timestamps but detects content changes', () => {
	const projection = {
		schemaVersion: 3,
		generatedAt: '2026-07-26T12:00:00.000Z',
		files: [{ path: 'library/example.md', contentHash: 'a'.repeat(64), byteCount: 7 }],
		entries: [{ id: 'personal:example' }]
	};
	assert.equal(
		hasSameLibraryContent(projection, {
			...projection,
			generatedAt: '2026-07-26T12:05:00.000Z'
		}),
		true
	);
	assert.equal(
		hasSameLibraryContent(projection, {
			...projection,
			files: [{ ...projection.files[0], contentHash: 'b'.repeat(64) }]
		}),
		false
	);
});

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
			if (
				this.sql.includes('FROM billing_customers') &&
				this.sql.includes('WHERE account_id = ?')
			) {
				return (
					[...this.database.billingCustomers.values()].find(
						(record) => record.account_id === this.arguments[0]
					) ?? null
				);
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
			if (this.sql.includes('FROM google_login_states')) {
				return this.database.googleLoginState?.state === this.arguments[0]
					? this.database.googleLoginState
					: null;
			}
			if (this.sql.includes('FROM google_oauth_states')) {
				return this.database.googleOAuthState?.state === this.arguments[0]
					? this.database.googleOAuthState
					: null;
			}
			if (this.sql.includes('FROM apple_login_states')) {
				return this.database.appleLoginState?.state === this.arguments[0]
					? this.database.appleLoginState
					: null;
			}
			if (this.sql.includes('FROM auth_identities')) {
				return (
					this.database.authIdentities.get(`${this.arguments[0]}:${this.arguments[1]}`) ??
					null
				);
			}
			if (this.sql.includes('FROM sync_preferences')) {
				const provider = this.database.syncPreferences.get(this.arguments[0]);
				return provider ? { provider } : null;
			}
			if (this.sql.includes('FROM tts_accounts')) {
				return this.database.ttsAccounts.get(this.arguments[0]) ?? null;
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
					user_email: this.database.sessionEmail,
					expires_at: Date.now() + 60_000
				};
			}
			if (this.sql.includes('FROM feedback_upvotes')) {
				const [userEmail, itemID] = this.arguments;
				const upvotes = [...this.database.feedbackUpvotes.values()].filter(
					(upvote) => upvote.feedback_item_id === itemID
				);
				return {
					upvotes: upvotes.length,
					upvoted: upvotes.some((upvote) => upvote.user_email === userEmail) ? 1 : 0
				};
			}
		return null;
	}

	async all() {
		if (this.sql.includes('FROM feedback_items')) {
			const userEmail = this.arguments[0];
			return {
				results: [...this.database.feedbackItems.values()]
					.map((item) => {
						const upvotes = [...this.database.feedbackUpvotes.values()].filter(
							(upvote) => upvote.feedback_item_id === item.id
						);
						return {
							...item,
							upvotes: upvotes.length,
							upvoted: upvotes.some((upvote) => upvote.user_email === userEmail) ? 1 : 0
						};
					})
					.sort(
						(left, right) =>
							right.upvotes - left.upvotes || right.created_at - left.created_at
					)
			};
		}
		if (this.sql.includes('FROM tts_usage')) {
			return {
				results: [...this.database.ttsUsage.values()]
					.filter(
						(row) =>
							(this.arguments.length === 1
								? row.account_id === this.arguments[0] && row.status === 'settled'
								: ['pending', 'reserved'].includes(row.status) &&
									row.updated_at <= Number(this.arguments[0]))
					)
					.sort((left, right) => right.updated_at - left.updated_at)
					.slice(0, 10)
			};
		}
		if (this.sql.includes('FROM share_links')) {
			return {
				results: [...this.database.shareLinks.values()]
					.filter((row) => row.owner_email === this.arguments[0])
					.sort((left, right) => right.updated_at.localeCompare(left.updated_at))
					.slice(0, Number(this.arguments[1]))
			};
		}
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
			if (this.sql.includes('INSERT INTO feedback_items')) {
				const [id, userEmail, title, details, createdAt] = this.arguments;
				this.database.feedbackItems.set(id, {
					id,
					user_email: userEmail,
					title,
					details,
					created_at: createdAt
				});
				changes = 1;
			}
			if (this.sql.includes('INTO feedback_upvotes')) {
				const [feedbackItemID, userEmail, createdAt] = this.arguments;
				const key = `${feedbackItemID}:${userEmail}`;
				if (!this.database.feedbackUpvotes.has(key)) {
					this.database.feedbackUpvotes.set(key, {
						feedback_item_id: feedbackItemID,
						user_email: userEmail,
						created_at: createdAt
					});
					changes = 1;
				}
			}
			if (this.sql.includes('DELETE FROM feedback_upvotes')) {
				changes = Number(
					this.database.feedbackUpvotes.delete(`${this.arguments[0]}:${this.arguments[1]}`)
				);
			}
			if (this.sql.includes('INSERT INTO openrouter_oauth_states')) {
			this.database.oauthState = {
				state: this.arguments[0],
				userEmail: this.arguments[1],
				verifier: this.arguments[2],
				createdAt: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO google_login_states')) {
			this.database.googleLoginState = {
				state: this.arguments[0],
				code_verifier: this.arguments[1],
				return_to: this.arguments[2],
				created_at: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO google_oauth_states')) {
			this.database.googleOAuthState = {
				state: this.arguments[0],
				user_email: this.arguments[1],
				code_verifier: this.arguments[2],
				created_at: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('INSERT INTO apple_login_states')) {
			this.database.appleLoginState = {
				state: this.arguments[0],
				nonce: this.arguments[1],
				return_to: this.arguments[2],
				created_at: this.arguments[3]
			};
			changes = 1;
		}
		if (this.sql.includes('INSERT OR IGNORE INTO auth_identities')) {
			const key = `${this.arguments[0]}:${this.arguments[1]}`;
			if (!this.database.authIdentities.has(key)) {
				this.database.authIdentities.set(key, {
					user_email: this.arguments[2]
				});
				changes = 1;
			}
		}
		if (this.sql.includes('INSERT INTO sync_preferences')) {
			this.database.syncPreferences.set(
				this.arguments[0],
				this.sql.includes("'google'") ? 'google' : this.arguments[1]
			);
			changes = 1;
		}
		if (this.sql.includes('DELETE FROM sync_preferences')) {
			changes = Number(this.database.syncPreferences.delete(this.arguments[0]));
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
			if (this.sql.includes('INSERT OR IGNORE INTO tts_accounts')) {
				const [accountID, createdAt, updatedAt] = this.arguments;
				if (!this.database.ttsAccounts.has(accountID)) {
					this.database.ttsAccounts.set(accountID, {
						account_id: accountID,
						balance_micros: 0,
						created_at: createdAt,
						updated_at: updatedAt
					});
					changes = 1;
				}
			}
			if (this.sql.includes('INSERT OR IGNORE INTO tts_usage')) {
				const [
					requestID,
					accountID,
					model,
					voice,
					characterCount,
					amountMicros,
					createdAt,
					updatedAt
				] = this.arguments;
				if (!this.database.ttsUsage.has(requestID)) {
					this.database.ttsUsage.set(requestID, {
						request_id: requestID,
						account_id: accountID,
						model,
						voice,
						character_count: characterCount,
						amount_micros: amountMicros,
						status: 'pending',
						generation_id: null,
						created_at: createdAt,
						updated_at: updatedAt
					});
					changes = 1;
				}
			}
			if (
				this.sql.includes('UPDATE tts_accounts') &&
				this.sql.includes('balance_micros = balance_micros -')
			) {
				const [amountMicros, updatedAt, accountID, minimumBalance] = this.arguments;
				const account = this.database.ttsAccounts.get(accountID);
				if (account && account.balance_micros >= minimumBalance) {
					account.balance_micros -= amountMicros;
					account.updated_at = updatedAt;
					changes = 1;
				}
			}
			if (
				this.sql.includes('UPDATE tts_accounts') &&
				this.sql.includes('balance_micros = balance_micros +')
			) {
				const [amountMicros, updatedAt, accountID] = this.arguments;
				const referenceID = this.sql.includes('FROM tts_welcome_credits')
					? this.arguments[4]
					: this.arguments[3];
				const account = this.database.ttsAccounts.get(accountID);
				const usage = this.database.ttsUsage.get(referenceID);
				const topUp = this.database.ttsTopUps.get(referenceID);
				const monthly = this.sql.includes('FROM tts_monthly_credits')
					? this.database.ttsMonthlyCredits.get(
							`${this.arguments[3]}:${this.arguments[4]}`
						)
					: null;
				const welcome = [...this.database.ttsWelcomeCredits.values()].find(
					(record) =>
						record.account_id === accountID &&
						record.stripe_checkout_session_id === referenceID
				);
				if (
					account &&
					((usage && usage.status === 'reserved') ||
						(topUp && topUp.account_id === accountID && topUp.credited_at === null) ||
						(monthly && monthly.credited_at === null) ||
						(welcome && welcome.credited_at === null))
				) {
					account.balance_micros += amountMicros;
					account.updated_at = updatedAt;
					changes = 1;
				}
			}
			if (this.sql.includes("UPDATE tts_usage SET status = 'declined'")) {
				const record = this.database.ttsUsage.get(this.arguments[1]);
				if (record?.status === 'pending') {
					record.status = 'declined';
					record.updated_at = this.arguments[0];
					changes = 1;
				}
			}
			if (this.sql.includes("UPDATE tts_usage SET status = 'reserved'")) {
				const record = this.database.ttsUsage.get(this.arguments[1]);
				if (record?.status === 'pending') {
					record.status = 'reserved';
					record.updated_at = this.arguments[0];
					changes = 1;
				}
			}
			if (this.sql.includes("UPDATE tts_usage SET status = 'released'")) {
				const record = this.database.ttsUsage.get(this.arguments[1]);
				if (record && ['pending', 'reserved'].includes(record.status)) {
					record.status = 'released';
					record.updated_at = this.arguments[0];
					changes = 1;
				}
			}
			if (this.sql.includes("SET status = 'settled', generation_id")) {
				const record = this.database.ttsUsage.get(this.arguments[2]);
				if (
					record?.account_id === this.arguments[3] &&
					record.status === 'reserved'
				) {
					record.status = 'settled';
					record.generation_id = this.arguments[0];
					record.updated_at = this.arguments[1];
					changes = 1;
				}
			}
			if (this.sql.includes('INSERT OR IGNORE INTO tts_topups')) {
				const [sessionID, accountID, paymentIntentID, amountMicros, createdAt] =
					this.arguments;
				if (!this.database.ttsTopUps.has(sessionID)) {
					this.database.ttsTopUps.set(sessionID, {
						checkout_session_id: sessionID,
						account_id: accountID,
						stripe_payment_intent_id: paymentIntentID,
						amount_micros: amountMicros,
						refunded_micros: 0,
						refund_status: 'disabled',
						created_at: createdAt,
						credited_at: null,
						refunded_at: null
					});
					changes = 1;
				}
			}
			if (
				this.sql.includes('UPDATE tts_topups SET credited_at') &&
				this.database.ttsTopUps.has(this.arguments[1])
			) {
				const record = this.database.ttsTopUps.get(this.arguments[1]);
				if (record.credited_at === null) {
					record.credited_at = this.arguments[0];
					changes = 1;
				}
			}
			if (this.sql.includes('INSERT OR IGNORE INTO tts_welcome_credits')) {
				const [accountID, sessionID, amountMicros, createdAt] = this.arguments;
				if (!this.database.ttsWelcomeCredits.has(accountID)) {
					this.database.ttsWelcomeCredits.set(accountID, {
						account_id: accountID,
						stripe_checkout_session_id: sessionID,
						amount_micros: amountMicros,
						created_at: createdAt,
						credited_at: null
					});
					changes = 1;
				}
			}
			if (this.sql.includes('UPDATE tts_welcome_credits SET credited_at')) {
				const record = this.database.ttsWelcomeCredits.get(this.arguments[1]);
				if (
					record?.stripe_checkout_session_id === this.arguments[2] &&
					record.credited_at === null
				) {
					record.credited_at = this.arguments[0];
					changes = 1;
				}
			}
			if (this.sql.includes('INSERT OR IGNORE INTO tts_monthly_credits')) {
				const [accountID, creditMonth, amountMicros, createdAt] = this.arguments;
				const key = `${accountID}:${creditMonth}`;
				if (!this.database.ttsMonthlyCredits.has(key)) {
					this.database.ttsMonthlyCredits.set(key, {
						account_id: accountID,
						credit_month: creditMonth,
						amount_micros: amountMicros,
						created_at: createdAt,
						credited_at: null
					});
					changes = 1;
				}
			}
			if (this.sql.includes('UPDATE tts_monthly_credits SET credited_at')) {
				const record = this.database.ttsMonthlyCredits.get(
					`${this.arguments[1]}:${this.arguments[2]}`
				);
				if (record?.credited_at === null) {
					record.credited_at = this.arguments[0];
					changes = 1;
				}
			}
		if (this.sql.includes('INSERT INTO share_links')) {
			const existing = [...this.database.shareLinks.values()].find(
				(record) =>
					record.owner_email === this.arguments[1] &&
					record.capture_id === this.arguments[2]
			);
			const ownerLinkCount = [...this.database.shareLinks.values()].filter(
				(record) => record.owner_email === this.arguments[1]
			).length;
			if (!existing && ownerLinkCount >= Number(this.arguments[10])) {
				return { success: true, meta: { changes: 0 } };
			}
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
		if (this.sql.includes('INSERT OR REPLACE INTO share_texts')) {
			const [shareToken, generation, variant, markdown, wordCount] = this.arguments;
			this.database.shareTexts = this.database.shareTexts.filter(
				(row) =>
					!(
						row.share_token === shareToken &&
						row.generation === generation &&
						row.variant === variant
					)
			);
			this.database.shareTexts.push({
				share_token: shareToken,
				generation,
				variant,
				markdown,
				word_count: wordCount
			});
			changes = 1;
		}
		if (this.sql.includes('INSERT OR REPLACE INTO share_audio_segments')) {
			const [
				shareToken,
				generation,
				variant,
				segmentIndex,
				audioHash,
				r2Key,
				contentType,
				byteCount,
				voice
			] = this.arguments;
			this.database.shareAudioSegments = this.database.shareAudioSegments.filter(
				(row) =>
					!(
						row.share_token === shareToken &&
						row.generation === generation &&
						row.variant === variant &&
						row.segment_index === segmentIndex
					)
			);
			this.database.shareAudioSegments.push({
				share_token: shareToken,
				generation,
				variant,
				segment_index: segmentIndex,
				audio_hash: audioHash,
				r2_key: r2Key,
				content_type: contentType,
				byte_count: byteCount,
				voice
			});
			changes = 1;
		}
		if (this.sql.includes("SET status = 'ready'")) {
			const record = this.database.shareLinks.get(this.arguments[3]);
			if (record && record.generation === this.arguments[4]) {
				record.status = 'ready';
				record.metadata_json = this.arguments[0];
				record.source_filename = this.arguments[1];
				record.error_message = null;
				record.updated_at = this.arguments[2];
				changes = 1;
			}
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
	sessionEmail = 'reader@example.com';
	credential = null;
	oauthState = null;
	googleLoginState = null;
	googleOAuthState = null;
	appleLoginState = null;
	authIdentities = new Map();
	syncPreferences = new Map();
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
	ttsAccounts = new Map();
	ttsWelcomeCredits = new Map();
	ttsMonthlyCredits = new Map();
	ttsTopUps = new Map();
	ttsUsage = new Map();
	feedbackItems = new Map();
	feedbackUpvotes = new Map();

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
		OPENROUTER_API_KEY: 'sk-or-managed',
		GOOGLE_DRIVE_WEB_CLIENT_ID:
			'123456789-sharedlibrary.apps.googleusercontent.com',
		GOOGLE_DRIVE_WEB_CLIENT_SECRET: 'central-google-secret',
		APPLE_CLIENT_ID: 'fyi.readbriefly.web',
		APPLE_TEAM_ID: 'ABCDEFGHIJ',
		APPLE_KEY_ID: 'K123456789',
		APPLE_PRIVATE_KEY:
			'-----BEGIN PRIVATE KEY-----\\ntest-private-key\\n-----END PRIVATE KEY-----',
		CLOUDKIT_CONTAINER_ID: 'iCloud.fyi.readbriefly',
		CLOUDKIT_API_TOKEN: 'test-cloudkit-api-token-123456789',
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
		STRIPE_SECRET_KEY: 'rk_test_briefly',
		STRIPE_WEBHOOK_SECRET: 'whsec_briefly_test',
		STRIPE_PRODUCT_PLUS: 'prod_briefly_plus',
		STRIPE_PRODUCT_TTS: 'prod_briefly_tts',
		STRIPE_PORTAL_CONFIGURATION_ID: 'bpc_briefly_plus',
		STRIPE_PRICE_FOUNDING: 'price_founding',
		STRIPE_PRICE_EARLY: 'price_early',
		STRIPE_PRICE_GROWING: 'price_growing',
		STRIPE_PRICE_STANDARD: 'price_standard'
	};
}

function entitledEnvironment(database = new MockDatabase()) {
	database.billingCustomers.set('reader@example.com', {
		user_email: 'reader@example.com',
		account_id: 'account-reader',
		stripe_customer_id: 'cus_reader'
	});
	database.billingSubscriptions.set('account-reader', {
		account_id: 'account-reader',
		stripe_subscription_id: 'sub_reader',
		stripe_customer_id: 'cus_reader',
		stripe_price_id: 'price_founding',
		tier_key: 'founding',
		status: 'active',
		status_changed_at: Date.now(),
		stripe_created_at: Date.now(),
		current_period_end: null,
		cancel_at_period_end: 0
	});
	return stripeEnvironment(database);
}

function fundedTTSEnvironment(database, balanceMicros = 500_000_000) {
	database.billingCustomers.set('reader@example.com', {
		user_email: 'reader@example.com',
		account_id: 'account-reader',
		stripe_customer_id: 'cus_reader',
		created_at: Date.now(),
		updated_at: Date.now()
	});
	database.ttsAccounts.set('account-reader', {
		account_id: 'account-reader',
		balance_micros: balanceMicros,
		created_at: Date.now(),
		updated_at: Date.now()
	});
	return environment(database);
}

function authenticatedRequest(path, init = {}) {
	const headers = new Headers(init.headers);
	headers.set('Cookie', 'shared_library_session=test-session');
	return new Request(`https://library.example${path}`, { ...init, headers });
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

test('managed speech status exposes balance and prices, never the server key', async () => {
	const database = new MockDatabase();
	const response = await worker.fetch(
		authenticatedRequest('/api/tts/status'),
		fundedTTSEnvironment(database)
	);
	assert.equal(response.status, 200);
	const status = await response.json();
	assert.equal(status.configured, true);
	assert.equal(status.authenticated, true);
	assert.equal(status.balanceMicros, 500_000_000);
	assert.deepEqual(status.topUpAmounts, [500, 1000, 1500]);
	assert.equal(status.prices.length, 3);
	assert.equal(JSON.stringify(status).includes('sk-or-managed'), false);
});

test('the owner receives exactly €10 of AI voice credit each UTC month', async (context) => {
	const database = new MockDatabase();
	database.sessionEmail = 'schauljonathan@gmail.com';
	const env = environment(database);
	let now = Date.UTC(2026, 6, 1);
	context.mock.method(Date, 'now', () => now);

	for (let request = 0; request < 2; request += 1) {
		const response = await worker.fetch(authenticatedRequest('/api/tts/status'), env);
		assert.equal((await response.json()).balanceMicros, 1_000_000_000);
	}
	assert.equal(database.ttsMonthlyCredits.size, 1);

	now = Date.UTC(2026, 7, 1);
	const nextMonth = await worker.fetch(authenticatedRequest('/api/tts/status'), env);
	assert.equal((await nextMonth.json()).balanceMicros, 2_000_000_000);
	assert.equal(database.ttsMonthlyCredits.size, 2);
});

test('managed speech pricing reports rounded audio hours per euro', () => {
	assert.deepEqual(ttsModels.map((option) => option.hoursPerEuro), [10, 2, 1]);
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
	const authorizationURL = new URL(startResponse.headers.get('location'));
	assert.equal(authorizationURL.hostname, 'accounts.google.com');
	assert.equal(authorizationURL.searchParams.get('scope'), 'openid email');
	assert.equal(authorizationURL.searchParams.has('access_type'), false);
});

test('Apple sign-in is a separate account flow', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/auth/apple/start?return_to=%2Faccount'),
		environment()
	);
	assert.equal(response.status, 302);
	const authorizationURL = new URL(response.headers.get('location'));
	assert.equal(authorizationURL.origin, 'https://appleid.apple.com');
	assert.equal(authorizationURL.searchParams.get('client_id'), 'fyi.readbriefly.web');
	assert.equal(authorizationURL.searchParams.get('scope'), 'name email');
	assert.equal(authorizationURL.searchParams.get('response_mode'), 'form_post');
	assert.equal(
		authorizationURL.searchParams.get('redirect_uri'),
		'https://library.example/api/auth/apple/callback'
	);
});

test('Apple callback verifies the identity token before creating a session', async (context) => {
	const database = new MockDatabase();
	database.appleLoginState = {
		state: 'apple-state',
		nonce: 'apple-nonce',
		return_to: '/account',
		created_at: Date.now()
	};
	const clientKeys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
	const appleKeys = generateKeyPairSync('rsa', { modulusLength: 2048 });
	const header = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'APPLEKEY01' })).toString(
		'base64url'
	);
	const claims = Buffer.from(
		JSON.stringify({
			iss: 'https://appleid.apple.com',
			aud: 'fyi.readbriefly.web',
			exp: Math.floor(Date.now() / 1000) + 300,
			nonce: 'apple-nonce',
			sub: 'apple-user-1',
			email: 'apple-reader@example.com',
			email_verified: 'true'
		})
	).toString('base64url');
	const input = `${header}.${claims}`;
	const idToken = `${input}.${signBytes('RSA-SHA256', Buffer.from(input), appleKeys.privateKey).toString('base64url')}`;
	context.mock.method(globalThis, 'fetch', async (input, init) => {
		const url = new URL(input);
		if (url.pathname === '/auth/token') {
			assert.equal(init.method, 'POST');
			assert.equal(new URLSearchParams(init.body).get('client_secret').split('.').length, 3);
			return Response.json({ id_token: idToken });
		}
		if (url.pathname === '/auth/keys') {
			return Response.json({
				keys: [{ ...appleKeys.publicKey.export({ format: 'jwk' }), kid: 'APPLEKEY01' }]
			});
		}
		return new Response('not found', { status: 404 });
	});
	const env = {
		...environment(database),
		APPLE_PRIVATE_KEY: clientKeys.privateKey.export({ format: 'pem', type: 'pkcs8' })
	};
	const response = await worker.fetch(
		new Request('https://library.example/api/auth/apple/callback', {
			method: 'POST',
			headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
			body: new URLSearchParams({ state: 'apple-state', code: 'apple-code' })
		}),
		env
	);
	assert.equal(response.status, 302);
	assert.equal(
		response.headers.get('location'),
		'https://library.example/account?apple=signed-in'
	);
	assert.match(response.headers.get('set-cookie'), /^shared_library_session=/);
	assert.equal(
		database.authIdentities.get('apple:apple-user-1').user_email,
		'apple-reader@example.com'
	);
});

test('billing publishes the launch ladder and fails closed until Stripe is configured', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/billing/status'),
		environment()
	);
	assert.equal(response.status, 200);
	const status = await response.json();
	assert.equal(status.configured, false);
	assert.equal(status.entitled, false);
	assert.equal('enforced' in status, false);
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
	assert.deepEqual(await response.json(), {
		authenticated: false,
		providers: { google: true, apple: true }
	});
});

test('users can post feedback and independently upvote it', async () => {
	const database = new MockDatabase();
	const env = environment(database);
	const createdResponse = await worker.fetch(
		authenticatedRequest('/api/feedback', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				title: 'Add keyboard shortcuts',
				details: 'Let readers move between documents without reaching for the mouse.'
			})
		}),
		env
	);
	assert.equal(createdResponse.status, 201);
	const created = await createdResponse.json();
	assert.equal(created.upvotes, 1);
	assert.equal(created.upvoted, true);

	database.sessionEmail = 'second-reader@example.com';
	const upvoteResponse = await worker.fetch(
		authenticatedRequest(`/api/feedback/${created.id}/upvote`, {
			method: 'PUT',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({ upvoted: true })
		}),
		env
	);
	assert.deepEqual(await upvoteResponse.json(), {
		id: created.id,
		upvotes: 2,
		upvoted: true
	});

	const boardResponse = await worker.fetch(
		new Request('https://library.example/api/feedback'),
		env
	);
	const board = await boardResponse.json();
	assert.equal(board.authenticated, false);
	assert.deepEqual(
		board.items.map((item) => [item.title, item.upvotes, item.upvoted]),
		[['Add keyboard shortcuts', 2, false]]
	);
});

test('billing fails closed when Stripe configuration is incomplete', async () => {
	const response = await worker.fetch(authenticatedRequest('/api/library'), environment());
	assert.equal(response.status, 503);
	assert.equal((await response.json()).code, 'billing_unavailable');
});

test('the owner account has complimentary Plus access without Stripe', async () => {
	const database = new MockDatabase();
	database.sessionEmail = 'SchaulJonathan@gmail.com';
	const env = environment(database);
	const response = await worker.fetch(authenticatedRequest('/api/billing/status'), env);
	assert.equal(response.status, 200);
	const { configured, entitled, complimentary, subscription } = await response.json();
	assert.deepEqual({ configured, entitled, complimentary, subscription }, {
		configured: false,
		entitled: true,
		complimentary: true,
		subscription: null
	});
	const checkout = await worker.fetch(
		authenticatedRequest('/api/billing/checkout', {
			method: 'POST',
			headers: { Origin: 'https://library.example' }
		}),
		env
	);
	assert.equal(checkout.status, 409);
	assert.equal((await checkout.json()).code, 'access_exists');
	const library = await worker.fetch(authenticatedRequest('/api/library'), env);
	assert.equal(library.status, 401);
	assert.equal((await library.json()).error, 'Connect Google Drive first.');
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
		error: 'Sign in to continue.',
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
		assert.match(creations[0].init.headers['Idempotency-Key'], /^briefly-checkout-v3-/);
		const form = creations[0].init.body;
		assert.equal(form.get('payment_method_types[0]'), null);
		assert.equal(form.get('automatic_tax[enabled]'), null);
		assert.equal(form.get('tax_id_collection[enabled]'), null);
		assert.equal(form.get('line_items[0][price]'), 'price_founding');
		assert.equal(form.get('custom_text[submit][message]'), null);
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test('AI voice top-up checkout accepts only fixed VAT-inclusive credit amounts', async () => {
	const database = new MockDatabase();
	const env = stripeEnvironment(database);
	const originalFetch = globalThis.fetch;
	let checkoutForm;
	let checkoutHeaders;
	globalThis.fetch = async (input, init = {}) => {
		const url = new URL(input);
		if (url.pathname === '/v1/products/prod_briefly_tts') {
			return Response.json({ id: 'prod_briefly_tts', active: true });
		}
		if (url.pathname === '/v1/checkout/sessions') {
			checkoutForm = init.body;
			checkoutHeaders = init.headers;
			return Response.json({
				id: 'cs_tts_topup',
				url: 'https://checkout.stripe.test/c/pay/cs_tts_topup'
			});
		}
		return Response.json({ error: { message: 'Unexpected Stripe request.' } }, { status: 500 });
	};
	try {
		const response = await worker.fetch(
			authenticatedRequest('/api/tts/checkout', {
				method: 'POST',
				headers: {
					Origin: 'https://library.example',
					'Content-Type': 'application/json'
				},
				body: JSON.stringify({
					amountCents: 500,
					checkoutID: '8f44eb45-905c-4eb1-8f91-4f6c37de3e35'
				})
			}),
			env
		);
		assert.equal(response.status, 200);
		assert.equal(checkoutForm.get('mode'), 'payment');
		assert.equal(checkoutForm.get('line_items[0][price_data][unit_amount]'), '500');
		assert.equal(checkoutForm.get('line_items[0][price_data][tax_behavior]'), 'inclusive');
		assert.equal(checkoutForm.get('line_items[0][price_data][product]'), 'prod_briefly_tts');
		assert.equal(checkoutForm.get('metadata[briefly_kind]'), 'tts_credit');
		assert.match(checkoutHeaders['Idempotency-Key'], /^briefly-tts-checkout-v3-/);
		assert.equal(checkoutForm.get('payment_method_types[0]'), null);
		assert.equal(checkoutForm.get('automatic_tax[enabled]'), 'true');
		assert.equal(checkoutForm.get('tax_id_collection[enabled]'), 'true');
		assert.equal(checkoutForm.get('billing_address_collection'), 'required');
		assert.equal(checkoutForm.get('customer_creation'), 'always');
		assert.equal(checkoutForm.get('custom_text[submit][message]'), null);
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

test('paid AI voice checkout credits the VAT-exclusive amount exactly once', async () => {
	const database = new MockDatabase();
	database.billingCustomers.set('reader@example.com', {
		user_email: 'reader@example.com',
		account_id: 'account-reader',
		stripe_customer_id: null
	});
	const env = stripeEnvironment(database);
	const session = {
		id: 'cs_tts_topup',
		mode: 'payment',
		payment_status: 'paid',
		amount_total: 500,
		currency: 'eur',
		automatic_tax: { enabled: true, status: 'complete' },
		total_details: { amount_tax: 87 },
		client_reference_id: 'account-reader',
		customer: 'cus_reader',
		payment_intent: 'pi_tts_topup',
		created: 1_785_000_000,
		metadata: {
			briefly_kind: 'tts_credit',
			briefly_account_id: 'account-reader',
			briefly_credit_cents: '500'
		}
	};
	const event = {
		id: 'evt_tts_topup',
		type: 'checkout.session.completed',
		data: { object: session }
	};
	const originalFetch = globalThis.fetch;
	globalThis.fetch = async (input) => {
		const url = new URL(input);
		if (url.pathname === '/v1/checkout/sessions/cs_tts_topup') {
			return Response.json(session);
		}
		return Response.json({ error: { message: 'Unexpected Stripe request.' } }, { status: 500 });
	};
	try {
		const first = await worker.fetch(
			signedStripeRequest(event, env.STRIPE_WEBHOOK_SECRET),
			env
		);
		const duplicate = await worker.fetch(
			signedStripeRequest(event, env.STRIPE_WEBHOOK_SECRET),
			env
		);
		assert.equal(first.status, 200);
		assert.deepEqual(await duplicate.json(), { received: true, duplicate: true });
		assert.equal(database.ttsAccounts.get('account-reader').balance_micros, 413_000_000);
		assert.equal(database.ttsTopUps.get('cs_tts_topup').amount_micros, 413_000_000);
		assert.equal(database.ttsTopUps.get('cs_tts_topup').credited_at > 0, true);
		assert.equal(database.ttsTopUps.get('cs_tts_topup').refund_status, 'disabled');
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test('first paid Plus month grants matching AI voice credit only once', async (context) => {
	const database = new MockDatabase();
	database.billingCustomers.set('reader@example.com', {
		user_email: 'reader@example.com',
		account_id: 'account-reader',
		stripe_customer_id: 'cus_reader'
	});
	database.checkoutReservations.set('account-reader', {
		reservation_id: 'reservation-welcome',
		account_id: 'account-reader',
		tier_key: 'founding',
		stripe_session_id: 'cs_plus_welcome',
		expires_at: Date.now() + 60_000,
		created_at: Date.now()
	});
	const env = stripeEnvironment(database);
	context.mock.method(globalThis, 'fetch', async (input) => {
		assert.equal(new URL(input).pathname, '/v1/subscriptions/sub_welcome');
		return Response.json({
			id: 'sub_welcome',
			customer: 'cus_reader',
			status: 'active',
			created: 1_785_000_000,
			cancel_at_period_end: false,
			metadata: {
				briefly_account_id: 'account-reader',
				briefly_tier_key: 'founding'
			},
			items: {
				data: [
					{
						price: { id: 'price_founding' },
						current_period_end: 1_790_000_000
					}
				]
			}
		});
	});
	const session = {
		id: 'cs_plus_welcome',
		mode: 'subscription',
		payment_status: 'paid',
		amount_total: 475,
		currency: 'eur',
		client_reference_id: 'account-reader',
		customer: 'cus_reader',
		subscription: 'sub_welcome',
		metadata: {
			briefly_reservation_id: 'reservation-welcome',
			briefly_tier_key: 'founding'
		}
	};
	for (const [id, type] of [
		['evt_plus_welcome', 'checkout.session.completed'],
		['evt_plus_welcome_async', 'checkout.session.async_payment_succeeded']
	]) {
		const response = await worker.fetch(
			signedStripeRequest({ id, type, data: { object: session } }, env.STRIPE_WEBHOOK_SECRET),
			env
		);
		assert.equal(response.status, 200);
	}
	assert.equal(database.ttsAccounts.get('account-reader').balance_micros, 475_000_000);
	assert.equal(database.ttsWelcomeCredits.get('account-reader').credited_at > 0, true);
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
		entitledEnvironment()
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
		entitledEnvironment(database),
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
		entitledEnvironment(database)
	);
	assert.equal(statusResponse.status, 200);
	const status = await statusResponse.json();
	assert.equal(status.shared, true);
	assert.equal(status.token, published.token);
});

test('iCloud clients publish the selected document without routing private files through Drive', async () => {
	const database = new MockDatabase();
	database.syncPreferences.set('reader@example.com', 'icloud');
	const storedAudio = new Map();
	const env = entitledEnvironment(database);
	env.SHARE_MEDIA = {
		async put(key, bytes) {
			storedAudio.set(key, new Uint8Array(bytes));
		}
	};
	let backgroundTask;
	const response = await worker.fetch(
		authenticatedRequest('/api/share-links', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				captureID: 'capture-icloud',
				voice: 'eve',
				source: {
					filename: 'icloud-note.md',
					title: 'iCloud note',
					excerpt: 'A private note selected for sharing.',
					topicIDs: ['notes'],
					topicNames: ['Notes'],
					tags: [],
					texts: [
						{
							variant: 'source',
							markdown:
								'---\nid: \"capture-icloud\"\ntitle: \"iCloud note\"\n---\n\nPrivate source.'
						},
						{ variant: 'concise', markdown: 'Concise summary.' }
					]
				}
			})
		}),
		env,
		{
			waitUntil(task) {
				backgroundTask = task;
			}
		}
	);
	assert.equal(response.status, 202);
	const published = await response.json();
	assert.equal(published.status, 'preparing');
	assert.match(published.generation, /^[a-f0-9-]{36}$/);
	await backgroundTask;
	const audioHash = 'a'.repeat(64);
	const audioResponse = await worker.fetch(
		authenticatedRequest(
			`/api/share-links/${published.token}/audio/${published.generation}/source/0/${audioHash}`,
			{
				method: 'PUT',
				headers: {
					Origin: 'https://library.example',
					'Content-Type': 'audio/mpeg',
					'X-Briefly-Voice': 'eve'
				},
				body: new Uint8Array([1, 2, 3])
			}
		),
		env
	);
	assert.equal(audioResponse.status, 200);
	assert.equal(database.shareAudioSegments.length, 1);
	assert.equal(storedAudio.size, 1);

	const ready = await worker.fetch(
		new Request(`https://library.example/api/public/shares/${published.token}`),
		env
	);
	assert.equal(ready.status, 200);
	const document = await ready.json();
	assert.equal(document.title, 'iCloud note');
	assert.deepEqual(
		document.texts.map((text) => text.variant),
		['concise', 'source']
	);
	assert.equal(JSON.stringify(document).includes('Private source.'), true);
});

test('iCloud recipients receive an authenticated import package instead of a Drive write', async () => {
	const database = new MockDatabase();
	database.syncPreferences.set('reader@example.com', 'icloud');
	const token = 'I'.repeat(32);
	database.shareLinks.set(token, {
		token,
		owner_email: 'owner@example.com',
		capture_id: 'capture-shared',
		generation: 'generation-icloud',
		revision: 3,
		status: 'ready',
		metadata_json: JSON.stringify({
			title: 'Shared through iCloud',
			excerpt: 'A shared document.'
		}),
		source_filename: 'shared-through-icloud.md',
		voice: 'eve',
		error_message: null,
		created_at: '2026-07-27T10:00:00Z',
		updated_at: '2026-07-27T10:00:00Z'
	});
	database.shareTexts.push({
		share_token: token,
		generation: 'generation-icloud',
		variant: 'source',
		markdown: '---\nid: \"capture-shared\"\n---\n\nShared source.',
		word_count: 2
	});

	const response = await worker.fetch(
		authenticatedRequest(`/api/public/shares/${token}/import`, {
			method: 'POST',
			headers: { Origin: 'https://library.example' }
		}),
		entitledEnvironment(database)
	);
	assert.equal(response.status, 200);
	const imported = await response.json();
	assert.equal(imported.provider, 'icloud');
	assert.equal(imported.source.filename, 'shared-through-icloud.md');
	assert.equal(imported.source.revision, 3);
	assert.equal(imported.source.texts[0].markdown.includes('Shared source.'), true);
});

test('owners can list and revoke their published links from the account', async () => {
	const database = new MockDatabase();
	const ownToken = 'A'.repeat(32);
	const otherToken = 'B'.repeat(32);
	database.shareLinks.set(ownToken, {
		token: ownToken,
		owner_email: 'reader@example.com',
		capture_id: 'capture-1',
		generation: 'generation-1',
		revision: 1,
		status: 'ready',
		metadata_json: JSON.stringify({ title: 'Published research' }),
		source_filename: 'published-research.md',
		voice: 'eve',
		error_message: null,
		created_at: '2026-07-23T10:00:00Z',
		updated_at: '2026-07-23T11:00:00Z'
	});
	database.shareLinks.set(otherToken, {
		...database.shareLinks.get(ownToken),
		token: otherToken,
		owner_email: 'other@example.com',
		capture_id: 'capture-2'
	});

	const response = await worker.fetch(
		authenticatedRequest('/api/share-links'),
		environment(database)
	);
	assert.equal(response.status, 200);
	const published = await response.json();
	assert.equal(published.limit, 200);
	assert.equal(published.links.length, 1);
	assert.equal(published.links[0].token, ownToken);
	assert.equal(published.links[0].captureID, 'capture-1');
	assert.equal(published.links[0].metadata.title, 'Published research');

	const revoked = await worker.fetch(
		authenticatedRequest(`/api/share-links/${ownToken}`, {
			method: 'DELETE',
			headers: { Origin: 'https://library.example' }
		}),
		environment(database)
	);
	assert.equal(revoked.status, 200);
	assert.equal(database.shareLinks.has(ownToken), false);
});

test('an account can update at 200 active links but cannot publish a 201st', async () => {
	const database = new MockDatabase();
	for (let index = 0; index < 200; index += 1) {
		const token = index.toString(36).padStart(32, '0');
		database.shareLinks.set(token, {
			token,
			owner_email: 'reader@example.com',
			capture_id: `capture-${index}`,
			generation: `generation-${index}`,
			revision: 1,
			status: 'ready',
			metadata_json: null,
			source_filename: null,
			voice: 'eve',
			error_message: null,
			created_at: '2026-07-23T10:00:00Z',
			updated_at: '2026-07-23T10:00:00Z'
		});
	}
	const request = (captureID) =>
		authenticatedRequest('/api/share-links', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({ captureID, voice: 'eve' })
		});

	const denied = await worker.fetch(request('capture-200'), entitledEnvironment(database));
	assert.equal(denied.status, 409);
	assert.equal((await denied.json()).code, 'share_limit_reached');
	assert.equal(database.shareLinks.size, 200);

	let backgroundTask;
	const updated = await worker.fetch(
		request('capture-0'),
		entitledEnvironment(database),
		{
			waitUntil(task) {
				backgroundTask = task;
			}
		}
	);
	assert.equal(updated.status, 202);
	assert.equal((await updated.json()).revision, 2);
	await backgroundTask;
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
		'https://www.googleapis.com/auth/drive.file'
	);
});

test('sync provider selection is independent from account sign-in', async () => {
	const database = new MockDatabase();
	const env = environment(database);
	const response = await worker.fetch(
		authenticatedRequest('/api/sync/provider', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({ provider: 'icloud' })
		}),
		env
	);
	assert.equal(response.status, 200);
	assert.deepEqual(await response.json(), { provider: 'icloud' });
	assert.equal(database.syncPreferences.get('reader@example.com'), 'icloud');

	const status = await worker.fetch(authenticatedRequest('/api/auth/status'), env);
	assert.equal((await status.json()).syncProvider, 'icloud');
});

test('library file access rejects paths outside the mirrored workspace', async () => {
	const response = await worker.fetch(
		authenticatedRequest(
			`/api/library/file?path=${encodeURIComponent('../secrets.md')}&hash=${'a'.repeat(64)}`
		),
		entitledEnvironment()
	);
	assert.equal(response.status, 400);
	assert.deepEqual(await response.json(), { error: 'Invalid library file request.' });
});

test('audio mirror listing requires an authenticated account', async () => {
	const response = await worker.fetch(
		new Request('https://library.example/api/media/audio'),
		stripeEnvironment()
	);
	assert.equal(response.status, 401);
	assert.deepEqual(await response.json(), {
		error: 'Sign in before using Briefly Plus.',
		code: 'authentication_required'
	});
});

test('GitHub endpoints are no longer exposed', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/github/status'),
		environment()
	);
	assert.equal(response.status, 404);
});

test('user-managed OpenRouter OAuth endpoints are no longer exposed', async () => {
	for (const path of [
		'/api/openrouter/status',
		'/api/openrouter/connect/start',
		'/api/openrouter/connect/callback?state=pending&code=authorization'
	]) {
		const response = await worker.fetch(authenticatedRequest(path), environment());
		assert.equal(response.status, 404);
	}
});

test('credential and media mutations reject cross-origin requests', async () => {
	const env = entitledEnvironment();
	const mutations = [
		{ path: '/api/tts', body: { input: 'Hello', voice: 'eve' } },
		{ path: '/api/tts/checkout', body: { amountCents: 500 } },
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

test('speech requires prepaid credit before making a provider request', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json',
				'X-Briefly-Request-Id': crypto.randomUUID()
			},
			body: JSON.stringify({ input: 'Hello', voice: 'af_heart' })
		}),
		environment()
	);
	assert.equal(response.status, 402);
	assert.deepEqual(await response.json(), {
		error: 'Not enough Briefly AI voice credit. Top up in Settings.'
	});
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
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json',
				'X-Briefly-Request-Id': crypto.randomUUID()
			},
			body: JSON.stringify({
				input: 'Hello',
				voice: 'af_heart',
				model: 'hexgrad/kokoro-82m'
			})
		}),
		environment()
	);
	assert.equal(response.status, 402);
	assert.deepEqual(await response.json(), {
		error: 'Not enough Briefly AI voice credit. Top up in Settings.'
	});
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

test('failed provider speech restores the reserved AI voice credit', async (context) => {
	const database = new MockDatabase();
	const env = fundedTTSEnvironment(database);
	const requestID = 'c84068cb-faf5-4f06-896c-a666a768907d';
	context.mock.method(globalThis, 'fetch', async () =>
		Response.json({ error: { message: 'Provider unavailable.' } }, { status: 503 })
	);
	const response = await worker.fetch(
		authenticatedRequest('/api/tts', {
			method: 'POST',
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json',
				'X-Briefly-Request-Id': requestID
			},
			body: JSON.stringify({
				input: 'Hello',
				voice: 'af_heart',
				model: 'hexgrad/kokoro-82m'
			})
		}),
		env
	);
	assert.equal(response.status, 503);
	assert.equal(database.ttsAccounts.get('account-reader').balance_micros, 500_000_000);
	assert.equal(database.ttsUsage.get(requestID).status, 'released');
});

test('AI voice credit has no refund endpoint', async () => {
	const response = await worker.fetch(
		authenticatedRequest('/api/tts/refund', {
			method: 'POST',
			headers: { Origin: 'https://library.example' }
		}),
		stripeEnvironment()
	);
	assert.equal(response.status, 404);
});

test('speech forwards provider audio progressively', async (context) => {
	const database = new MockDatabase();
	let providerController;
	context.mock.method(globalThis, 'fetch', async (input, init) => {
		assert.equal(String(input), 'https://openrouter.ai/api/v1/audio/speech');
		assert.equal(init.headers.Authorization, 'Bearer sk-or-managed');
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
			headers: {
				Origin: 'https://library.example',
				'Content-Type': 'application/json',
				'X-Briefly-Request-Id': crypto.randomUUID()
			},
			body: JSON.stringify({
				input: 'A longer streaming example.',
				voice: 'eve',
				model: 'x-ai/grok-voice-tts-1.0'
			})
		}),
		fundedTTSEnvironment(database)
	);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get('X-Generation-Id'), 'generation-1');
	assert.equal(
		response.headers.get('X-Briefly-TTS-Balance-Micros'),
		String(500_000_000 - 27 * 1800)
	);
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
