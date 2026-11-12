CREATE TABLE `kb_page_scans` (
	`document_id` text NOT NULL,
	`family_id` text NOT NULL,
	`page` integer NOT NULL,
	`hash` text NOT NULL,
	`path` text NOT NULL,
	`forced` integer DEFAULT false NOT NULL,
	`status` text DEFAULT 'waiting' NOT NULL,
	`error` text,
	`run_token` text,
	`run_until` integer,
	`attempts` integer DEFAULT 0 NOT NULL,
	`retries` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`document_id`, `page`),
	FOREIGN KEY (`document_id`) REFERENCES `kb_documents`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `kb_page_scans_queue_idx` ON `kb_page_scans` (`status`,`run_until`);--> statement-breakpoint
CREATE INDEX `kb_page_scans_family_idx` ON `kb_page_scans` (`family_id`,`status`);--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `reader` integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `ai_pages` text DEFAULT '[]' NOT NULL;--> statement-breakpoint
ALTER TABLE `kb_folders` ADD `ai_scans` integer DEFAULT false NOT NULL;