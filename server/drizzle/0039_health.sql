CREATE TABLE `health_notified` (
	`family_id` text NOT NULL,
	`member_id` text NOT NULL,
	`key` text NOT NULL,
	`sent_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `member_id`, `key`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `health_records` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`member_user_id` text,
	`member_person_id` text,
	`code` text NOT NULL,
	`day` text,
	`status` text DEFAULT 'done' NOT NULL,
	`note` text DEFAULT '' NOT NULL,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`member_user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`member_person_id`) REFERENCES `family_people`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `health_records_family_idx` ON `health_records` (`family_id`);