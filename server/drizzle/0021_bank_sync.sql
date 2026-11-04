CREATE TABLE `fin_bank_links` (
	`family_id` text NOT NULL,
	`account_id` text NOT NULL,
	`provider` text NOT NULL,
	`credentials` text NOT NULL,
	`iban` text,
	`session` text,
	`synced_through` text,
	`last_sync_at` integer,
	`unconfirmed_tans` integer DEFAULT 0 NOT NULL,
	`login_refused` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `account_id`),
	FOREIGN KEY (`family_id`,`account_id`) REFERENCES `fin_accounts`(`family_id`,`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `fin_bank_syncs` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`account_id` text NOT NULL,
	`user_id` text,
	`status` text DEFAULT 'waiting' NOT NULL,
	`step` text,
	`tan` text,
	`tan_input` text,
	`result` text,
	`error` text,
	`run_token` text,
	`locked_until` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null,
	FOREIGN KEY (`family_id`,`account_id`) REFERENCES `fin_accounts`(`family_id`,`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `fin_bank_syncs_status_idx` ON `fin_bank_syncs` (`status`,`locked_until`);--> statement-breakpoint
CREATE INDEX `fin_bank_syncs_account_idx` ON `fin_bank_syncs` (`family_id`,`account_id`,`created_at`);