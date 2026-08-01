CREATE TABLE `accounts` (
	`user_email` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `accounts_account_id_unique` ON `accounts` (`account_id`);--> statement-breakpoint
CREATE TABLE `app_sessions` (
	`token_hash` text PRIMARY KEY NOT NULL,
	`user_email` text NOT NULL,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `app_sessions_user_email_idx` ON `app_sessions` (`user_email`);--> statement-breakpoint
CREATE TABLE `app_store_subscriptions` (
	`original_transaction_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`transaction_id` text NOT NULL,
	`product_id` text NOT NULL,
	`environment` text NOT NULL,
	`expires_at` integer NOT NULL,
	`revocation_date` integer,
	`signed_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `app_store_subscriptions_transaction_id_unique` ON `app_store_subscriptions` (`transaction_id`);--> statement-breakpoint
CREATE INDEX `app_store_subscriptions_account_expires_idx` ON `app_store_subscriptions` (`account_id`,`expires_at`);--> statement-breakpoint
CREATE TABLE `apple_login_states` (
	`state` text PRIMARY KEY NOT NULL,
	`nonce` text NOT NULL,
	`return_to` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `auth_identities` (
	`provider` text NOT NULL,
	`subject` text NOT NULL,
	`user_email` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`provider`, `subject`)
);
--> statement-breakpoint
CREATE TABLE `complimentary_access` (
	`user_email` text PRIMARY KEY NOT NULL,
	`granted_by` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `content_reports` (
	`id` text PRIMARY KEY NOT NULL,
	`share_token` text NOT NULL,
	`owner_email` text NOT NULL,
	`capture_id` text NOT NULL,
	`share_title` text NOT NULL,
	`reported_url` text NOT NULL,
	`variant` text,
	`category` text NOT NULL,
	`reporter_name` text,
	`reporter_email` text,
	`work_description` text,
	`explanation` text NOT NULL,
	`status` text DEFAULT 'open' NOT NULL,
	`created_at` integer NOT NULL,
	`resolved_at` integer
);
--> statement-breakpoint
CREATE INDEX `content_reports_status_created_idx` ON `content_reports` (`status`,`created_at`);--> statement-breakpoint
CREATE INDEX `content_reports_owner_capture_idx` ON `content_reports` (`owner_email`,`capture_id`);--> statement-breakpoint
CREATE TABLE `feedback_items` (
	`id` text PRIMARY KEY NOT NULL,
	`user_email` text NOT NULL,
	`title` text NOT NULL,
	`details` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `feedback_upvotes` (
	`feedback_item_id` text NOT NULL,
	`user_email` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`feedback_item_id`, `user_email`),
	FOREIGN KEY (`feedback_item_id`) REFERENCES `feedback_items`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `feedback_upvotes_item_idx` ON `feedback_upvotes` (`feedback_item_id`);--> statement-breakpoint
CREATE TABLE `managed_ai_usage` (
	`account_id` text NOT NULL,
	`usage_month` text NOT NULL,
	`spent_micros` integer DEFAULT 0 NOT NULL,
	`reserved_micros` integer DEFAULT 0 NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`account_id`, `usage_month`)
);
--> statement-breakpoint
CREATE TABLE `service_leases` (
	`lease_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`service` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `service_leases_account_service_idx` ON `service_leases` (`account_id`,`service`,`expires_at`);--> statement-breakpoint
CREATE TABLE `service_limit_overrides` (
	`account_id` text NOT NULL,
	`service` text NOT NULL,
	`daily_units` integer NOT NULL,
	`monthly_units` integer NOT NULL,
	`concurrency` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`account_id`, `service`)
);
--> statement-breakpoint
CREATE TABLE `service_usage` (
	`account_id` text NOT NULL,
	`service` text NOT NULL,
	`usage_day` text NOT NULL,
	`units` integer DEFAULT 0 NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`account_id`, `service`, `usage_day`)
);
--> statement-breakpoint
CREATE TABLE `share_links` (
	`token` text PRIMARY KEY NOT NULL,
	`owner_email` text NOT NULL,
	`capture_id` text NOT NULL,
	`generation` text NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`status` text NOT NULL,
	`metadata_json` text,
	`source_filename` text,
	`error_message` text,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `share_links_owner_capture_unique` ON `share_links` (`owner_email`,`capture_id`);--> statement-breakpoint
CREATE TABLE `share_texts` (
	`share_token` text NOT NULL,
	`generation` text NOT NULL,
	`variant` text NOT NULL,
	`markdown` text NOT NULL,
	`word_count` integer NOT NULL,
	PRIMARY KEY(`share_token`, `generation`, `variant`)
);
