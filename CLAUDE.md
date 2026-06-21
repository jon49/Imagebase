# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ImageBase is a rewrite of an older V/`veb` app onto [TrailBase](https://trailbase.io).
TrailBase owns everything auth-shaped (users, sessions, JWTs, password reset). The only
custom code is one HTTP route — a CRDT (last-write-wins) sync endpoint — compiled as a
Rust → `wasm32-wasip2` component and loaded by the `trail` server at startup.

## Commands

```sh
make build      # build the wasm guest and copy it into traildepot/wasm/ (alias: make deploy)
make dev        # build + run trail with --dev (permissive CORS, emails logged to stderr)
make run        # build + run trail (production-ish)
make build-wasm # just cargo build the guest, no copy
make clean      # nuke target/ and traildepot runtime dirs (data, secrets, backups, uploads)

./tasks/test.sh         # run the full Hurl integration suite
./tasks/test.sh -- ...  # extra args pass through to hurl
```

The test runner (`tests/tests.sh`) is self-contained: it rebuilds the wasm, spawns its own
short-lived `trail` on a random free port, waits for `/api/auth/v1/status`, runs the Hurl
scripts in sequence, then kills the server on exit. You do **not** need a running server.
It shares `traildepot/data/` with any long-running `make dev` (SQLite handles the locking).
To run a single test, invoke `hurl` directly against a running server, e.g.:

```sh
make dev   # in one terminal
cd tests && hurl --test --variables-file local.env --variable url=http://localhost:4000 \
    --variable token=<jwt> add-data.tests.hurl
```

First `trail` start prints an auto-generated admin password; admin UI is at
`http://localhost:4000/_/admin/`.

## Prerequisites

`trail` CLI on `$PATH`; Rust toolchain with the `wasm32-wasip2` target; plus `sqlite3`,
`python3`, and `hurl` for the test runner. `CARGO` defaults to `$HOME/.cargo/bin/cargo` in
the Makefile.

## Architecture

- **`guests/rust/src/lib.rs`** — the entire custom backend. Implements the `trailbase_wasm::Guest`
  trait, exporting one route: `POST /api/data/{app}` → `sync_data`. Build artifact lands at
  `guests/rust/target/wasm32-wasip2/release/imagebase_guest.wasm` and is copied to
  `traildepot/wasm/imagebase_guest.wasm` (gitignored) by `make deploy`.

- **`traildepot/`** — the TrailBase data dir passed via `--data-dir`. `config.textproto` is the
  server config; `migrations/main/*.sql` run at startup; `data/` (main.db, logs.db, session.db)
  and `secrets/` are runtime-generated and gitignored.

- **`tools/import-from-v.py`** — one-shot importer from a legacy V SQLite DB into TrailBase's
  `main.db`. See README for what does/doesn't port (notably: password hashes do **not** carry
  over — imported users must use forgot-password before they can log in).

### The sync protocol (the core domain logic)

`POST /api/data/{app}` is the only custom route. Key invariants when editing `sync_data`:

- **`{app}` namespaces everything.** Every read and write is scoped by `(user, app)` so one
  TrailBase instance backs multiple frontends with no cross-tenant reads. `user` comes from the
  authenticated TrailBase identity (`req.user()`, base64-decoded to the UUID blob), never the body.

- **`user_data` is append-only.** Each upload is an `INSERT`; there are no updates or deletes.
  "Latest value per key" is derived at read time via `ROW_NUMBER() OVER (PARTITION BY user, app, key
  ORDER BY id DESC)` keeping `dup = 1`. This is the last-write-wins CRDT semantics. Don't convert
  it to upserts.

- **`key` and `data` are stored as JSON-serialized text** of whatever the client sent, and echoed
  back the same way. This deliberately matches the old V server's `@[raw]` behavior so existing
  clients don't change their wire format. `serde_json` uses `preserve_order`.

- **Response shape:** `data` = rows other clients wrote since `lastSyncedId` (excluding keys in this
  batch), `conflicted` = rows whose key collided with this batch's keys, `saved` = the rows just
  inserted, `lastSyncedId` = max of the incoming cursor and any ids seen/written. All writes happen
  in a single `Transaction`.

- TrailBase auth endpoints live under `/api/auth/v1/*` (register/login/logout/reset_password). See
  the README table mapping old V `/api/authentication/*` routes to their TrailBase equivalents.

## Conventions

- Migrations are immutable once applied; add a new `U<timestamp>__*.sql` rather than editing an
  existing one. Tables use `STRICT`. `user_data.user` cascade-deletes with `_user`.
- The guest release profile is size-tuned (`opt-level = "s"`, `lto`, `strip`); keep it lean —
  binary size affects the ~63 MB RSS target called out in the README.
