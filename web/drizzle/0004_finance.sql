CREATE TABLE `fin_accounts` (
	`family_id` text NOT NULL,
	`id` text NOT NULL,
	`name` text NOT NULL,
	`color` text NOT NULL,
	`icon` text DEFAULT '' NOT NULL,
	`opening_cents` integer DEFAULT 0 NOT NULL,
	`position` integer DEFAULT 0 NOT NULL,
	PRIMARY KEY(`family_id`, `id`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `fin_categories` (
	`family_id` text NOT NULL,
	`id` text NOT NULL,
	`name` text NOT NULL,
	`color` text NOT NULL,
	`icon` text DEFAULT '' NOT NULL,
	`kind` text DEFAULT 'expense' NOT NULL,
	`position` integer DEFAULT 0 NOT NULL,
	`parent_id` text,
	PRIMARY KEY(`family_id`, `id`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`family_id`,`parent_id`) REFERENCES `fin_categories`(`family_id`,`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "fin_categories_kind" CHECK("fin_categories"."kind" in ('income', 'expense', 'both')),
	CONSTRAINT "fin_categories_parent_not_self" CHECK("fin_categories"."parent_id" is null or "fin_categories"."parent_id" <> "fin_categories"."id")
);
--> statement-breakpoint
CREATE INDEX `fin_categories_parent_idx` ON `fin_categories` (`family_id`,`parent_id`);--> statement-breakpoint
CREATE TABLE `fin_settings` (
	`family_id` text PRIMARY KEY NOT NULL,
	`currency` text DEFAULT 'EUR' NOT NULL,
	`csv_mappings` text DEFAULT '[]' NOT NULL,
	`benchmark` text,
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `fin_transactions` (
	`family_id` text NOT NULL,
	`id` text NOT NULL,
	`day` text NOT NULL,
	`amount_cents` integer NOT NULL,
	`payee` text DEFAULT '' NOT NULL,
	`description` text DEFAULT '' NOT NULL,
	`category_id` text,
	`note` text DEFAULT '' NOT NULL,
	`import_hash` text,
	`account_id` text,
	`transfer_id` text,
	`split_of` text,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `id`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`family_id`,`category_id`) REFERENCES `fin_categories`(`family_id`,`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`family_id`,`account_id`) REFERENCES `fin_accounts`(`family_id`,`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`family_id`,`split_of`) REFERENCES `fin_transactions`(`family_id`,`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "fin_transactions_amount" CHECK(abs("fin_transactions"."amount_cents") <= 100000000000000)
);
--> statement-breakpoint
CREATE INDEX `fin_transactions_day_idx` ON `fin_transactions` (`family_id`,`day`);--> statement-breakpoint
CREATE UNIQUE INDEX `fin_transactions_import_hash_idx` ON `fin_transactions` (`family_id`,`import_hash`) WHERE "fin_transactions"."import_hash" is not null;--> statement-breakpoint
CREATE INDEX `fin_transactions_transfer_idx` ON `fin_transactions` (`family_id`,`transfer_id`) WHERE "fin_transactions"."transfer_id" is not null;--> statement-breakpoint
CREATE INDEX `fin_transactions_split_idx` ON `fin_transactions` (`family_id`,`split_of`) WHERE "fin_transactions"."split_of" is not null;--> statement-breakpoint
CREATE INDEX `fin_transactions_account_idx` ON `fin_transactions` (`family_id`,`account_id`);--> statement-breakpoint
CREATE INDEX `fin_transactions_category_idx` ON `fin_transactions` (`family_id`,`category_id`);