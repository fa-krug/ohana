CREATE TABLE `digest_dismissals` (
	`family_id` text NOT NULL,
	`key` text NOT NULL,
	`day` text NOT NULL,
	`created_by_id` text,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `key`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE TABLE `geo_places` (
	`family_id` text NOT NULL,
	`query` text NOT NULL,
	`lat` real,
	`lng` real,
	`looked_up_at` integer NOT NULL,
	PRIMARY KEY(`family_id`, `query`),
	FOREIGN KEY (`family_id`) REFERENCES `families`(`id`) ON UPDATE no action ON DELETE cascade
);
