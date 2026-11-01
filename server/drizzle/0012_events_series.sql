DROP INDEX `families_feed_id_unique`;--> statement-breakpoint
DROP INDEX `families_legacy_id_unique`;--> statement-breakpoint
ALTER TABLE `families` DROP COLUMN `feed_id`;--> statement-breakpoint
ALTER TABLE `families` DROP COLUMN `legacy_id`;--> statement-breakpoint
CREATE TABLE `__new_cal_events` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`day` text NOT NULL,
	`end_day` text NOT NULL,
	`start` text,
	`end` text,
	`title` text NOT NULL,
	`location` text DEFAULT '' NOT NULL,
	`person` text DEFAULT '' NOT NULL,
	`note` text DEFAULT '' NOT NULL,
	`url` text DEFAULT '' NOT NULL,
	`rrule` text,
	`exdates` text DEFAULT '[]' NOT NULL,
	`series_id` text,
	`occurrence` text,
	`source` text DEFAULT 'manual' NOT NULL,
	`source_id` text,
	`source_item` text,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`series_id`) REFERENCES `cal_events`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
INSERT INTO `__new_cal_events` (`id`, `family_id`, `day`, `end_day`, `start`, `end`, `title`, `location`, `person`, `note`, `url`, `source`, `source_id`, `source_item`, `created_by_id`, `created_at`)
SELECT `id`, `family_id`, `day`, `day`, `start`, `end`, `title`, `location`, `person`, `note`, `url`, `source`, `source_id`, `source_item`, `created_by_id`, `created_at` FROM `cal_events`;--> statement-breakpoint
DROP TABLE `cal_events`;--> statement-breakpoint
ALTER TABLE `__new_cal_events` RENAME TO `cal_events`;--> statement-breakpoint
CREATE INDEX `cal_events_family_day_idx` ON `cal_events` (`family_id`,`day`);--> statement-breakpoint
CREATE UNIQUE INDEX `cal_events_series_occurrence_idx` ON `cal_events` (`series_id`,`occurrence`);
