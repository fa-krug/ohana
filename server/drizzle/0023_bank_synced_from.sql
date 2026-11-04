ALTER TABLE `fin_bank_links` ADD `synced_from` text;--> statement-breakpoint
-- Links synced before: their history before the last booking day may have come from a CSV file,
-- so later syncs start no earlier than that day.
UPDATE `fin_bank_links` SET `synced_from` = `synced_through` WHERE `synced_through` IS NOT NULL;
