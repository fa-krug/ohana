CREATE TABLE `ai_memories` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`module` text NOT NULL,
	`text` text NOT NULL,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `ai_memories_module_idx` ON `ai_memories` (`family_id`,`module`);