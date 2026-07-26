CREATE TABLE `tts_accounts` (
	`account_id` text PRIMARY KEY NOT NULL,
	`balance_micros` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `tts_topups` (
	`checkout_session_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`stripe_payment_intent_id` text NOT NULL,
	`amount_micros` integer NOT NULL,
	`refunded_micros` integer DEFAULT 0 NOT NULL,
	`refund_status` text DEFAULT 'disabled' NOT NULL,
	`created_at` integer NOT NULL,
	`credited_at` integer,
	`refunded_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `tts_topups_stripe_payment_intent_id_unique` ON `tts_topups` (`stripe_payment_intent_id`);--> statement-breakpoint
CREATE INDEX `tts_topups_account_created_idx` ON `tts_topups` (`account_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `tts_usage` (
	`request_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`model` text NOT NULL,
	`voice` text NOT NULL,
	`character_count` integer NOT NULL,
	`amount_micros` integer NOT NULL,
	`status` text NOT NULL,
	`generation_id` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `tts_usage_account_created_idx` ON `tts_usage` (`account_id`,`created_at`);
