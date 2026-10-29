CREATE TABLE `cooking_steps` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`recipe_id` text NOT NULL,
	`method` text NOT NULL,
	`step_number` integer NOT NULL,
	`instruction` text DEFAULT '' NOT NULL,
	`program_type` text DEFAULT '' NOT NULL,
	`temperature` integer,
	`duration_seconds` integer,
	`speed` integer,
	`turbo` integer DEFAULT false NOT NULL,
	`direction` text DEFAULT '' NOT NULL,
	`weight_grams` integer,
	FOREIGN KEY (`recipe_id`) REFERENCES `recipes`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `cooking_steps_recipe_id_idx` ON `cooking_steps` (`recipe_id`);--> statement-breakpoint
CREATE TABLE `ingredients` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`name_de` text NOT NULL,
	`name_en` text NOT NULL,
	`category` text DEFAULT 'OTHER' NOT NULL
);
--> statement-breakpoint
CREATE TABLE `meal_plan_entries` (
	`id` text PRIMARY KEY NOT NULL,
	`iteration_id` text NOT NULL,
	`date` text NOT NULL,
	`meal_type` text NOT NULL,
	`recipe_id` text NOT NULL,
	`servings` integer NOT NULL,
	`is_leftover` integer DEFAULT false NOT NULL,
	`source_entry_id` text,
	`is_locked` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`iteration_id`) REFERENCES `plan_iterations`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`recipe_id`) REFERENCES `recipes`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`source_entry_id`) REFERENCES `meal_plan_entries`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `meal_plan_entries_iteration_id_idx` ON `meal_plan_entries` (`iteration_id`);--> statement-breakpoint
CREATE TABLE `meal_plan_excluded_tags` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`meal_plan_id` text NOT NULL,
	`tag_id` text NOT NULL,
	FOREIGN KEY (`meal_plan_id`) REFERENCES `meal_plans`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`tag_id`) REFERENCES `meal_tags`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `meal_plan_excluded_tags_plan_tag_idx` ON `meal_plan_excluded_tags` (`meal_plan_id`,`tag_id`);--> statement-breakpoint
CREATE TABLE `meal_plans` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`iteration_weeks` integer DEFAULT 1 NOT NULL,
	`shopping_day_1` integer DEFAULT 5 NOT NULL,
	`shopping_day_2` integer,
	`servings` integer DEFAULT 2 NOT NULL,
	`known_ratio` text DEFAULT '0.7' NOT NULL,
	`default_leftover_days` integer DEFAULT 1 NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `meal_plans_family_id_unique` ON `meal_plans` (`family_id`);--> statement-breakpoint
CREATE TABLE `meal_tags` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`category` text NOT NULL,
	`name_en` text NOT NULL,
	`name_de` text NOT NULL,
	`is_default` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `meal_tags_family_category_name_idx` ON `meal_tags` (`family_id`,`category`,`name_en`);--> statement-breakpoint
CREATE TABLE `plan_iterations` (
	`id` text PRIMARY KEY NOT NULL,
	`meal_plan_id` text NOT NULL,
	`start_date` text NOT NULL,
	`end_date` text NOT NULL,
	`status` text DEFAULT 'ACTIVE' NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`meal_plan_id`) REFERENCES `meal_plans`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `plan_iterations_meal_plan_id_idx` ON `plan_iterations` (`meal_plan_id`);--> statement-breakpoint
CREATE TABLE `recipe_ingredients` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`recipe_id` text NOT NULL,
	`ingredient_id` integer NOT NULL,
	`quantity` text NOT NULL,
	`unit_id` integer NOT NULL,
	`order` integer DEFAULT 0 NOT NULL,
	FOREIGN KEY (`recipe_id`) REFERENCES `recipes`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`ingredient_id`) REFERENCES `ingredients`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`unit_id`) REFERENCES `units`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `recipe_ingredients_recipe_id_idx` ON `recipe_ingredients` (`recipe_id`);--> statement-breakpoint
CREATE TABLE `recipe_tags` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`recipe_id` text NOT NULL,
	`tag_id` text NOT NULL,
	FOREIGN KEY (`recipe_id`) REFERENCES `recipes`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`tag_id`) REFERENCES `meal_tags`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `recipe_tags_recipe_tag_idx` ON `recipe_tags` (`recipe_id`,`tag_id`);--> statement-breakpoint
CREATE TABLE `recipes` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`title` text NOT NULL,
	`description` text DEFAULT '' NOT NULL,
	`list_type` text NOT NULL,
	`default_servings` integer DEFAULT 2 NOT NULL,
	`prep_time_minutes` integer,
	`cook_time_minutes` integer,
	`leftover_days` integer,
	`image` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `recipes_family_id_idx` ON `recipes` (`family_id`);--> statement-breakpoint
CREATE TABLE `shopping_list_items` (
	`id` text PRIMARY KEY NOT NULL,
	`shopping_list_id` text NOT NULL,
	`ingredient_id` integer NOT NULL,
	`quantity` text NOT NULL,
	`unit_id` integer NOT NULL,
	`is_checked` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`shopping_list_id`) REFERENCES `shopping_lists`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`ingredient_id`) REFERENCES `ingredients`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`unit_id`) REFERENCES `units`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `shopping_list_items_shopping_list_id_idx` ON `shopping_list_items` (`shopping_list_id`);--> statement-breakpoint
CREATE TABLE `shopping_lists` (
	`id` text PRIMARY KEY NOT NULL,
	`iteration_id` text NOT NULL,
	`shopping_date` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`iteration_id`) REFERENCES `plan_iterations`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `shopping_lists_iteration_id_idx` ON `shopping_lists` (`iteration_id`);--> statement-breakpoint
CREATE TABLE `step_ingredients` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`step_id` integer NOT NULL,
	`recipe_ingredient_id` integer NOT NULL,
	`quantity` text NOT NULL,
	FOREIGN KEY (`step_id`) REFERENCES `cooking_steps`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`recipe_ingredient_id`) REFERENCES `recipe_ingredients`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `step_ingredients_step_id_idx` ON `step_ingredients` (`step_id`);--> statement-breakpoint
CREATE TABLE `units` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`name_de` text NOT NULL,
	`name_en` text NOT NULL,
	`abbreviation` text NOT NULL,
	`base_unit_id` integer,
	`conversion_factor` text DEFAULT '1' NOT NULL,
	FOREIGN KEY (`base_unit_id`) REFERENCES `units`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
-- Backfill: the default meal tags for families that existed before this migration
-- (new families get them from createFamily).
INSERT INTO `meal_tags` (`id`, `family_id`, `category`, `name_en`, `name_de`, `is_default`)
SELECT lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || substr('89ab', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))),
  f.`id`, d.`category`, d.`name_en`, d.`name_de`, 1
FROM `families` f
CROSS JOIN (
  WITH t(`category`, `name_en`, `name_de`) AS (VALUES
    ('DIETARY', 'Vegan', 'Vegan'),
    ('DIETARY', 'Vegetarian', 'Vegetarisch'),
    ('DIETARY', 'Kosher', 'Koscher'),
    ('DIETARY', 'Halal', 'Halal'),
    ('DIETARY', 'Gluten-Free', 'Glutenfrei'),
    ('DIETARY', 'Dairy-Free', 'Laktosefrei'),
    ('DIETARY', 'Low-Carb', 'Low-Carb'),
    ('DIETARY', 'Nut-Free', 'Nussfrei'),
    ('DIETARY', 'Whole30', 'Whole30'),
    ('DIETARY', 'Paleo', 'Paleo'),
    ('PROTEIN', 'Pork', 'Schwein'),
    ('PROTEIN', 'Beef', 'Rind'),
    ('PROTEIN', 'Chicken', 'Hähnchen'),
    ('PROTEIN', 'Duck', 'Ente'),
    ('PROTEIN', 'Turkey', 'Truthahn'),
    ('PROTEIN', 'Fish', 'Fisch'),
    ('PROTEIN', 'Seafood', 'Meeresfrüchte'),
    ('PROTEIN', 'Tofu', 'Tofu'),
    ('PROTEIN', 'Egg', 'Ei'),
    ('CUISINE', 'Italian', 'Italienisch'),
    ('CUISINE', 'Asian', 'Asiatisch'),
    ('CUISINE', 'Mexican', 'Mexikanisch'),
    ('CUISINE', 'Indian', 'Indisch'),
    ('CUISINE', 'Mediterranean', 'Mediterran'),
    ('CUISINE', 'German', 'Deutsch'),
    ('CUISINE', 'American', 'Amerikanisch'),
    ('CUISINE', 'French', 'Französisch'),
    ('CUISINE', 'Middle Eastern', 'Nahöstlich'),
    ('CUISINE', 'Thai', 'Thailändisch'),
    ('MEAL_TYPE', 'Quick Weeknight', 'Schnelles Abendessen'),
    ('MEAL_TYPE', 'One-Pot', 'Eintopf'),
    ('MEAL_TYPE', 'Meal-Prep', 'Meal-Prep'),
    ('MEAL_TYPE', 'Comfort Food', 'Comfort Food'),
    ('MEAL_TYPE', 'Simple', 'Einfach'),
    ('MEAL_TYPE', 'Elaborate', 'Aufwändig'),
    ('MEAL_TYPE', 'Grilling', 'Grillen'),
    ('MEAL_TYPE', 'Salad', 'Salat')
  ) SELECT * FROM t
) d;
