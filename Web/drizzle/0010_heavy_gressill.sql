CREATE TABLE `tts_monthly_credits` (
	`account_id` text NOT NULL,
	`credit_month` text NOT NULL,
	`amount_micros` integer NOT NULL,
	`created_at` integer NOT NULL,
	`credited_at` integer,
	PRIMARY KEY(`account_id`, `credit_month`)
);
