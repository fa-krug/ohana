CREATE TABLE `cal_events` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`day` text NOT NULL,
	`start` text,
	`end` text,
	`title` text NOT NULL,
	`location` text DEFAULT '' NOT NULL,
	`person` text DEFAULT '' NOT NULL,
	`note` text DEFAULT '' NOT NULL,
	`url` text DEFAULT '' NOT NULL,
	`source` text DEFAULT 'manual' NOT NULL,
	`source_id` text,
	`source_item` text,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `cal_events_family_day_idx` ON `cal_events` (`family_id`,`day`);--> statement-breakpoint
CREATE TABLE `notification_prefs` (
	`family_id` text NOT NULL,
	`event` text NOT NULL,
	`enabled` integer NOT NULL,
	`channel_ids` text,
	`state` text DEFAULT '{}' NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `event`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
ALTER TABLE `cal_entry_types` ADD `away` integer DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE `fin_settings` ADD `groceries_category_id` text;