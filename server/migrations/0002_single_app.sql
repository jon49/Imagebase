-- One server per application: drop the `app` namespace.
--
-- A server instance now backs exactly one frontend, so `user_data`, `spaces`
-- and `pages` lose their `app` column and the per-app owner registry becomes
-- a single page owner. maintenance.goose refuses to apply this to a database
-- holding more than one app's data (the rows would merge); split such a
-- database by importing each app into its own data dir instead.

DROP INDEX _user_data__user_app_id_idx;
DROP INDEX _user_data__space_app_id_idx;
ALTER TABLE user_data DROP COLUMN app;
CREATE INDEX _user_data__user_id_idx ON user_data (user, id);
CREATE INDEX _user_data__space_id_idx ON user_data (space, id) WHERE space IS NOT NULL;

ALTER TABLE spaces DROP COLUMN app;

DROP INDEX _pages__app_idx;
ALTER TABLE pages DROP COLUMN app;

-- The one user who may publish pages outside a space (`imagebase owner set`).
CREATE TABLE page_owner (
    id     INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
    owner  BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE
) STRICT;

INSERT INTO page_owner (id, owner) SELECT 1, owner FROM app_owners LIMIT 1;
DROP TABLE app_owners;
