CREATE TABLE IF NOT EXISTS `shared_folder_connections` (
	`user_email` text PRIMARY KEY NOT NULL,
	`folder_id` text NOT NULL,
	`user_id` text NOT NULL,
	`username` text NOT NULL,
	`connected_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `sharing_operations` (
	`user_email` text NOT NULL,
	`capture_id` text NOT NULL,
	`recipient_ids` text NOT NULL,
	`generation` text NOT NULL,
	`status` text NOT NULL,
	`attempt_count` integer DEFAULT 0 NOT NULL,
	`last_error` text,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	PRIMARY KEY(`user_email`, `capture_id`)
);
