CREATE TABLE `feedback_items` (
	`id` text PRIMARY KEY NOT NULL,
	`user_email` text NOT NULL,
	`title` text NOT NULL,
	`details` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `feedback_upvotes` (
	`feedback_item_id` text NOT NULL,
	`user_email` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`feedback_item_id`, `user_email`),
	FOREIGN KEY (`feedback_item_id`) REFERENCES `feedback_items`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `feedback_upvotes_item_idx` ON `feedback_upvotes` (`feedback_item_id`);