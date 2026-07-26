ALTER TABLE `billing_subscriptions` ADD `status_changed_at` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `billing_subscriptions` ADD `stripe_created_at` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `stripe_webhook_events` ADD `status` text DEFAULT 'processed' NOT NULL;--> statement-breakpoint
ALTER TABLE `stripe_webhook_events` ADD `attempts` integer DEFAULT 1 NOT NULL;