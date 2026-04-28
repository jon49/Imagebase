-- Per-user append-only CRDT (last-write-wins) data table.
--
-- Clients POST to /api/data with a batch of key/value pairs plus the id of the
-- last row they have seen. The server saves the new rows, returns any rows
-- that were written by other clients since the cursor, and flags rows whose
-- keys collided with the incoming batch as "conflicted" so the client can
-- reconcile.
--
-- `user` references TrailBase's built-in `_user` table; rows cascade-delete
-- when the user is removed.

CREATE TABLE user_data (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user        BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE,
    key         TEXT NOT NULL,
    value       TEXT,
    timestamp   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

-- Covers the "rows since cursor, for this user" scan, ordered by id.
CREATE INDEX _user_data__user_id_idx ON user_data (user, id);
