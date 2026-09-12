CREATE TABLE `apple_authorizations` (
	`subject` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`refresh_token` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
