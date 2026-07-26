CREATE TABLE `tts_welcome_credits` (
	`account_id` text PRIMARY KEY NOT NULL,
	`stripe_checkout_session_id` text NOT NULL,
	`amount_micros` integer NOT NULL,
	`created_at` integer NOT NULL,
	`credited_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `tts_welcome_credits_stripe_checkout_session_id_unique` ON `tts_welcome_credits` (`stripe_checkout_session_id`);
