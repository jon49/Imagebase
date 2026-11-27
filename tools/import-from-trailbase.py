#!/usr/bin/env python3
"""Copy an ImageBase TrailBase depot into the Goose server's database.

    server/imagebase --data data migrate          # create the empty schema
    python3 tools/import-from-trailbase.py \\
        --depot traildepot --data data            # --dry-run first to see counts

What carries over, unchanged:
* `_user` rows: id, email / unverified_email, admin flag, timestamps and the
  Argon2id `password_hash`, so everyone keeps their password.
* `spaces`, `space_members`, `space_invites`, `app_owners`.
* `user_data`, with the same ids and the AUTOINCREMENT high-water mark, so
  clients' `lastSyncedId` and per-space cursors stay valid.
* `pages`: each row's file is read out of the depot's object store
  (`<depot>/uploads/<object id>`) and stored in the row itself.

What does not: sessions (TrailBase's tokens are signed with its own key, so
users sign in again; their passwords still work), pending verification and
reset codes, and TrailBase's own tables (logs, admin settings, its
auto-created `admin@localhost` account, unless --keep-admin-localhost).

The target must be freshly migrated and empty; the import is one transaction.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys

COPY_TABLES = [
    ("spaces", "id, app, created_by, created"),
    ("space_members", "space, user, joined"),
    ("space_invites", "code, space, created_by, created, expires"),
    ("app_owners", "app, owner"),
    ("user_data", "id, user, space, app, key, value, timestamp"),
]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--depot", default="traildepot", help="TrailBase depot dir (default: traildepot)")
    p.add_argument("--data", default="data", help="imagebase data dir (default: data)")
    p.add_argument("--dry-run", action="store_true", help="count what would be copied, write nothing")
    p.add_argument("--keep-admin-localhost", action="store_true",
                   help="also copy TrailBase's auto-created admin@localhost account")
    a = p.parse_args()

    src_path = os.path.join(a.depot, "data", "main.db")
    dst_path = os.path.join(a.data, "imagebase.db")
    if not os.path.exists(src_path):
        sys.exit(f"no TrailBase database at {src_path}")
    if not os.path.exists(dst_path):
        sys.exit(f"no {dst_path}: run `server/imagebase --data {a.data} migrate` first")

    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    dst = sqlite3.connect(dst_path)
    dst.execute("PRAGMA foreign_keys = ON")

    for t in ("_user", "user_data", "spaces", "pages"):
        if dst.execute(f"SELECT 1 FROM {t} LIMIT 1").fetchone():
            sys.exit(f"{dst_path} already has rows in {t}; import into a fresh data dir")

    skip_admin = "" if a.keep_admin_localhost else "WHERE coalesce(email, '') != 'admin@localhost'"
    users = src.execute(f"""
        SELECT id, email, unverified_email, coalesce(password_hash, ''), admin, created, updated
          FROM _user {skip_admin}""").fetchall()
    users = [u for u in users if u[1] or u[2]]       # OAuth-only rows have no address
    user_ids = {u[0] for u in users}

    rows = {}
    for table, cols in COPY_TABLES:
        rows[table] = src.execute(f"SELECT {cols} FROM {table} ORDER BY rowid").fetchall()
    # Drop references to accounts that weren't copied.
    rows["space_members"] = [r for r in rows["space_members"] if r[1] in user_ids]
    rows["space_invites"] = [r for r in rows["space_invites"] if r[2] in user_ids]
    rows["app_owners"] = [r for r in rows["app_owners"] if r[1] in user_ids]
    rows["spaces"] = [(r[0], r[1], r[2] if r[2] in user_ids else None, r[3]) for r in rows["spaces"]]
    rows["user_data"] = [r for r in ([(i, u if u in user_ids else None, s, *rest)
                                       for (i, u, s, *rest) in rows["user_data"]])
                         if r[1] is not None or r[2] is not None]
    seq = src.execute("SELECT seq FROM sqlite_sequence WHERE name = 'user_data'").fetchone()

    pages = []
    missing = 0
    for pid, app, space, meta, created, updated in src.execute(
            "SELECT id, app, space, html, created, updated FROM pages"):
        info = json.loads(meta)
        path = os.path.join(a.depot, "uploads", info.get("id", ""))
        if not info.get("id") or not os.path.isfile(path):
            missing += 1
            continue
        with open(path, "rb") as f:
            body = f.read()
        pages.append((pid, app, space, info.get("original_filename") or info.get("filename") or "",
                      info.get("content_type") or "text/html", body, created, updated))

    print(f"users: {len(users)}")
    for table, _ in COPY_TABLES:
        print(f"{table}: {len(rows[table])}")
    print(f"pages: {len(pages)}" + (f" ({missing} skipped: file missing from uploads/)" if missing else ""))
    if a.dry_run:
        print("dry run: nothing written")
        return 0

    with dst:
        dst.executemany("""INSERT INTO _user (id, email, unverified_email, password_hash, admin, created, updated)
                           VALUES (?, ?, ?, ?, ?, ?, ?)""", users)
        for table, cols in COPY_TABLES:
            marks = ", ".join("?" * len(cols.split(",")))
            dst.executemany(f"INSERT INTO {table} ({cols}) VALUES ({marks})", rows[table])
        if seq:
            dst.execute("UPDATE sqlite_sequence SET seq = max(seq, ?) WHERE name = 'user_data'", seq)
            dst.execute("INSERT INTO sqlite_sequence (name, seq) SELECT 'user_data', ? "
                        "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'user_data')", seq)
        dst.executemany("""INSERT INTO pages (id, app, space, filename, content_type, html, created, updated)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""", pages)
    print(f"imported into {dst_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
