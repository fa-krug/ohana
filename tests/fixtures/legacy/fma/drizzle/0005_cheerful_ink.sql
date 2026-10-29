CREATE TABLE `profile_cache` (
	`provider_slug` text PRIMARY KEY NOT NULL,
	`payload` text NOT NULL,
	`fetched_at` integer NOT NULL
);
