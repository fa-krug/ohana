CREATE TABLE `households` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `users` (
	`id` text PRIMARY KEY NOT NULL,
	`email` text NOT NULL,
	`password` text DEFAULT '' NOT NULL,
	`preferred_language` text DEFAULT 'en' NOT NULL,
	`active_household_id` text,
	`onboarding_step` text DEFAULT 'CHANGE_PASSWORD' NOT NULL,
	`is_active` integer DEFAULT 1 NOT NULL,
	`is_staff` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`active_household_id`) REFERENCES `households`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE UNIQUE INDEX `users_email_unique` ON `users` (`email`);
--> statement-breakpoint
CREATE TABLE `household_members` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`household_id` text NOT NULL,
	`user_id` text NOT NULL,
	`role` text DEFAULT 'MEMBER' NOT NULL,
	`joined_at` integer NOT NULL,
	FOREIGN KEY (`household_id`) REFERENCES `households`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `uniq_household_user` ON `household_members` (`household_id`,`user_id`);
--> statement-breakpoint
CREATE INDEX `household_members_user_id_idx` ON `household_members` (`user_id`);
--> statement-breakpoint
CREATE TABLE `invites` (
	`id` text PRIMARY KEY NOT NULL,
	`household_id` text NOT NULL,
	`created_by_id` text NOT NULL,
	`code` text NOT NULL,
	`expires_at` integer NOT NULL,
	`used_by_id` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`household_id`) REFERENCES `households`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`used_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE UNIQUE INDEX `invites_code_unique` ON `invites` (`code`);
--> statement-breakpoint
CREATE TABLE `passkey_credentials` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`credential_id` blob NOT NULL,
	`public_key` blob NOT NULL,
	`sign_count` integer DEFAULT 0 NOT NULL,
	`device_name` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `passkey_credentials_credential_id_unique` ON `passkey_credentials` (`credential_id`);
--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `notification_channels` (
	`id` text PRIMARY KEY NOT NULL,
	`household_id` text NOT NULL,
	`name` text NOT NULL,
	`provider` text DEFAULT 'PUSHBULLET' NOT NULL,
	`token` text DEFAULT '' NOT NULL,
	`target` text DEFAULT '' NOT NULL,
	`enabled` integer DEFAULT 1 NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`household_id`) REFERENCES `households`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `searches` (
	`id` text PRIMARY KEY NOT NULL,
	`household_id` text NOT NULL,
	`name` text NOT NULL,
	`speciality_slug` text DEFAULT '' NOT NULL,
	`speciality_label` text DEFAULT '' NOT NULL,
	`location_label` text DEFAULT '' NOT NULL,
	`latitude` text DEFAULT '' NOT NULL,
	`longitude` text DEFAULT '' NOT NULL,
	`insurance_sector` text DEFAULT '' NOT NULL,
	`day_limit` integer DEFAULT 14 NOT NULL,
	`max_pages` integer DEFAULT 3 NOT NULL,
	`enabled` integer DEFAULT 1 NOT NULL,
	`schedule_type` text DEFAULT 'MINUTES' NOT NULL,
	`schedule_minutes` integer DEFAULT 30,
	`cron` text DEFAULT '' NOT NULL,
	`notify_only_earlier` integer DEFAULT 0 NOT NULL,
	`earliest_seen` integer,
	`last_run_at` integer,
	`next_run_at` integer,
	`last_status` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`household_id`) REFERENCES `households`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `searches_household_id_idx` ON `searches` (`household_id`);
--> statement-breakpoint
CREATE TABLE `search_channels` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`search_id` text NOT NULL,
	`channel_id` text NOT NULL,
	FOREIGN KEY (`search_id`) REFERENCES `searches`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`channel_id`) REFERENCES `notification_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `uniq_search_channel` ON `search_channels` (`search_id`,`channel_id`);
--> statement-breakpoint
CREATE TABLE `ignored_entries` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`search_id` text NOT NULL,
	`provider_slug` text NOT NULL,
	`motive_id` integer NOT NULL,
	`doctor_name` text DEFAULT '' NOT NULL,
	`motive_label` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`search_id`) REFERENCES `searches`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `uniq_ignored_entry` ON `ignored_entries` (`search_id`,`provider_slug`,`motive_id`);
--> statement-breakpoint
CREATE TABLE `search_runs` (
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
	`notified` integer DEFAULT 0 NOT NULL,
	FOREIGN KEY (`search_id`) REFERENCES `searches`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `search_runs_search_id_idx` ON `search_runs` (`search_id`);
--> statement-breakpoint
CREATE TABLE `appointment_results` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`run_id` text NOT NULL,
	`doctor_name` text NOT NULL,
	`motive_label` text DEFAULT '' NOT NULL,
	`practice_name` text DEFAULT '' NOT NULL,
	`booking_url` text NOT NULL,
	`provider_slug` text DEFAULT '' NOT NULL,
	`motive_id` integer,
	`slot_datetime` integer NOT NULL,
	`is_next_slot` integer DEFAULT 0 NOT NULL,
	FOREIGN KEY (`run_id`) REFERENCES `search_runs`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `appointment_results_run_id_idx` ON `appointment_results` (`run_id`);
