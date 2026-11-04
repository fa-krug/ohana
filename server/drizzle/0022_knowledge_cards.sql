ALTER TABLE `kb_documents` ADD `card_status` text DEFAULT 'pending' NOT NULL;--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `card_run_token` text;--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `card_run_until` integer;--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `card_attempts` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `card_retries` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `kb_documents` ADD `card_error` text;--> statement-breakpoint
CREATE INDEX `kb_documents_card_queue_idx` ON `kb_documents` (`card_status`,`status`,`card_run_until`);--> statement-breakpoint
UPDATE `kb_documents` SET `card_status` = 'none' WHERE `status` = 'ready' AND NOT EXISTS (SELECT 1 FROM `kb_chunks` WHERE `kb_chunks`.`document_id` = `kb_documents`.`id`);