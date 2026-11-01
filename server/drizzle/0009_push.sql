CREATE TABLE `push_devices` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`token_id` text NOT NULL,
	`platform` text NOT NULL,
	`relay_token` text NOT NULL,
	`key` text NOT NULL,
	`muted_family_ids` text DEFAULT '[]' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`last_sent_at` integer,
	`last_error` text,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`token_id`) REFERENCES `auth_tokens`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `push_devices_token_id_unique` ON `push_devices` (`token_id`);--> statement-breakpoint
ALTER TABLE `appt_searches` ADD `notify_app` integer DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE `notification_prefs` ADD `app` integer DEFAULT true NOT NULL;