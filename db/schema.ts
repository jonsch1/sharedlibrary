import { integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';

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
