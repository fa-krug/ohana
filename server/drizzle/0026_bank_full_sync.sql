ALTER TABLE `fin_bank_syncs` ADD `full` integer DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE `fin_transactions` ADD `source` text DEFAULT 'manual' NOT NULL;--> statement-breakpoint
-- Rows imported before: from a bank sync when added to a linked account after it was linked
-- (a linked account refuses CSV files), else from a CSV file (or a family file's import).
UPDATE `fin_transactions` SET `source` = 'csv' WHERE `import_hash` IS NOT NULL;--> statement-breakpoint
UPDATE `fin_transactions` SET `source` = 'bank'
WHERE `import_hash` IS NOT NULL AND EXISTS (
  SELECT 1 FROM `fin_bank_links` l
  WHERE l.`family_id` = `fin_transactions`.`family_id` AND l.`account_id` = `fin_transactions`.`account_id`
    AND `fin_transactions`.`created_at` >= l.`created_at`
);
