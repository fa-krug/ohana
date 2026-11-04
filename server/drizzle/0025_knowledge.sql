CREATE TABLE `kb_chunks` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`document_id` text NOT NULL,
	`family_id` text NOT NULL,
	`seq` integer NOT NULL,
	`page` integer NOT NULL,
	`text` text NOT NULL,
	FOREIGN KEY (`document_id`) REFERENCES `kb_documents`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `kb_chunks_document_idx` ON `kb_chunks` (`document_id`,`seq`);--> statement-breakpoint
CREATE TABLE `kb_documents` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`folder_id` text NOT NULL,
	`path` text NOT NULL,
	`name` text NOT NULL,
	`tags` text DEFAULT '[]' NOT NULL,
	`size` integer DEFAULT 0 NOT NULL,
	`mtime` integer DEFAULT 0 NOT NULL,
	`hash` text NOT NULL,
	`pages` integer DEFAULT 0 NOT NULL,
	`text` text DEFAULT '[]' NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`error` text,
	`summary` text,
	`facts` text,
	`doc_date` text,
	`person_user_id` text,
	`person_person_id` text,
	`indexed_at` integer,
	`missing_since` integer,
	`run_token` text,
	`run_until` integer,
	`attempts` integer DEFAULT 0 NOT NULL,
	`card_status` text DEFAULT 'pending' NOT NULL,
	`card_run_token` text,
	`card_run_until` integer,
	`card_attempts` integer DEFAULT 0 NOT NULL,
	`card_retries` integer DEFAULT 0 NOT NULL,
	`card_error` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`folder_id`) REFERENCES `kb_folders`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`person_user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null,
	FOREIGN KEY (`person_person_id`) REFERENCES `family_people`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE UNIQUE INDEX `kb_documents_path_uniq` ON `kb_documents` (`folder_id`,`path`);--> statement-breakpoint
CREATE INDEX `kb_documents_status_idx` ON `kb_documents` (`family_id`,`status`);--> statement-breakpoint
CREATE INDEX `kb_documents_queue_idx` ON `kb_documents` (`status`,`run_until`);--> statement-breakpoint
CREATE INDEX `kb_documents_card_queue_idx` ON `kb_documents` (`card_status`,`status`,`card_run_until`);--> statement-breakpoint
CREATE TABLE `kb_folders` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	`last_manifest_at` integer,
	`last_manifest_device` text,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE UNIQUE INDEX `kb_folders_family_uniq` ON `kb_folders` (`family_id`);--> statement-breakpoint
ALTER TABLE `chats` ADD `knowledge_refs` text DEFAULT '[]' NOT NULL;--> statement-breakpoint
-- Hand-written: full-text search over the chunks (FTS5, external content: the text lives in
-- kb_chunks only), case and diacritics ignored ("kundigung" finds "Kündigung"), kept in step
-- by the triggers below.
CREATE VIRTUAL TABLE `kb_chunks_fts` USING fts5(`text`, content='kb_chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2');--> statement-breakpoint
CREATE TRIGGER `kb_chunks_fts_insert` AFTER INSERT ON `kb_chunks` BEGIN
	INSERT INTO `kb_chunks_fts`(rowid, `text`) VALUES (new.`id`, new.`text`);
END;--> statement-breakpoint
CREATE TRIGGER `kb_chunks_fts_delete` AFTER DELETE ON `kb_chunks` BEGIN
	INSERT INTO `kb_chunks_fts`(`kb_chunks_fts`, rowid, `text`) VALUES ('delete', old.`id`, old.`text`);
END;--> statement-breakpoint
CREATE TRIGGER `kb_chunks_fts_update` AFTER UPDATE ON `kb_chunks` BEGIN
	INSERT INTO `kb_chunks_fts`(`kb_chunks_fts`, rowid, `text`) VALUES ('delete', old.`id`, old.`text`);
	INSERT INTO `kb_chunks_fts`(rowid, `text`) VALUES (new.`id`, new.`text`);
END;
