-- Shared "spaces": a slice of one app's sync data that several users read and
-- write as equals (e.g. a soccer team co-managed by two coaches).
--
-- A `user_data` row is either personal (`space IS NULL`, scoped by `user` as
-- before) or belongs to a space (`space` set, `user` = the author). The sync
-- handler derives "latest value per key" per scope: PARTITION BY (user, app, key)
-- for personal rows, (space, app, key) for space rows — so two members writing
-- the same key in a space is ordinary last-write-wins.
--
-- Membership is flat: every member has full read/write. There are no roles.

-- `id` is a 16-byte UUID blob. Plain length check (not `is_uuid`) so rows can be
-- seeded with the stock sqlite3 CLI, which lacks TrailBase's functions.
CREATE TABLE spaces (
    id          BLOB PRIMARY KEY NOT NULL CHECK (length(id) = 16),
    app         TEXT NOT NULL,
    created_by  BLOB REFERENCES _user(id) ON DELETE SET NULL,
    created     INTEGER NOT NULL DEFAULT (UNIXEPOCH())
) STRICT;

CREATE TABLE space_members (
    space   BLOB NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    user    BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE,
    joined  INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    PRIMARY KEY (space, user)
) STRICT;

-- Sync looks up "which spaces is this user in" on every request.
CREATE INDEX _space_members__user_idx ON space_members (user);

-- A space with no members left is unreachable; drop it (and, via cascade, its data).
CREATE TRIGGER _space_members__gc_trigger AFTER DELETE ON space_members FOR EACH ROW
  WHEN NOT EXISTS (SELECT 1 FROM space_members WHERE space = OLD.space)
  BEGIN
    DELETE FROM spaces WHERE id = OLD.space;
  END;

-- Rebuild user_data to add `space` and to change what happens when a user is
-- deleted. Previously every row cascade-deleted with its `user`; for space rows
-- that would silently roll the other members' shared data back to older values.
-- Now: personal rows are still deleted with the user (trigger below), space rows
-- keep their data and just lose the author (`user` → NULL).
--
-- SQLite can't alter a column's FK action in place, hence the copy.
CREATE TABLE user_data_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user        BLOB REFERENCES _user(id) ON DELETE SET NULL,
    space       BLOB REFERENCES spaces(id) ON DELETE CASCADE,
    app         TEXT NOT NULL,
    key         TEXT NOT NULL,
    value       TEXT,
    timestamp   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK (user IS NOT NULL OR space IS NOT NULL)
) STRICT;

INSERT INTO user_data_new (id, user, space, app, key, value, timestamp)
  SELECT id, user, NULL, app, key, value, timestamp FROM user_data;

-- Carry the AUTOINCREMENT high-water mark over. Clients hold `lastSyncedId`
-- cursors; if ids were ever reissued below a cursor those rows would be skipped.
INSERT OR REPLACE INTO sqlite_sequence (name, seq)
  SELECT 'user_data_new', seq FROM sqlite_sequence WHERE name = 'user_data';

DROP TABLE user_data;
ALTER TABLE user_data_new RENAME TO user_data;

CREATE INDEX _user_data__user_app_id_idx ON user_data (user, app, id);
CREATE INDEX _user_data__space_app_id_idx ON user_data (space, app, id) WHERE space IS NOT NULL;

-- Personal rows go with their user. Runs before the FK action, so by the time
-- `ON DELETE SET NULL` fires only space rows are left to be orphaned.
CREATE TRIGGER _user_data__user_delete_trigger BEFORE DELETE ON _user FOR EACH ROW
  BEGIN
    DELETE FROM user_data WHERE user = OLD.id AND space IS NULL;
  END;

-- Let space members publish pages (e.g. a shared team's schedule) for the app
-- the space belongs to. See the `pages` access rules in config.textproto.
-- `is_uuid` makes the Record API accept the hyphenated string form, like `id`.
ALTER TABLE pages ADD COLUMN space BLOB REFERENCES spaces(id) ON DELETE SET NULL
  CHECK (space IS NULL OR is_uuid(space));
