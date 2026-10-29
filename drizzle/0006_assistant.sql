CREATE TABLE `ai_settings` (
	`family_id` text PRIMARY KEY NOT NULL,
	`base_url` text DEFAULT '' NOT NULL,
	`model` text DEFAULT '' NOT NULL,
	`api_key_enc` text DEFAULT '' NOT NULL,
	`search_provider` text DEFAULT 'none' NOT NULL,
	`search_key_enc` text DEFAULT '' NOT NULL,
	`allow_writes` integer DEFAULT true NOT NULL,
	`context_window` integer DEFAULT 0 NOT NULL,
	`image_model` text DEFAULT '' NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `chat_items` (
	`chat_id` text NOT NULL,
	`seq` integer NOT NULL,
	`rev` integer NOT NULL,
	`item` text NOT NULL,
	PRIMARY KEY(`chat_id`, `seq`),
	FOREIGN KEY (`chat_id`) REFERENCES `chats`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `chat_items_rev_idx` ON `chat_items` (`chat_id`,`rev`);--> statement-breakpoint
CREATE TABLE `chat_messages` (
	`chat_id` text NOT NULL,
	`seq` integer NOT NULL,
	`message` text NOT NULL,
	PRIMARY KEY(`chat_id`, `seq`),
	FOREIGN KEY (`chat_id`) REFERENCES `chats`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `chats` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`user_id` text NOT NULL,
	`title` text DEFAULT '' NOT NULL,
	`status` text DEFAULT 'idle' NOT NULL,
	`run_token` text,
	`run_until` integer,
	`stop` integer DEFAULT false NOT NULL,
	`retries` integer DEFAULT 0 NOT NULL,
	`context` text DEFAULT '{}' NOT NULL,
	`activity` text,
	`notes` text DEFAULT '[]' NOT NULL,
	`usage` text,
	`queue` text DEFAULT '[]' NOT NULL,
	`rev` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "chats_status_check" CHECK("chats"."status" in ('idle', 'running'))
);
--> statement-breakpoint
CREATE INDEX `chats_owner_idx` ON `chats` (`family_id`,`user_id`,`updated_at`);--> statement-breakpoint
CREATE INDEX `chats_status_idx` ON `chats` (`status`);