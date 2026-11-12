CREATE TABLE `fin_insight_dismissals` (
	`family_id` text NOT NULL,
	`key` text NOT NULL,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `key`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
