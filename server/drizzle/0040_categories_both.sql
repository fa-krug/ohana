-- Categories are no longer for income or for expenses: every one holds both, and within a
-- category money in and out cancel out. The column stays (older code reads it), always "both".
UPDATE `fin_categories` SET `kind` = 'both';
