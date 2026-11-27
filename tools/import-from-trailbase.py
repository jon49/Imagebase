#!/usr/bin/env python3
"""Copy an ImageBase TrailBase depot into the Goose server's database.

    server/imagebase --data data migrate          # create the empty schema
    python3 tools/import-from-trailbase.py \\
        --depot traildepot --data data [--app soccer]   # --dry-run first to see counts

A TrailBase depot could back several frontends, each under its own `app` id;
a server now serves one. `--app` picks which app's data to import (needed
only when the depot holds more than one); import each app into a data dir of
its own and run one server per app.

What carries over, unchanged:
* `_user` rows: id, email / unverified_email, admin flag, timestamps and the
  Argon2id `password_hash`, so everyone keeps their password.
  Accounts are shared by every app in a depot, so all of them are copied.
* The app's `spaces`, with their `space_members` and `space_invites`; its
  `app_owners` entry becomes the page owner.
* The app's `user_data`, with the same ids and the AUTOINCREMENT high-water
  mark, so clients' `lastSyncedId` and per-space cursors stay valid.
* The app's `pages`: each row's file is read out of the depot's object store
  (`<depot>/uploads/<object id>`) and written to `--pages-dir` as `<id>.html`,
  with its space, if any, in `.spaces/<id>` (as the server keeps pages).

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
import uuid

# (table, columns copied, which rows belong to the app being imported)
COPY_TABLES = [
    ("spaces", "id, created_by, created", "app = :app"),
    ("space_members", "space, user, joined", "space IN (SELECT id FROM spaces WHERE app = :app)"),
    ("space_invites", "code, space, created_by, created, expires",
     "space IN (SELECT id FROM spaces WHERE app = :app)"),
    ("user_data", "id, user, space, key, value, timestamp", "app = :app"),
]


def write_atomic(path: str, data: bytes | None) -> None:
    """Writes `data` to `path` via a temp file and a rename; None removes it."""
    if data is None:
        if os.path.exists(path):
            os.remove(path)
        return
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--depot", default="traildepot", help="TrailBase depot dir (default: traildepot)")
    p.add_argument("--data", default="data", help="imagebase data dir (default: data)")
    p.add_argument("--app", help="which app's data to import (required if the depot has several)")
    p.add_argument("--pages-dir", help="where the server publishes pages (its --pages-dir); "
                   "required if the app has published pages")
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

    for t in ("_user", "user_data", "spaces"):
        if dst.execute(f"SELECT 1 FROM {t} LIMIT 1").fetchone():
            sys.exit(f"{dst_path} already has rows in {t}; import into a fresh data dir")

    apps = [r[0] for r in src.execute(
        "SELECT app FROM user_data UNION SELECT app FROM spaces UNION SELECT app FROM pages "
        "UNION SELECT app FROM app_owners ORDER BY 1")]
    app = a.app
    if app is None:
        if len(apps) > 1:
            sys.exit(f"the depot holds several apps ({', '.join(apps)}): pick one with --app")
        app = apps[0] if apps else ""
    elif apps and app not in apps:
        sys.exit(f"no app {app!r} in the depot (it has: {', '.join(apps)})")
    print(f"app: {app or '(none: accounts only)'}")

    skip_admin = "" if a.keep_admin_localhost else "WHERE coalesce(email, '') != 'admin@localhost'"
    users = src.execute(f"""
        SELECT id, email, unverified_email, coalesce(password_hash, ''), admin, created, updated
          FROM _user {skip_admin}""").fetchall()
    users = [u for u in users if u[1] or u[2]]       # OAuth-only rows have no address
    user_ids = {u[0] for u in users}

    rows = {}
    for table, cols, where in COPY_TABLES:
        rows[table] = src.execute(f"SELECT {cols} FROM {table} WHERE {where} ORDER BY rowid",
                                  {"app": app}).fetchall()
    owner = src.execute("SELECT owner FROM app_owners WHERE app = ?", (app,)).fetchone()
    owner = owner[0] if owner and owner[0] in user_ids else None
    # Drop references to accounts that weren't copied.
    rows["space_members"] = [r for r in rows["space_members"] if r[1] in user_ids]
    rows["space_invites"] = [r for r in rows["space_invites"] if r[2] in user_ids]
    rows["spaces"] = [(r[0], r[1] if r[1] in user_ids else None, r[2]) for r in rows["spaces"]]
    rows["user_data"] = [r for r in ([(i, u if u in user_ids else None, s, *rest)
                                       for (i, u, s, *rest) in rows["user_data"]])
                         if r[1] is not None or r[2] is not None]
    seq = src.execute("SELECT seq FROM sqlite_sequence WHERE name = 'user_data'").fetchone()

    pages = []
    missing = 0
    for pid, space, meta, created, updated in src.execute(
            "SELECT id, space, html, created, updated FROM pages WHERE app = ?", (app,)):
        info = json.loads(meta)
        path = os.path.join(a.depot, "uploads", info.get("id", ""))
        if not info.get("id") or not os.path.isfile(path):
            missing += 1
            continue
        with open(path, "rb") as f:
            body = f.read()
        pages.append((pid, space, info.get("original_filename") or info.get("filename") or "",
                      info.get("content_type") or "text/html", body, created, updated))

    print(f"users: {len(users)}")
    for table, _, _ in COPY_TABLES:
        print(f"{table}: {len(rows[table])}")
    print(f"page owner: {'yes' if owner else 'none'}")
    print(f"pages: {len(pages)}" + (f" ({missing} skipped: file missing from uploads/)" if missing else ""))
    if pages and not a.pages_dir:
        sys.exit("the app has published pages: give --pages-dir (the server's) to write them to")
    if a.dry_run:
        print("dry run: nothing written")
        return 0

    with dst:
        dst.executemany("""INSERT INTO _user (id, email, unverified_email, password_hash, admin, created, updated)
                           VALUES (?, ?, ?, ?, ?, ?, ?)""", users)
        for table, cols, _ in COPY_TABLES:
            marks = ", ".join("?" * len(cols.split(",")))
            dst.executemany(f"INSERT INTO {table} ({cols}) VALUES ({marks})", rows[table])
        if seq:
            dst.execute("UPDATE sqlite_sequence SET seq = max(seq, ?) WHERE name = 'user_data'", seq)
            dst.execute("INSERT INTO sqlite_sequence (name, seq) SELECT 'user_data', ? "
                        "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'user_data')", seq)
        if owner:
            dst.execute("INSERT INTO page_owner (id, owner) VALUES (1, ?)", (owner,))
    if pages:
        spaces_dir = os.path.join(a.pages_dir, ".spaces")
        os.makedirs(spaces_dir, exist_ok=True)
        for pid, space, _name, _ctype, body, _created, _updated in pages:
            name = str(uuid.UUID(bytes=pid))
            write_atomic(os.path.join(spaces_dir, name),
                         (str(uuid.UUID(bytes=space)) + "\n").encode() if space else None)
            write_atomic(os.path.join(a.pages_dir, name + ".html"), body)
        print(f"wrote {len(pages)} page(s) to {a.pages_dir}")
    print(f"imported into {dst_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
