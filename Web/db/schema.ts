import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core';

export const openRouterCredentials = sqliteTable('openrouter_credentials', {
	userEmail: text('user_email').primaryKey(),
	encryptedAPIKey: text('encrypted_api_key').notNull(),
	initializationVector: text('initialization_vector').notNull(),
	openRouterUserID: text('openrouter_user_id'),
	connectedAt: text('connected_at').notNull(),
	updatedAt: text('updated_at').notNull()
});

export const openRouterOAuthStates = sqliteTable('openrouter_oauth_states', {
	state: text('state').primaryKey(),
	userEmail: text('user_email').notNull(),
	codeVerifier: text('code_verifier').notNull(),
	createdAt: integer('created_at').notNull()
});

export const googleDriveConnections = sqliteTable('google_drive_connections', {
	userEmail: text('user_email').primaryKey(),
	clientID: text('client_id').notNull(),
	encryptedClientSecret: text('encrypted_client_secret').notNull(),
	clientSecretIV: text('client_secret_iv').notNull(),
	encryptedAccessToken: text('encrypted_access_token'),
	accessTokenIV: text('access_token_iv'),
	encryptedRefreshToken: text('encrypted_refresh_token'),
	refreshTokenIV: text('refresh_token_iv'),
	accessTokenExpiresAt: integer('access_token_expires_at'),
	folderID: text('folder_id'),
	connectedAt: text('connected_at'),
	updatedAt: text('updated_at').notNull()
});

export const googleOAuthStates = sqliteTable('google_oauth_states', {
	state: text('state').primaryKey(),
	userEmail: text('user_email').notNull(),
	codeVerifier: text('code_verifier').notNull(),
	createdAt: integer('created_at').notNull()
});

export const billingCustomers = sqliteTable(
	'billing_customers',
	{
		userEmail: text('user_email').primaryKey(),
		accountID: text('account_id').notNull(),
		stripeCustomerID: text('stripe_customer_id'),
		createdAt: integer('created_at').notNull(),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [
		uniqueIndex('billing_customers_account_id_unique').on(table.accountID),
		uniqueIndex('billing_customers_stripe_customer_id_unique').on(table.stripeCustomerID)
	]
);

export const billingSubscriptions = sqliteTable(
	'billing_subscriptions',
	{
		accountID: text('account_id').primaryKey(),
		stripeSubscriptionID: text('stripe_subscription_id').notNull(),
		stripeCustomerID: text('stripe_customer_id').notNull(),
		stripePriceID: text('stripe_price_id'),
		tierKey: text('tier_key').notNull(),
		status: text('status').notNull(),
		statusChangedAt: integer('status_changed_at').notNull().default(0),
		stripeCreatedAt: integer('stripe_created_at').notNull().default(0),
		currentPeriodEnd: integer('current_period_end'),
		cancelAtPeriodEnd: integer('cancel_at_period_end').notNull().default(0),
		createdAt: integer('created_at').notNull(),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [
		uniqueIndex('billing_subscriptions_stripe_subscription_id_unique').on(
			table.stripeSubscriptionID
		)
	]
);

export const billingCheckoutReservations = sqliteTable(
	'billing_checkout_reservations',
	{
		reservationID: text('reservation_id').primaryKey(),
		accountID: text('account_id').notNull(),
		tierKey: text('tier_key').notNull(),
		stripeSessionID: text('stripe_session_id'),
		expiresAt: integer('expires_at').notNull(),
		createdAt: integer('created_at').notNull()
	},
	(table) => [
		uniqueIndex('billing_checkout_reservations_account_id_unique').on(table.accountID)
	]
);

export const billingAllocations = sqliteTable('billing_allocations', {
	reservationID: text('reservation_id').primaryKey(),
	accountID: text('account_id').notNull(),
	tierKey: text('tier_key').notNull(),
	allocatedAt: integer('allocated_at').notNull()
});

export const stripeWebhookEvents = sqliteTable('stripe_webhook_events', {
	eventID: text('event_id').primaryKey(),
	eventType: text('event_type').notNull(),
	status: text('status').notNull().default('processed'),
	attempts: integer('attempts').notNull().default(1),
	processedAt: integer('processed_at').notNull()
});

export const ttsAccounts = sqliteTable('tts_accounts', {
	accountID: text('account_id').primaryKey(),
	balanceMicros: integer('balance_micros').notNull().default(0),
	createdAt: integer('created_at').notNull(),
	updatedAt: integer('updated_at').notNull()
});

export const ttsWelcomeCredits = sqliteTable('tts_welcome_credits', {
	accountID: text('account_id').primaryKey(),
	stripeCheckoutSessionID: text('stripe_checkout_session_id').notNull().unique(),
	amountMicros: integer('amount_micros').notNull(),
	createdAt: integer('created_at').notNull(),
	creditedAt: integer('credited_at')
});

export const ttsTopUps = sqliteTable(
	'tts_topups',
	{
		checkoutSessionID: text('checkout_session_id').primaryKey(),
		accountID: text('account_id').notNull(),
		stripePaymentIntentID: text('stripe_payment_intent_id').notNull(),
		amountMicros: integer('amount_micros').notNull(),
		refundedMicros: integer('refunded_micros').notNull().default(0),
		refundStatus: text('refund_status').notNull().default('disabled'),
		createdAt: integer('created_at').notNull(),
		creditedAt: integer('credited_at'),
		refundedAt: integer('refunded_at')
	},
	(table) => [
		uniqueIndex('tts_topups_stripe_payment_intent_id_unique').on(
			table.stripePaymentIntentID
		),
		index('tts_topups_account_created_idx').on(table.accountID, table.createdAt)
	]
);

export const ttsUsage = sqliteTable(
	'tts_usage',
	{
		requestID: text('request_id').primaryKey(),
		accountID: text('account_id').notNull(),
		model: text('model').notNull(),
		voice: text('voice').notNull(),
		characterCount: integer('character_count').notNull(),
		amountMicros: integer('amount_micros').notNull(),
		status: text('status').notNull(),
		generationID: text('generation_id'),
		createdAt: integer('created_at').notNull(),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [index('tts_usage_account_created_idx').on(table.accountID, table.createdAt)]
);

export const shareLinks = sqliteTable(
	'share_links',
	{
		token: text('token').primaryKey(),
		ownerEmail: text('owner_email').notNull(),
		captureID: text('capture_id').notNull(),
		generation: text('generation').notNull(),
		revision: integer('revision').notNull().default(1),
		status: text('status').notNull(),
		metadataJSON: text('metadata_json'),
		sourceFilename: text('source_filename'),
		voice: text('voice').notNull(),
		errorMessage: text('error_message'),
		createdAt: text('created_at').notNull(),
		updatedAt: text('updated_at').notNull()
	},
	(table) => [
		uniqueIndex('share_links_owner_capture_unique').on(table.ownerEmail, table.captureID)
	]
);

export const shareTexts = sqliteTable(
	'share_texts',
	{
		shareToken: text('share_token').notNull(),
		generation: text('generation').notNull(),
		variant: text('variant').notNull(),
		markdown: text('markdown').notNull(),
		wordCount: integer('word_count').notNull()
	},
	(table) => [
		primaryKey({ columns: [table.shareToken, table.generation, table.variant] })
	]
);

export const shareAudioSegments = sqliteTable(
	'share_audio_segments',
	{
		shareToken: text('share_token').notNull(),
		generation: text('generation').notNull(),
		variant: text('variant').notNull(),
		segmentIndex: integer('segment_index').notNull(),
		audioHash: text('audio_hash').notNull(),
		r2Key: text('r2_key').notNull(),
		contentType: text('content_type').notNull(),
		byteCount: integer('byte_count').notNull(),
		voice: text('voice').notNull()
	},
	(table) => [
		primaryKey({
			columns: [table.shareToken, table.generation, table.variant, table.segmentIndex]
		})
	]
);

export const feedbackItems = sqliteTable('feedback_items', {
	id: text('id').primaryKey(),
	userEmail: text('user_email').notNull(),
	title: text('title').notNull(),
	details: text('details').notNull(),
	createdAt: integer('created_at').notNull()
});

export const feedbackUpvotes = sqliteTable(
	'feedback_upvotes',
	{
		feedbackItemID: text('feedback_item_id')
			.notNull()
			.references(() => feedbackItems.id, { onDelete: 'cascade' }),
		userEmail: text('user_email').notNull(),
		createdAt: integer('created_at').notNull()
	},
	(table) => [
		primaryKey({ columns: [table.feedbackItemID, table.userEmail] }),
		index('feedback_upvotes_item_idx').on(table.feedbackItemID)
	]
);
