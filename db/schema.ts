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
