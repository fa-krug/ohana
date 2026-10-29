CREATE TABLE `family_people` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`name` text NOT NULL,
	`birthday` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `family_people_family_name_idx` ON `family_people` (`family_id`,`name`);--> statement-breakpoint
ALTER TABLE `family_members` ADD `birthday` text;--> statement-breakpoint
ALTER TABLE `invites` ADD `person_id` text REFERENCES family_people(id) ON DELETE cascade;