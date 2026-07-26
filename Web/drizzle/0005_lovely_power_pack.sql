CREATE TABLE `billing_allocations` (
	`reservation_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`tier_key` text NOT NULL,
	`allocated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `billing_checkout_reservations` (
	`reservation_id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`tier_key` text NOT NULL,
	`stripe_session_id` text,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `billing_checkout_reservations_account_id_unique` ON `billing_checkout_reservations` (`account_id`);--> statement-breakpoint
CREATE TABLE `billing_customers` (
	`user_email` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`stripe_customer_id` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `billing_customers_account_id_unique` ON `billing_customers` (`account_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `billing_customers_stripe_customer_id_unique` ON `billing_customers` (`stripe_customer_id`);--> statement-breakpoint
CREATE TABLE `billing_subscriptions` (
	`account_id` text PRIMARY KEY NOT NULL,
	`stripe_subscription_id` text NOT NULL,
	`stripe_customer_id` text NOT NULL,
	`stripe_price_id` text,
	`tier_key` text NOT NULL,
	`status` text NOT NULL,
	`current_period_end` integer,
	`cancel_at_period_end` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `billing_subscriptions_stripe_subscription_id_unique` ON `billing_subscriptions` (`stripe_subscription_id`);--> statement-breakpoint
CREATE TABLE `stripe_webhook_events` (
	`event_id` text PRIMARY KEY NOT NULL,
	`event_type` text NOT NULL,
	`processed_at` integer NOT NULL
);
