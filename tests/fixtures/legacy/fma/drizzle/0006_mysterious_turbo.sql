DROP INDEX `uniq_ignored_entry`;--> statement-breakpoint
ALTER TABLE `ignored_entries` ADD `source` text DEFAULT 'doctolib' NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX `uniq_ignored_entry` ON `ignored_entries` (`search_id`,`source`,`provider_slug`,`motive_id`);--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_profile_cache` (
	`source` text DEFAULT 'doctolib' NOT NULL,
	`provider_slug` text NOT NULL,
	`payload` text NOT NULL,
	`fetched_at` integer NOT NULL,
	PRIMARY KEY(`source`, `provider_slug`)
);
--> statement-breakpoint
INSERT INTO `__new_profile_cache`("source", "provider_slug", "payload", "fetched_at") SELECT 'doctolib', "provider_slug", "payload", "fetched_at" FROM `profile_cache`;--> statement-breakpoint
DROP TABLE `profile_cache`;--> statement-breakpoint
ALTER TABLE `__new_profile_cache` RENAME TO `profile_cache`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
ALTER TABLE `appointment_results` ADD `source` text DEFAULT 'doctolib' NOT NULL;--> statement-breakpoint
ALTER TABLE `searches` ADD `sources` text DEFAULT 'doctolib' NOT NULL;--> statement-breakpoint
ALTER TABLE `searches` ADD `jameda_speciality_slug` text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE `searches` ADD `jameda_speciality_label` text DEFAULT '' NOT NULL;