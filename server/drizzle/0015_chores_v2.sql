CREATE TABLE `chore_completions` (
	`chore_id` text NOT NULL,
	`day` text NOT NULL,
	`done_by_id` text,
	`done_at` integer NOT NULL,
	PRIMARY KEY(`chore_id`, `day`),
	FOREIGN KEY (`chore_id`) REFERENCES `chores`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`done_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE TABLE `chore_notified` (
	`chore_id` text NOT NULL,
	`day` text NOT NULL,
	`sent_at` integer NOT NULL,
	PRIMARY KEY(`chore_id`, `day`),
	FOREIGN KEY (`chore_id`) REFERENCES `chores`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `chore_subscribers` (
	`chore_id` text NOT NULL,
	`user_id` text NOT NULL,
	PRIMARY KEY(`chore_id`, `user_id`),
	FOREIGN KEY (`chore_id`) REFERENCES `chores`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
ALTER TABLE `chores` ADD `part` text DEFAULT 'day' NOT NULL;--> statement-breakpoint
ALTER TABLE `chores` ADD `done_by_id` text REFERENCES users(id) ON DELETE set null;