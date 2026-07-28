CREATE TABLE `managed_ai_usage` (
	`account_id` text NOT NULL,
	`usage_month` text NOT NULL,
	`spent_micros` integer DEFAULT 0 NOT NULL,
	`reserved_micros` integer DEFAULT 0 NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`account_id`, `usage_month`)
);
