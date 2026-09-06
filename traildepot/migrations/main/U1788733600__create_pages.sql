-- Publishable HTML pages, one file per (app, id).
--
-- Clients (specifically, the account that owns an `app`) upload an HTML file via
-- TrailBase's Record API — `POST /api/records/v1/pages` with a `std.FileUpload`
-- payload for the `html` column. TrailBase keeps only the file *metadata* in this
-- table; the bytes land in the object store (`<data-dir>/uploads/` by default, or
-- an S3 bucket if `server.s3_storage_config` is set).
--
-- Reads are public and go through the custom guest route `GET /api/pages/{app}/{id}`,
-- which streams the stored file back with `Content-Type: text/html` inline (the
-- Record API's own file endpoint forces `Content-Disposition: attachment`, which
-- makes browsers download rather than render).
--
-- `id` is a client-supplied UUID/GUID. TrailBase's Record API requires a PK of
-- type INTEGER or `BLOB CHECK(is_uuid*)`, so it's stored as a 16-byte blob; the
-- Record API accepts the canonical hyphenated string on write and the guest
-- route parses the same string out of `GET /api/pages/{app}/<guid>`.
CREATE TABLE pages (
    id       BLOB PRIMARY KEY NOT NULL CHECK (is_uuid(id)),
    app      TEXT NOT NULL,
    html     TEXT NOT NULL CHECK (jsonschema('std.FileUpload', html)),
    created  INTEGER NOT NULL DEFAULT (UNIXEPOCH()),
    updated  INTEGER NOT NULL DEFAULT (UNIXEPOCH())
) STRICT;

CREATE INDEX _pages__app_idx ON pages (app);

-- Keep `updated` current on overwrite.
CREATE TRIGGER _pages__updated_trigger AFTER UPDATE ON pages FOR EACH ROW
  BEGIN
    UPDATE pages SET updated = UNIXEPOCH() WHERE id = OLD.id;
  END;

-- Owner registry: one owner user per `app`. This is the "config owner" surface —
-- populate it once per app (admin UI, or:
--   INSERT INTO app_owners (app, owner)
--   VALUES ('imagebase', (SELECT id FROM _user WHERE email = 'owner@example.com'));
-- ). The Record API access rules for `pages` check membership here, so only the
-- registered owner's auth token can create/update/delete a page for that app.
CREATE TABLE app_owners (
    app    TEXT PRIMARY KEY NOT NULL,
    owner  BLOB NOT NULL REFERENCES _user(id) ON DELETE CASCADE
) STRICT;
