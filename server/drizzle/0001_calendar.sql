CREATE TABLE `cal_entries` (
	`family_id` text NOT NULL,
	`day` text NOT NULL,
	`year` integer NOT NULL,
	`type_id` text NOT NULL,
	PRIMARY KEY(`family_id`, `day`, `type_id`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`family_id`,`year`,`type_id`) REFERENCES `cal_entry_types`(`family_id`,`year`,`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "cal_entries_year_of_day" CHECK("cal_entries"."year" = cast(substr("cal_entries"."day", 1, 4) as integer))
);
--> statement-breakpoint
CREATE INDEX `cal_entries_type_idx` ON `cal_entries` (`family_id`,`year`,`type_id`);--> statement-breakpoint
CREATE TABLE `cal_entry_types` (
	`family_id` text NOT NULL,
	`year` integer NOT NULL,
	`id` text NOT NULL,
	`name` text NOT NULL,
	`color` text NOT NULL,
	`role` text DEFAULT 'none' NOT NULL,
	`position` integer DEFAULT 0 NOT NULL,
	PRIMARY KEY(`family_id`, `year`, `id`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `cal_notes` (
	`family_id` text NOT NULL,
	`day` text NOT NULL,
	`icon` text DEFAULT '' NOT NULL,
	`comment` text DEFAULT '' NOT NULL,
	PRIMARY KEY(`family_id`, `day`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
-- SQLite can't add a NOT NULL column without a default: add it with '' and give every
-- existing family its own random feed id (20 hex characters) before the unique index.
ALTER TABLE `families` ADD `feed_id` text DEFAULT '' NOT NULL;--> statement-breakpoint
UPDATE `families` SET `feed_id` = lower(hex(randomblob(10))) WHERE `feed_id` = '';--> statement-breakpoint
ALTER TABLE `families` ADD `legacy_id` text;--> statement-breakpoint
CREATE UNIQUE INDEX `families_feed_id_unique` ON `families` (`feed_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `families_legacy_id_unique` ON `families` (`legacy_id`);