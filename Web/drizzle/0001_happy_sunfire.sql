CREATE TABLE `github_connections` (
	`user_email` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`encrypted_access_token` text NOT NULL,
	`access_token_iv` text NOT NULL,
	`encrypted_refresh_token` text,
	`refresh_token_iv` text,
	`access_token_expires_at` integer,
	`refresh_token_expires_at` integer,
	`login` text NOT NULL,
	`repository` text,
	`default_branch` text,
	`connected_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `github_device_states` (
	`user_email` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`encrypted_device_code` text NOT NULL,
	`device_code_iv` text NOT NULL,
	`user_code` text NOT NULL,
	`verification_uri` text NOT NULL,
	`expires_at` integer NOT NULL,
	`interval_seconds` integer NOT NULL,
	`next_poll_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `google_drive_connections` (
	`user_email` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`encrypted_client_secret` text NOT NULL,
	`client_secret_iv` text NOT NULL,
	`encrypted_access_token` text,
	`access_token_iv` text,
	`encrypted_refresh_token` text,
	`refresh_token_iv` text,
	`access_token_expires_at` integer,
	`folder_id` text,
	`connected_at` text,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `google_oauth_states` (
	`state` text PRIMARY KEY NOT NULL,
	`user_email` text NOT NULL,
	`code_verifier` text NOT NULL,
	`created_at` integer NOT NULL
);
