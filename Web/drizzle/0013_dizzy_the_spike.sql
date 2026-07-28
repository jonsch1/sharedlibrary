CREATE TABLE IF NOT EXISTS `app_sessions` (
	`token_hash` text PRIMARY KEY NOT NULL,
	`user_email` text NOT NULL,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `app_sessions_user_email_idx` ON `app_sessions` (`user_email`);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `complimentary_access` (
	`user_email` text PRIMARY KEY NOT NULL,
	`granted_by` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `google_login_states` (
	`state` text PRIMARY KEY NOT NULL,
	`code_verifier` text NOT NULL,
	`return_to` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `service_leases` (
	`lease_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`service` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `service_leases_account_service_idx` ON `service_leases` (`account_id`,`service`,`expires_at`);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `service_usage` (
	`account_id` text NOT NULL,
	`service` text NOT NULL,
	`usage_day` text NOT NULL,
	`units` integer DEFAULT 0 NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`account_id`, `service`, `usage_day`)
);
