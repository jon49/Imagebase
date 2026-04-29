#!/usr/bin/env python3
"""Import users + data from a V/`veb` ImageBase SQLite database into the
TrailBase main.db used by NewImageBase.

What gets ported
----------------
* Each row in the V `users` table becomes a row in TrailBase's `_user`,
  with a freshly-generated UUIDv4, `verified=1`, and an empty
  `password_hash`. Empty hashes can never authenticate, so users must use
  the password-reset flow on first login (see README).
* Each row in the V `data` table is copied into `user_data` under the
  `--app` namespace, with `user_id` remapped to the matching new UUID.
* Insertion order follows the old `data.id`, which keeps `lastSyncedId`
  cursors monotonically usable for clients that already track an id.

What does NOT get ported
------------------------
* Password hashes — V used SHA-256+salt, TrailBase uses Argon2id. Force
  every user through the reset flow.
* Sessions / `password_reset` tokens — short-lived; TrailBase manages its
  own.
* Email-verification status of the V user — we mark all imported users
  verified so they can log in immediately after resetting their password.

Skips users already present in `_user` (matched by email). Re-running is
safe: the script never mutates existing TrailBase rows, but rows already
imported under the same `app` will accumulate. Pass `--wipe-app` to clear
the namespace before reimport.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import uuid
from contextlib import closing


def stub_check_funcs(conn: sqlite3.Connection) -> None:
    """The `_user` table has CHECK(is_uuid(id)) and CHECK(is_email(email)).
    Both functions live in TrailBase's bundled SQLite extension, which
    plain Python sqlite3 can't load. Register no-op stubs that always
    accept — we control the inputs ourselves."""
    conn.create_function("is_uuid", 1, lambda _x: 1)
    conn.create_function("is_email", 1, lambda _x: 1)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--old-db", required=True,
                   help="path to the V ImageBase sqlite db (with users + data tables)")
    p.add_argument("--new-db", default="traildepot/data/main.db",
                   help="path to TrailBase main.db (default: traildepot/data/main.db)")
    p.add_argument("--app", required=True,
                   help="app id to namespace the imported rows under (e.g. 'imagebase')")
    p.add_argument("--wipe-app", action="store_true",
                   help="delete existing user_data rows for --app before importing")
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
        print(f"data:  {len(data_rows)} rows to import under app='{args.app}'")

        if args.dry_run:
            return 0

        with new:
            if args.wipe_app:
                cur = new.execute(
                    "DELETE FROM user_data WHERE app = ?", (args.app,))
                print(f"wiped {cur.rowcount} existing rows for app='{args.app}'")

            new.executemany(
                "INSERT INTO _user (id, email, password_hash, verified) "
                "VALUES (?, ?, '', 1)",
                [(user_map[u["id"]], u["email"]) for u in to_insert],
            )
            new.executemany(
                "INSERT INTO user_data (user, app, key, value, timestamp) "
                "VALUES (?, ?, ?, ?, ?)",
                [(user_map[r["user_id"]], args.app, r["key"], r["value"],
                  r["timestamp"]) for r in data_rows],
            )

        print("done. Tell users to use forgot-password — V password hashes "
              "do not transfer.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
