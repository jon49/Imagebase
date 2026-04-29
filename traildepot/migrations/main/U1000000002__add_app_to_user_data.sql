-- Scope user_data by app so a single TrailBase instance can back multiple
-- frontends. The handler now reads the app id from the URL path
-- (/api/data/{app}) and rejects empty values, so any pre-existing rows
-- carrying the default '' are inert until backfilled.

ALTER TABLE user_data ADD COLUMN app TEXT NOT NULL DEFAULT '';

-- Sync queries always scope by (user, app) and walk by id from a cursor.
CREATE INDEX _user_data__user_app_id_idx ON user_data (user, app, id);

-- The old (user, id) index is now strictly weaker than the new one.
DROP INDEX _user_data__user_id_idx;
