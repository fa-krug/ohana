CREATE TABLE `chore_day_parts` (
	`family_id` text PRIMARY KEY NOT NULL,
	`morning` text NOT NULL,
	`day` text NOT NULL,
	`evening` text NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
-- The evening now starts at 18:00 by default (it was 17:00 for a chore's time, 18:00 for its
-- notification): chores at 17:xx belong to the day.
UPDATE `chores` SET `part` = 'day' WHERE `time` >= '17:00' AND `time` < '18:00';
