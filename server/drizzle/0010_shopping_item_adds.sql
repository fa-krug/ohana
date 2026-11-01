CREATE TABLE `shopping_item_adds` (
	`shopping_list_id` text NOT NULL,
	`client_id` text NOT NULL,
	`item_id` text NOT NULL,
	`merged` integer NOT NULL,
	`previous_quantity` text,
	PRIMARY KEY(`shopping_list_id`, `client_id`),
	FOREIGN KEY (`shopping_list_id`) REFERENCES `shopping_lists`(`id`) ON UPDATE no action ON DELETE cascade
);
