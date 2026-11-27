#!/usr/bin/env python3
"""Import users + data from a V/`veb` ImageBase SQLite database into the
ImageBase server's database (`<data dir>/imagebase.db`; create it first with
`server/imagebase --data <dir> migrate`).

What gets ported
----------------
* Each row in the V `users` table becomes a row in `_user`,
  with a freshly-generated UUIDv4, a verified email, and an empty
  `password_hash`. Empty hashes can never authenticate, so users must use
  the password-reset flow on first login (see README).
* Each row in the V `data` table is copied into `user_data`, with `user_id`
  remapped to the matching new UUID. A server holds one app's data, so
  import into the data dir of the server for that app.
* Insertion order follows the old `data.id`, which keeps `lastSyncedId`
  cursors monotonically usable for clients that already track an id.

What does NOT get ported
------------------------
* Password hashes — V used SHA-256+salt, the server uses Argon2id. Force
  every user through the reset flow.
* Sessions / `password_reset` tokens — short-lived; the server manages its
  own.
* Email-verification status of the V user — we mark all imported users
  verified so they can log in immediately after resetting their password.

Skips users already present in `_user` (matched by email). Re-running is
safe: the script never mutates existing rows, but imported data rows will
accumulate. Pass `--wipe-data` to delete every `user_data` row first.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import uuid
from contextlib import closing


def stub_check_funcs(conn: sqlite3.Connection) -> None:
    """TrailBase's `_user` table had CHECK(is_uuid(id)) and CHECK(is_email(email)),
    functions from its bundled SQLite extension. The current schema doesn't
    use them; the no-op stubs are kept so the script also still runs against
    an old TrailBase main.db."""
    conn.create_function("is_uuid", 1, lambda _x: 1)
    conn.create_function("is_email", 1, lambda _x: 1)


def as_text(v):
    """V stored some `data.value` rows with BLOB storage class even though
    the column was declared TEXT (sqlite's loose affinity let this slip).
    `user_data.value` is STRICT TEXT and rejects BLOB binds,
    so coerce bytes → str. The original payloads are JSON text per the V
    server's @[raw] handling, so UTF-8 decode is lossless."""
    return v.decode("utf-8") if isinstance(v, bytes) else v


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--old-db", required=True,
                   help="path to the V ImageBase sqlite db (with users + data tables)")
    p.add_argument("--new-db", default="data/imagebase.db",
                   help="path to the server's database (default: data/imagebase.db)")
    p.add_argument("--wipe-data", action="store_true",
                   help="delete every existing user_data row before importing")
    p.add_argument("--dry-run", action="store_true",
                   help="report counts without writing anything")
    args = p.parse_args()

    old = sqlite3.connect(f"file:{args.old_db}?mode=ro", uri=True)
    new = sqlite3.connect(args.new_db)
    stub_check_funcs(new)

    with closing(old), closing(new):
        old.row_factory = sqlite3.Row

        existing_emails = {row[0] for row in
                           new.execute("SELECT email FROM _user").fetchall()}

        users = old.execute("SELECT id, email FROM users ORDER BY id").fetchall()
        to_insert = [u for u in users if u["email"] not in existing_emails]
        skipped = len(users) - len(to_insert)

        # old.id -> new uuid bytes. Includes already-existing users so data
        # rows linked to them can still be remapped.
        user_map: dict[int, bytes] = {}
        for row in users:
            if row["email"] in existing_emails:
                hit = new.execute("SELECT id FROM _user WHERE email = ?",
                                  (row["email"],)).fetchone()
                user_map[row["id"]] = hit[0]
            else:
                user_map[row["id"]] = uuid.uuid4().bytes

        data_rows = old.execute(
            "SELECT user_id, key, value, timestamp FROM data ORDER BY id"
        ).fetchall()
        # Drop rows whose user_id has no match (shouldn't happen, but guards
        # against stale orphans from older V schemas).
        data_rows = [r for r in data_rows if r["user_id"] in user_map]

        print(f"users: {len(to_insert)} new, {skipped} already present")
        print(f"data:  {len(data_rows)} rows to import")

        if args.dry_run:
            return 0

        with new:
            if args.wipe_data:
                cur = new.execute("DELETE FROM user_data")
                print(f"wiped {cur.rowcount} existing data rows")

            new.executemany(
                # A user is verified when `email` (not `unverified_email`)
                # is set.
                "INSERT INTO _user (id, email, password_hash) "
                "VALUES (?, ?, '')",
                [(user_map[u["id"]], u["email"]) for u in to_insert],
            )
            new.executemany(
                "INSERT INTO user_data (user, key, value, timestamp) "
                "VALUES (?, ?, ?, ?)",
                [(user_map[r["user_id"]],
                  as_text(r["key"]), as_text(r["value"]),
                  r["timestamp"]) for r in data_rows],
            )

        print("done. Tell users to use forgot-password — V password hashes "
              "do not transfer.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
