-- Members get a color, entry types a member (their color comes from theirs) and an icon, day
-- notes SF Symbol icons. Hand-edited: the columns are added and dropped in place, never by
-- rebuilding cal_entry_types (dropping that table would delete every cal_entries row through
-- its cascade).
ALTER TABLE `cal_entry_types` ADD `member_user_id` text REFERENCES users(id) ON DELETE set null;--> statement-breakpoint
ALTER TABLE `cal_entry_types` ADD `member_person_id` text REFERENCES family_people(id) ON DELETE set null;--> statement-breakpoint
ALTER TABLE `cal_entry_types` DROP COLUMN `color`;--> statement-breakpoint
-- Types get an icon (an SF Symbol name; null: their role's).
ALTER TABLE `cal_entry_types` ADD `icon` text;--> statement-breakpoint
-- Day notes' icons become SF Symbol names too (lib/calendar/icons.ts: lowercase letters and
-- digits, parts joined by dots, max 64): an older icon (an emoji) moves to the front of the
-- note's comment (max 500 characters kept).
UPDATE `cal_notes` SET
  `comment` = substr(trim(`icon` || ' ' || `comment`), 1, 500),
  `icon` = ''
WHERE `icon` <> '' AND (
  length(`icon`) > 64 OR `icon` GLOB '*[^a-z0-9.]*' OR `icon` GLOB '.*' OR `icon` GLOB '*.'
  OR `icon` GLOB '*..*'
);--> statement-breakpoint
ALTER TABLE `family_members` ADD `color` text DEFAULT 'blue' NOT NULL;--> statement-breakpoint
ALTER TABLE `family_people` ADD `color` text DEFAULT 'blue' NOT NULL;--> statement-breakpoint
-- Distinct colors per family in join order: accounts by joined_at, then people by created_at,
-- through the palette (lib/families/colors.ts) in its order.
CREATE TEMP TABLE `member_color_order` AS
SELECT `family_id`, `kind`, `id`,
  (row_number() OVER (PARTITION BY `family_id` ORDER BY `kind`, `at`, `id`) - 1) % 10 AS `n`
FROM (
  SELECT `family_id`, 0 AS `kind`, `user_id` AS `id`, `joined_at` AS `at` FROM `family_members`
  UNION ALL
  SELECT `family_id`, 1 AS `kind`, `id`, `created_at` AS `at` FROM `family_people`
);--> statement-breakpoint
CREATE TEMP TABLE `member_color_keys` (`n` integer PRIMARY KEY, `key` text NOT NULL);--> statement-breakpoint
INSERT INTO `member_color_keys` VALUES
  (0, 'blue'), (1, 'orange'), (2, 'green'), (3, 'red'), (4, 'purple'),
  (5, 'yellow'), (6, 'teal'), (7, 'pink'), (8, 'indigo'), (9, 'brown');--> statement-breakpoint
UPDATE `family_members` SET `color` = (
  SELECT k.`key` FROM `member_color_order` o JOIN `member_color_keys` k ON k.`n` = o.`n`
  WHERE o.`kind` = 0 AND o.`family_id` = `family_members`.`family_id` AND o.`id` = `family_members`.`user_id`
);--> statement-breakpoint
UPDATE `family_people` SET `color` = (
  SELECT k.`key` FROM `member_color_order` o JOIN `member_color_keys` k ON k.`n` = o.`n`
  WHERE o.`kind` = 1 AND o.`id` = `family_people`.`id`
);--> statement-breakpoint
DROP TABLE `member_color_order`;--> statement-breakpoint
DROP TABLE `member_color_keys`;
