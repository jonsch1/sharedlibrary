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
CREATE TABLE `share_media_deletions` (
	`r2_key` text PRIMARY KEY NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
INSERT OR IGNORE INTO `share_media_deletions` (`r2_key`, `created_at`)
	SELECT `r2_key`, CAST(strftime('%s', 'now') AS integer) * 1000
	FROM `share_audio_segments`;
--> statement-breakpoint
DELETE FROM `share_audio_segments`;
--> statement-breakpoint
DELETE FROM `share_texts` WHERE `variant` = 'source';
--> statement-breakpoint
UPDATE `share_links`
SET
	`status` = 'failed',
	`error_message` = 'No summary is available to share.',
	`updated_at` = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE NOT EXISTS (
	SELECT 1 FROM `share_texts`
	WHERE `share_texts`.`share_token` = `share_links`.`token`
);
