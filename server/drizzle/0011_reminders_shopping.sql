DROP TABLE `shopping_item_adds`;--> statement-breakpoint
DROP TABLE `shopping_list_items`;--> statement-breakpoint
DROP TABLE `shopping_lists`;--> statement-breakpoint
ALTER TABLE `fin_settings` DROP COLUMN `groceries_category_id`;--> statement-breakpoint
DELETE FROM `notification_prefs` WHERE `event` = 'shopping_reminder';