import { integer, primaryKey, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core';

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
