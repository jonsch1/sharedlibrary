CREATE TABLE `service_limit_overrides` (
	`account_id` text NOT NULL,
	`service` text NOT NULL,
	`daily_units` integer NOT NULL,
	`monthly_units` integer NOT NULL,
	`concurrency` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`account_id`, `service`)
);
