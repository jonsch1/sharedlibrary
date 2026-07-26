CREATE TABLE `apple_login_states` (
	`state` text PRIMARY KEY NOT NULL,
	`nonce` text NOT NULL,
	`return_to` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `auth_identities` (
	`provider` text NOT NULL,
	`subject` text NOT NULL,
	`user_email` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`provider`, `subject`)
);
--> statement-breakpoint
CREATE TABLE `sync_preferences` (
	`user_email` text PRIMARY KEY NOT NULL,
	`provider` text NOT NULL,
	`updated_at` integer NOT NULL
);
