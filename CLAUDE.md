# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ImageBase's backend: one [Goose](https://github.com/aardappel/goose) program (`server/`)
plus a little C (`server/native/`) for sockets, SQLite, crypto and sendmail. It replaced
a TrailBase + Rust/WASM version (last at commit `e444c51`) and keeps its HTTP API
byte-compatible, so the frontends don't change. The README documents the API.

## Commands

```sh
make build      # goose build server/imagebase.goose -> server/imagebase
make check      # goose check (type/lifetime check only, fast)
make dev        # build + run with --dev (mails logged to stderr) and an access log
make run        # build + run; DATA=data ADDRESS=localhost:4000
make test       # = ./tasks/test.sh, the Hurl suite (builds, spawns its own server)
bench/run-imagebase.sh [--duration N --concurrency N --out f.json]   # load + CPU/RSS benchmark
bench/run-trailbase.sh [...]    # the same against the old TrailBase build, in a git worktree
```

`tests/tests.sh` is self-contained: it builds, starts `server/imagebase --dev` on a free
port against a throwaway data dir, runs the Hurl files in order, and kills the server.
On failure it prints the last server log lines. To run one Hurl file by hand, start
`make dev` and use `hurl --test --variables-file tests/local.env --variable url=... --variable token=...`.

Admin tasks are CLI subcommands: `server/imagebase --data DIR user verify|delete|admin <email>`,
`owner set <app> <email>`, `prune`, `migrate`. They work while the server runs (SQLite WAL).

## Prerequisites

`goose` v2026.4 on `$PATH`, gcc, the SQLite dev library (linked dynamically),
plus `hurl`, `sqlite3` and `python3` for the tests.

## Architecture

- **Threads.** `native/http.c` runs one epoll I/O thread that frames requests and
  queues them. `serve()` starts N `supervise` threads; each runs a
  `thread_spawn_contained` `worker`, which pulls requests with `ib_http_next`, runs
  `handle()`, and answers with `ib_http_respond`. If a worker aborts, its supervisor
  answers the in-flight request with a 500 (`ib_http_abandon`), closes its DB
  connection so any transaction rolls back (`ib_db_reclaim`), and restarts it. Goose
  threads share nothing: each worker has its own copy of the globals (`CFG`,
  `JWT_KEY`, its own `DB` handle), taken at spawn.
- **Errors** are `exception::throw(Fail { status, msg })` (`fail()` in util.goose).
  `handle()` catches them, rolls back any open transaction and turns them into
  text responses. Handlers just call `fail(...)`; nothing returns error codes.
- **DB** (`db.goose` over `native/db.c`): `query(sql)` returns a cached prepared
  statement. Always `defer finish(st)`. `begin_write()`/`commit()` take a
  process-wide write gate in C, so writers queue instead of spinning in SQLite's
  busy handler. Every write path uses them.
- **Routing** is in `route()` in `imagebase.goose`: split the path into segments,
  then match.
- **Migrations** are `server/migrations/NNNN_*.sql`, listed in `MIGRATIONS` in
  `maintenance.goose` and embedded at compile time. They apply in order at
  startup, tracked in `_migrations`. Never edit a shipped one; add a new file
  and a new entry.

### The sync protocol (sync.goose)

- `{app}` namespaces every read and write. The user comes from the verified JWT,
  never the body.
- `user_data` is append-only. "Latest per key" is `ROW_NUMBER() OVER (PARTITION BY
  user|space, app, key ORDER BY id DESC)` = 1. Don't turn it into upserts.
- `key`/`data` are stored as compact JSON text that `canon()` writes exactly as
  serde_json did (Goose's `json::format_*` match serde's escaping and float
  layout), and are echoed as strings.
- Response field order matters and matches the old serde output: `data, saved,
  conflicted, lastSyncedId, spaces`; rows are `key, data, id[, timestamp][, space]`.
- Spaces: a row is personal (`space IS NULL`) or a space row (`user` = the
  author). Non-members get 403 for the whole batch; `spaces` cursors are
  per space.

## Goose gotchas hit here (v2026.4)

- **Compiler bug:** a bool-returning function whose `defer` is in its outermost
  block, inlined into an `if`/`while` condition, skips the defer on the false
  path. A skipped `finish()` leaves a read snapshot open, and the connection's
  next write fails with SQLITE_BUSY_SNAPSHOT (517). Put the query and its defer
  in an inner `{ }` block and return a local. Repro: `docs/goose-defer-bug.goose`,
  upstream aardappel/goose#431; drop the workaround once a fixed release is out.
- String literals can't span lines. Multi-line SQL uses `"""` raw strings.
- `pad`, `in`, `type`, `block`, `self` are keywords.
- Optionals are rebound with `.=` (`ch .= ch.next`), not `=`.
- `Ctx` holds slices and the `out` builder together, so the checker won't let a
  handler shrink `c.out` (`clear`, `resize`). Handlers only append. Only
  `handle()` clears it, after its last use of `c`.
- Typed queues are per type: never reuse one struct type for both jobs and
  results.
- Threads need `goose build`, not `goose run`.

## Conventions

- Tables are `STRICT`. Ids are 16-byte BLOB UUIDs. No TrailBase SQL functions,
  so the stock sqlite3 CLI can write the database.
- Keep the C layer thin. Logic goes in Goose; C only moves bytes or wraps a
  library.
- Deleting a `_user` deletes their personal `user_data` rows (trigger) but only
  nulls `user` on their space rows, so shared data never rolls back.
