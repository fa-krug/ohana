CREATE TABLE `holiday_cache` (
	`country` text NOT NULL,
	`kind` text NOT NULL,
	`year` integer NOT NULL,
	`data` text NOT NULL,
	`fetched_at` integer NOT NULL,
	PRIMARY KEY(`country`, `kind`, `year`)
);
--> statement-breakpoint
CREATE TABLE `holiday_days` (
	`family_id` text NOT NULL,
	`kind` text NOT NULL,
	`day` text NOT NULL,
	PRIMARY KEY(`family_id`, `kind`, `day`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `holiday_settings` (
	`family_id` text PRIMARY KEY NOT NULL,
	`public_holidays` integer DEFAULT false NOT NULL,
	`school_holidays` integer DEFAULT false NOT NULL,
	`region` text,
	`region_auto` integer DEFAULT true NOT NULL,
	`region_from` text,
	`region_names` text,
	`synced_region` text,
	`import_from` text,
	`requested_at` integer,
	`synced_at` integer,
	`status` text,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `holiday_settings_requested_idx` ON `holiday_settings` (`requested_at`);