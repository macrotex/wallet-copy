BEGIN;
DROP TABLE flag_names;
DROP TABLE IF EXISTS metadata;
ALTER TABLE objects ADD ob_comment varchar(255) DEFAULT NULL;
COMMIT;

