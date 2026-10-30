ALTER TABLE `notification_channels` ADD `smtp_host` text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE `notification_channels` ADD `smtp_port` integer DEFAULT 465 NOT NULL;--> statement-breakpoint
ALTER TABLE `notification_channels` ADD `smtp_username` text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE `notification_channels` ADD `smtp_from` text DEFAULT '' NOT NULL;
