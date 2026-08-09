import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core';

export const appleLoginStates = sqliteTable('apple_login_states', {
	state: text('state').primaryKey(),
	nonce: text('nonce').notNull(),
	returnTo: text('return_to').notNull(),
	createdAt: integer('created_at').notNull()
});

export const authIdentities = sqliteTable(
	'auth_identities',
	{
		provider: text('provider').notNull(),
		subject: text('subject').notNull(),
		userEmail: text('user_email').notNull(),
		createdAt: integer('created_at').notNull()
	},
	(table) => [primaryKey({ columns: [table.provider, table.subject] })]
);

export const appleAuthorizations = sqliteTable('apple_authorizations', {
	subject: text('subject').primaryKey(),
	clientID: text('client_id').notNull(),
	refreshToken: text('refresh_token').notNull(),
	createdAt: integer('created_at').notNull(),
	updatedAt: integer('updated_at').notNull()
});

export const appSessions = sqliteTable(
	'app_sessions',
	{
		tokenHash: text('token_hash').primaryKey(),
		userEmail: text('user_email').notNull(),
		createdAt: integer('created_at').notNull(),
		expiresAt: integer('expires_at').notNull()
	},
	(table) => [index('app_sessions_user_email_idx').on(table.userEmail)]
);

export const accounts = sqliteTable(
	'accounts',
	{
		userEmail: text('user_email').primaryKey(),
		accountID: text('account_id').notNull(),
		createdAt: integer('created_at').notNull(),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [uniqueIndex('accounts_account_id_unique').on(table.accountID)]
);

export const appStoreSubscriptions = sqliteTable(
	'app_store_subscriptions',
	{
		originalTransactionID: text('original_transaction_id').primaryKey(),
		accountID: text('account_id').notNull(),
		transactionID: text('transaction_id').notNull(),
		productID: text('product_id').notNull(),
		environment: text('environment').notNull(),
		expiresAt: integer('expires_at').notNull(),
		revocationDate: integer('revocation_date'),
		signedAt: integer('signed_at').notNull(),
		createdAt: integer('created_at').notNull(),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [
		uniqueIndex('app_store_subscriptions_transaction_id_unique').on(table.transactionID),
		index('app_store_subscriptions_account_expires_idx').on(table.accountID, table.expiresAt)
	]
);

export const complimentaryAccess = sqliteTable('complimentary_access', {
	userEmail: text('user_email').primaryKey(),
	grantedBy: text('granted_by').notNull(),
	createdAt: integer('created_at').notNull()
});


export const managedAIUsage = sqliteTable(
	'managed_ai_usage',
	{
		accountID: text('account_id').notNull(),
		usageMonth: text('usage_month').notNull(),
		spentMicros: integer('spent_micros').notNull().default(0),
		reservedMicros: integer('reserved_micros').notNull().default(0),
		reservationID: text('reservation_id'),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [primaryKey({ columns: [table.accountID, table.usageMonth] })]
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

export const contentReports = sqliteTable(
	'content_reports',
	{
		id: text('id').primaryKey(),
		shareToken: text('share_token').notNull(),
		ownerEmail: text('owner_email').notNull(),
		captureID: text('capture_id').notNull(),
		shareTitle: text('share_title').notNull(),
		reportedURL: text('reported_url').notNull(),
		variant: text('variant'),
		category: text('category').notNull(),
		reporterName: text('reporter_name'),
		reporterEmail: text('reporter_email'),
		workDescription: text('work_description'),
		explanation: text('explanation').notNull(),
		status: text('status').notNull().default('open'),
		createdAt: integer('created_at').notNull(),
		resolvedAt: integer('resolved_at')
	},
	(table) => [
		index('content_reports_status_created_idx').on(table.status, table.createdAt),
		index('content_reports_owner_capture_idx').on(table.ownerEmail, table.captureID)
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

export const serviceUsage = sqliteTable(
	'service_usage',
	{
		accountID: text('account_id').notNull(),
		service: text('service').notNull(),
		usageDay: text('usage_day').notNull(),
		units: integer('units').notNull().default(0),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [
		primaryKey({ columns: [table.accountID, table.service, table.usageDay] })
	]
);

export const serviceLimitOverrides = sqliteTable(
	'service_limit_overrides',
	{
		accountID: text('account_id').notNull(),
		service: text('service').notNull(),
		dailyUnits: integer('daily_units').notNull(),
		monthlyUnits: integer('monthly_units').notNull(),
		concurrency: integer('concurrency').notNull(),
		updatedAt: integer('updated_at').notNull()
	},
	(table) => [primaryKey({ columns: [table.accountID, table.service] })]
);

export const serviceLeases = sqliteTable(
	'service_leases',
	{
		leaseID: text('lease_id').primaryKey(),
		accountID: text('account_id').notNull(),
		service: text('service').notNull(),
		expiresAt: integer('expires_at').notNull(),
		createdAt: integer('created_at').notNull()
	},
	(table) => [
		index('service_leases_account_service_idx').on(
			table.accountID,
			table.service,
			table.expiresAt
		)
	]
);
