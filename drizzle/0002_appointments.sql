CREATE TABLE `notification_channels` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`name` text NOT NULL,
	`provider` text DEFAULT 'PUSHBULLET' NOT NULL,
	`token` text DEFAULT '' NOT NULL,
	`target` text DEFAULT '' NOT NULL,
	`smtp_host` text DEFAULT '' NOT NULL,
	`smtp_port` integer DEFAULT 465 NOT NULL,
	`smtp_username` text DEFAULT '' NOT NULL,
	`smtp_from` text DEFAULT '' NOT NULL,
	`enabled` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `notification_channels_family_idx` ON `notification_channels` (`family_id`);--> statement-breakpoint
CREATE TABLE `appt_ignored` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`search_id` text NOT NULL,
	`provider_slug` text NOT NULL,
	`source` text DEFAULT 'doctolib' NOT NULL,
	`motive_id` integer NOT NULL,
	`doctor_name` text DEFAULT '' NOT NULL,
	`motive_label` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`search_id`) REFERENCES `appt_searches`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `appt_ignored_uniq` ON `appt_ignored` (`search_id`,`source`,`provider_slug`,`motive_id`);--> statement-breakpoint
CREATE TABLE `appt_profile_cache` (
	`source` text DEFAULT 'doctolib' NOT NULL,
	`provider_slug` text NOT NULL,
	`payload` text NOT NULL,
	`fetched_at` integer NOT NULL,
	PRIMARY KEY(`source`, `provider_slug`)
);
--> statement-breakpoint
CREATE TABLE `appt_results` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`run_id` text NOT NULL,
	`doctor_name` text NOT NULL,
	`motive_label` text DEFAULT '' NOT NULL,
	`practice_name` text DEFAULT '' NOT NULL,
	`booking_url` text NOT NULL,
	`provider_slug` text DEFAULT '' NOT NULL,
	`source` text DEFAULT 'doctolib' NOT NULL,
	`motive_id` integer,
	`slot_datetime` integer NOT NULL,
	`is_next_slot` integer DEFAULT false NOT NULL,
	`doctor_subtitle` text DEFAULT '' NOT NULL,
	`speciality` text DEFAULT '' NOT NULL,
	`practice_address` text DEFAULT '' NOT NULL,
	`practice_city` text DEFAULT '' NOT NULL,
	`practice_zipcode` text DEFAULT '' NOT NULL,
	`practice_latitude` text DEFAULT '' NOT NULL,
	`practice_longitude` text DEFAULT '' NOT NULL,
	FOREIGN KEY (`run_id`) REFERENCES `appt_runs`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `appt_results_run_idx` ON `appt_results` (`run_id`);--> statement-breakpoint
CREATE TABLE `appt_runs` (
	`id` text PRIMARY KEY NOT NULL,
	`search_id` text NOT NULL,
	`started_at` integer NOT NULL,
	`finished_at` integer,
	`status` text DEFAULT 'RUNNING' NOT NULL,
	`triggered_by` text DEFAULT 'SCHEDULE' NOT NULL,
	`error_message` text DEFAULT '' NOT NULL,
	`doctors_found` integer DEFAULT 0 NOT NULL,
	`doctors_matched` integer DEFAULT 0 NOT NULL,
	`slots_found` integer DEFAULT 0 NOT NULL,
	`notified` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`search_id`) REFERENCES `appt_searches`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `appt_runs_search_idx` ON `appt_runs` (`search_id`,`started_at`);--> statement-breakpoint
CREATE TABLE `appt_search_channels` (
	`search_id` text NOT NULL,
	`channel_id` text NOT NULL,
	PRIMARY KEY(`search_id`, `channel_id`),
	FOREIGN KEY (`search_id`) REFERENCES `appt_searches`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`channel_id`) REFERENCES `notification_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `appt_searches` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`name` text NOT NULL,
	`speciality_slug` text DEFAULT '' NOT NULL,
	`speciality_label` text DEFAULT '' NOT NULL,
	`location_label` text DEFAULT '' NOT NULL,
	`latitude` text DEFAULT '' NOT NULL,
	`longitude` text DEFAULT '' NOT NULL,
	`insurance_sector` text DEFAULT '' NOT NULL,
	`sources` text DEFAULT 'doctolib' NOT NULL,
	`jameda_speciality_slug` text DEFAULT '' NOT NULL,
	`jameda_speciality_label` text DEFAULT '' NOT NULL,
	`jameda_speciality_type` text DEFAULT 'leistung' NOT NULL,
	`jameda_insurance_type` text DEFAULT '' NOT NULL,
	`jameda_kids_friendly` integer DEFAULT false NOT NULL,
	`jameda_video` text DEFAULT 'any' NOT NULL,
	`day_limit` integer DEFAULT 14 NOT NULL,
	`max_pages` integer DEFAULT 3 NOT NULL,
	`enabled` integer DEFAULT true NOT NULL,
	`schedule_type` text DEFAULT 'MINUTES' NOT NULL,
	`schedule_minutes` integer DEFAULT 30,
	`cron` text DEFAULT '' NOT NULL,
	`notify_only_earlier` integer DEFAULT false NOT NULL,
	`earliest_seen` integer,
	`last_run_at` integer,
	`next_run_at` integer,
	`run_requested_at` integer,
	`locked_until` integer,
	`last_status` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `appt_searches_family_idx` ON `appt_searches` (`family_id`);--> statement-breakpoint
CREATE INDEX `appt_searches_next_run_idx` ON `appt_searches` (`next_run_at`);--> statement-breakpoint
ALTER TABLE `families` ADD `home_address` text;--> statement-breakpoint
ALTER TABLE `families` ADD `home_lat` real;--> statement-breakpoint
ALTER TABLE `families` ADD `home_lng` real;