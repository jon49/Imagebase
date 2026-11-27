-- ImageBase schema. Applied once, in order, by the server at startup; a
-- migration is never edited after it has shipped -- add a new file instead.
--
-- Table and column names follow the TrailBase depot this replaces (`_user`,
-- `user_data`, `spaces`, ...), so `tools/import-from-trailbase.py` can copy
-- rows across unchanged and ad-hoc SQL keeps working.

-- Accounts. `email` is the verified address; a new account has only
-- `unverified_email` until its confirmation link is opened. Codes mailed for
-- verification and password reset are stored as their SHA-256.
CREATE TABLE _user (
    id                       BLOB PRIMARY KEY NOT NULL CHECK (length(id) = 16),
    email                    TEXT COLLATE NOCASE,
    unverified_email         TEXT COLLATE NOCASE,
    password_hash            TEXT NOT NULL DEFAULT '',
    admin                    INTEGER NOT NULL DEFAULT 0,
    email_verification_code  BLOB,
    email_verification_sent  INTEGER,
    password_reset_code      BLOB,
    password_reset_sent      INTEGER,
    created                  INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    updated                  INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    CHECK (email IS NOT NULL OR unverified_email IS NOT NULL)
) STRICT;

CREATE UNIQUE INDEX _user__email_idx ON _user (email);
CREATE UNIQUE INDEX _user__unverified_email_idx ON _user (unverified_email);
CREATE INDEX _user__verification_idx ON _user (email_verification_code) WHERE email_verification_code IS NOT NULL;
CREATE INDEX _user__reset_idx ON _user (password_reset_code) WHERE password_reset_code IS NOT NULL;

-- Refresh-token sessions; only the token's SHA-256 is kept.
CREATE TABLE _session (
    id          INTEGER PRIMARY KEY,
    user        BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE,
    token_hash  BLOB NOT NULL UNIQUE,
    created     INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    expires     INTEGER NOT NULL
) STRICT;

CREATE INDEX _session__user_idx ON _session (user);

-- Failed-login counters per address, for the brute-force limiter.
CREATE TABLE _auth_throttle (
    key           TEXT PRIMARY KEY NOT NULL,
    window_start  INTEGER NOT NULL,
    count         INTEGER NOT NULL
) STRICT;

-- Shared "spaces": a slice of one app's sync data that several users read and
-- write as equals. Membership is flat; there are no roles.
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

-- Single-use invites to a space. Any member can create one.
CREATE TABLE space_invites (
    code        BLOB PRIMARY KEY NOT NULL CHECK (length(code) = 16),
    space       BLOB NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    created_by  BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE,
    created     INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    expires     INTEGER NOT NULL
) STRICT;

CREATE INDEX _space_invites__space_idx ON space_invites (space);

-- A member who leaves or is removed takes their outstanding invites with them;
-- otherwise a removed member could accept their own earlier invite to rejoin.
CREATE TRIGGER _space_members__revoke_invites_trigger AFTER DELETE ON space_members FOR EACH ROW
  BEGIN
    DELETE FROM space_invites WHERE space = OLD.space AND created_by = OLD.user;
  END;

-- The append-only last-write-wins sync table. A row is personal (`space IS
-- NULL`, scoped by `user`) or belongs to a space (`user` is then the author).
-- `app` namespaces everything so one server backs several frontends.
CREATE TABLE user_data (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user        BLOB REFERENCES _user(id) ON DELETE SET NULL,
    space       BLOB REFERENCES spaces(id) ON DELETE CASCADE,
    app         TEXT NOT NULL,
    key         TEXT NOT NULL,
    value       TEXT,
    timestamp   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK (user IS NOT NULL OR space IS NOT NULL)
) STRICT;

CREATE INDEX _user_data__user_app_id_idx ON user_data (user, app, id);
CREATE INDEX _user_data__space_app_id_idx ON user_data (space, app, id) WHERE space IS NOT NULL;

-- Personal rows go with their user. Runs before the FK action, so by the time
-- `ON DELETE SET NULL` fires only space rows are left to be orphaned, and the
-- other members' shared data doesn't roll back.
CREATE TRIGGER _user_data__user_delete_trigger BEFORE DELETE ON _user FOR EACH ROW
  BEGIN
    DELETE FROM user_data WHERE user = OLD.id AND space IS NULL;
  END;

-- Owner registry for publishing pages: one owner user per `app`. Populate it
-- with `imagebase owner set <app> <email>`.
CREATE TABLE app_owners (
    app    TEXT PRIMARY KEY NOT NULL,
    owner  BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE
) STRICT;

-- Published HTML pages, one file per client-chosen UUID. The bytes live in
-- the row; GET /api/pages/{app}/{id} serves them inline.
CREATE TABLE pages (
    id            BLOB PRIMARY KEY NOT NULL CHECK (length(id) = 16),
    app           TEXT NOT NULL,
    space         BLOB REFERENCES spaces(id) ON DELETE SET NULL,
    filename      TEXT NOT NULL DEFAULT '',
    content_type  TEXT NOT NULL DEFAULT 'text/html',
    html          BLOB NOT NULL,
    created       INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    updated       INTEGER NOT NULL DEFAULT (UNIXEPOCH())
) STRICT;

CREATE INDEX _pages__app_idx ON pages (app);
