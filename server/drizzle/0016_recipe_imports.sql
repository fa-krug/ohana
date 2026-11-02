CREATE TABLE `recipe_imports` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`user_id` text,
	`url` text NOT NULL,
	`title` text DEFAULT '' NOT NULL,
	`image_url` text,
	`input` text NOT NULL,
	`language` text DEFAULT 'en' NOT NULL,
	`status` text DEFAULT 'waiting' NOT NULL,
	`error` text,
	`attempts` integer DEFAULT 0 NOT NULL,
	`run_token` text,
	`locked_until` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `recipe_imports_status_idx` ON `recipe_imports` (`status`,`locked_until`);--> statement-breakpoint
CREATE INDEX `recipe_imports_family_idx` ON `recipe_imports` (`family_id`);