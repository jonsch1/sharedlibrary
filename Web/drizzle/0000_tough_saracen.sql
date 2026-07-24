CREATE TABLE `openrouter_credentials` (
	`user_email` text PRIMARY KEY NOT NULL,
	`encrypted_api_key` text NOT NULL,
	`initialization_vector` text NOT NULL,
	`openrouter_user_id` text,
	`connected_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `openrouter_oauth_states` (
	`state` text PRIMARY KEY NOT NULL,
	`user_email` text NOT NULL,
	`code_verifier` text NOT NULL,
	`created_at` integer NOT NULL
);
