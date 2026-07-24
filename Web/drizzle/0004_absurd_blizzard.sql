CREATE TABLE `share_audio_segments` (
	`share_token` text NOT NULL,
	`generation` text NOT NULL,
	`variant` text NOT NULL,
	`segment_index` integer NOT NULL,
	`audio_hash` text NOT NULL,
	`r2_key` text NOT NULL,
	`content_type` text NOT NULL,
	`byte_count` integer NOT NULL,
	`voice` text NOT NULL,
	PRIMARY KEY(`share_token`, `generation`, `variant`, `segment_index`)
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
	`voice` text NOT NULL,
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
--> statement-breakpoint
DROP TABLE `shared_folder_connections`;--> statement-breakpoint
DROP TABLE `sharing_operations`;