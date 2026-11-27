# ImageBase

The ImageBase backend: a last-write-wins CRDT sync API, shared spaces,
published HTML pages and accounts (register, email verification, login,
refresh/logout, password reset, self-service delete). It is a single
[Goose](https://github.com/aardappel/goose) program (about 2,400 lines) with about 1,000 lines of C
underneath for what Goose has no library for: an epoll HTTP/1.1 front end, a
SQLite binding, SHA-256/HMAC, Argon2id (vendored) and sendmail.

It replaces the TrailBase + Rust/WASM version. TrailBase's admin UI and
generic record APIs are gone (see
[Differences from the TrailBase version](#differences-from-the-trailbase-version)).

**One server per application.** The TrailBase version let several frontends
share one server, with an `{app}` id in every path. Since a server now idles
at about 7 MB, each app gets its own server process and data dir instead, and
nothing is namespaced. The `{app}` segment is gone from the paths too:
`/api/data/soccer` is now `/api/data` on soccer's own server.
Idle RSS went from about 100 MB to 7 MB, and CPU per request is 6–70x lower
except for password hashing; see [docs/benchmarks.md](docs/benchmarks.md).

## Layout

```
server/
  imagebase.goose      entry point: router, worker pool, CLI
  imagebase.build      native sources and libraries for `goose build`
  auth.goose           /api/auth/v1/*: accounts, sessions, HS256 JWTs, reset pages
  sync.goose           POST /api/data: the sync protocol
  spaces.goose         /api/spaces, /api/invites: shared-space membership
  pages.goose          /api/records/v1/pages: pages written as files to --pages-dir
  maintenance.goose    migrations runner and the nightly prune
  http.goose db.goose util.goose config.goose mail.goose
  migrations/*.sql     schema, embedded in the binary
  native/              http.c, db.c, crypto.c, argon2/ (vendored, CC0/Apache-2.0)
tests/                 Hurl integration suite (tests.sh runs it)
bench/                 load + resource benchmark, before/after results
tools/                 importers from a TrailBase depot and from the V server
```

## Prerequisites

- [Goose](https://github.com/aardappel/goose) v2026.4 or newer. The task scripts use a
  checkout beside this repo (`../goose`) when there is one: `tasks/update-goose.sh`
  clones or pulls it, builds it (needs cmake ≥ 3.27 and a C++20 compiler), rebuilds the
  server and runs the tests. Otherwise `goose` on `$PATH` is used
- a C compiler (gcc or clang) and SQLite ≥ 3.38 development files (`libsqlite3-dev`)
- for the tests: `hurl`, `curl`, `python3`, `sqlite3`
- for delivering mail: a `sendmail`-compatible command (msmtp, postfix, ...)

## Running

```sh
make build                          # -> server/imagebase (about 320 KB)
make dev                            # --dev: mails are logged to stderr, every request is logged
make run                            # DATA=data ADDRESS=localhost:4000 by default
```

Run one server per app, each with its own data dir and port. Locally, soccer
uses `make dev DATA=data/soccer` (:4000) and weight
`make dev DATA=data/weight ADDRESS=localhost:4001`; their `start:full` scripts
do this for you. In production, give each app its own service and point its
reverse proxy's `/api/` (and `/_/`, for the password-reset page) at it.

`server/imagebase --help` lists everything. The common options are
`--data DIR` (database `imagebase.db` and `secrets/jwt.key`; default `./data`),
`--address host:port`, `--site-url URL` (used in emailed links),
`--workers N`, `--mail-from`, `--sendmail CMD` and `--cors ORIGIN` (default `*`,
which echoes any Origin as TrailBase did). TLS is not built in: put the server
behind a reverse proxy (Caddy, nginx) for HTTPS. SIGTERM or SIGINT shuts it
down cleanly.

Administration is by subcommand on the same binary. These work while the
server is running:

```sh
imagebase --data data user list
imagebase --data data user verify|delete|admin|unadmin someone@example.com
imagebase --data data owner set owner@example.com            # who may publish pages
imagebase --data data owner                                  # show it (owner clear removes it)
imagebase --data data prune                                  # also runs nightly at 03:30 UTC
imagebase --data data migrate                                # also runs at every start
```

## Moving over from TrailBase

```sh
make build
server/imagebase --data data migrate
python3 tools/import-from-trailbase.py --depot traildepot --data data --dry-run
python3 tools/import-from-trailbase.py --depot traildepot --data data   # --app NAME if it has several
```

The import copies users with their Argon2 password hashes, so passwords keep
working. From one app (`--app`, needed only when the depot served several), it
copies spaces, members, invites, the page owner and sync rows, keeping their
ids, so client cursors stay valid. For several apps, import each into its own
data dir and run a server for each. Published pages come across
too: their bytes are read out of `traildepot/uploads/` and written as files to
the importer's `--pages-dir` (the server's). Sessions don't come
across: TrailBase's tokens were signed with its own key, so users log in once
more. `tools/import-from-v.py` still imports from the original V server. For a production
cutover, follow [docs/migrating-from-trailbase.md](docs/migrating-from-trailbase.md).

## API

All bodies are JSON unless noted. `Authorization: Bearer <auth_token>` marks an
authenticated call.

### Accounts (`/api/auth/v1`)

| Method & path | Body | Result |
|---|---|---|
| `POST register` | `email`, `password`, `password_repeat` (JSON or form) | `200 registered`, then a verification mail. The same answer for a known address, so it can't be used to find accounts |
| `GET verify_email/confirm/{code}` | | marks the email verified (the link in that mail) |
| `POST login` | `email`, `password` | `{auth_token, refresh_token, csrf_token}`. `401` if wrong; `429` after 10 failures in 15 min |
| `POST refresh` | `refresh_token` | `{auth_token, csrf_token}` |
| `POST logout` | `refresh_token` (or none, with a Bearer token, to end all sessions) | `200` |
| `GET /api/healthcheck` | | `200 Ok`: a liveness probe, no auth |
| `GET status` | | `{auth_token, refresh_token: null, csrf_token}`, or nulls |
| `POST reset_password/request` | `email` | mails a link to `/_/auth/reset_password/update/{code}`, a small HTML form. `429` within an hour of the last one |
| `POST reset_password/update` | `password_reset_code`, `password`, `password_repeat` | `200`, and ends all sessions |
| `POST change_password` | `old_password`, `new_password`, `new_password_repeat` (Bearer) | `200` |
| `DELETE delete` | (Bearer) | deletes the caller's account and sessions |

`auth_token` is an HS256 JWT with TrailBase's claims (`sub` = the user id as
url-safe base64, `email`, `iat`, `exp`, `csrf_token`, ...), valid for an hour
(`--auth-ttl`). Refresh tokens last 30 days (`--refresh-ttl`). Passwords need
8–128 characters.

Deleting an account removes the user's personal sync rows and memberships, and
a space they were the last member of goes with its data. Rows they wrote into
a space that still has members are kept with their author cleared, so the other
members' data doesn't roll back. The auth token stays cryptographically valid
until it expires, but every route checks that the user still exists and
answers `401`.

### Sync: `POST /api/data` (Bearer)

```json
{ "lastSyncedId": 0,
  "spaces": { "<space uuid>": 0 },
  "data": [{ "key": <json>, "data": <json>, "space": "<space uuid, optional>" }] }
```

```json
{ "data":        [{ "key": "<json text>", "data": "<json text>", "id": 42 }],
  "saved":       [{ "key": "<json text>", "id": 43 }],
  "conflicted":  [{ "key": "<json text>", "data": "<json text>", "id": 12, "timestamp": "..." }],
  "lastSyncedId": 43,
  "spaces":      { "<space uuid>": 43 } }
```

- `user_data` is append-only: each upload inserts rows, and the latest value
  per key is derived at read time. That is the last-write-wins rule.
- `data` holds rows other clients wrote since your cursor. `conflicted` holds
  the ones whose key you are writing in this batch. `saved` holds what you
  just wrote.
- `key` and `data` are stored and echoed as the compact JSON text of what the
  client sent, byte for byte as serde_json wrote it, the V server's `@[raw]`
  format.
- Items with `"space"` go into that shared space. Non-members get `403` for
  the whole batch. `lastSyncedId` covers personal rows only; `spaces` carries
  one cursor per space you belong to (a space you omit starts at 0). Space
  rows carry `space`; personal rows don't.

### Shared spaces (Bearer; non-members get 404, so space ids can't be probed)

| Method & path | Result |
|---|---|
| `POST /api/spaces` | `{space}`: a new space with you as its only member |
| `GET /api/spaces/{space}/members` | `{members: [{user, email, joined, me}]}` |
| `DELETE /api/spaces/{space}/members/{user or me}` | removes a member. The last one leaving deletes the space and its data |
| `POST /api/spaces/{space}/invites` | `{code, expires}`: single use, valid for 7 days |
| `GET /api/invites/{code}` | `{space, invitedBy, expires, member}` |
| `POST /api/invites/{code}/accept` | `{space}`. A no-op for an existing member, and the code stays usable |

Every member has the same rights.

### Published pages

Pages are **files**: the server writes each one to `<pages-dir>/<id>.html`
(`--pages-dir DIR`, off when not given) so the web server can serve the
directory as it is, e.g. nginx:

```nginx
location ~ "^/api/pages/(?<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$" {
    alias /var/www/example/pages/$id.html;
    types { }                 # nginx types by the URI, which has no extension
    default_type text/html;
    charset utf-8;
    add_header Cache-Control "no-cache";
}
```

The space a page belongs to is the one line of `<pages-dir>/.spaces/<id>`,
which only the write rules read (a well-formed id never maps to it). Writes are
atomic (a new file renamed over the old). Keep the directory out of anything a
deploy replaces wholesale. It isn't in the database, so back it up separately,
or treat pages as regenerable by republishing.

Pages **expire**: the nightly prune (and `imagebase prune`) deletes a page not
written for `--pages-max-age` days (default 90; 0 keeps pages forever). Its
`.spaces/<id>` line stays (`owner` for a page outside a space), so the old link
can be republished only by whoever could write the page before, never claimed
by someone else.

| Method & path | Auth | |
|---|---|---|
| `POST /api/records/v1/pages` | page owner, or member of `space` | create, or overwrite the same `id` |
| `PATCH /api/records/v1/pages/{id}` | page owner, or member of the page's space | replace `html` and/or set `space` |
| `DELETE /api/records/v1/pages/{id}` | same | |
| `GET /api/pages/{id}` | none | the file, `text/html; charset=utf-8`, inline (for development; in production the web server serves the directory) |

```json
{ "id": "3f1a2b3c-0000-4000-8000-000000000001",
  "space": "<optional space uuid>",
  "html": { "filename": "standings.html", "content_type": "text/html", "data": "<base64>" } }
```

`id` is a UUID your client picks; it is the page's permanent address. `data`
may be standard or url-safe base64. `multipart/form-data` works too, with
fields `id`, `space` and a file field `html`. Create returns
`{"ids": ["<base64 id>"]}`. Anyone else gets `403`, including callers with no
token. The page owner is one account, set with `imagebase owner set <email>`.
A space member can't overwrite a page that belongs to another space or to none.

## Tests

```sh
./tasks/test.sh             # or: make test
```

The runner builds the server and starts it with `--dev` on a free port against
a throwaway data dir, so ids start clean and reset codes can be read from the
mail log. It runs the Hurl files in order and adds a few direct database
checks (invite expiry, account and member deletion, prune). Set `DATA_DIR` to
run against an existing data dir.

## Benchmarks

```sh
bench/run-imagebase.sh --duration 15 --concurrency 8 --out after.json
bench/run-trailbase.sh --duration 15 --concurrency 8 --out before.json   # builds e444c51 in a worktree
python3 bench/compare.py before.json after.json
```

See [docs/benchmarks.md](docs/benchmarks.md) for the method and the numbers.

## Differences from the TrailBase version

- **No admin UI and no generic Record API.** Administration is the CLI
  subcommands above plus plain SQL on `data/imagebase.db`. It has no
  TrailBase-only SQL functions, so the stock `sqlite3` works.
- **Pages are files in `--pages-dir`**, served by the web server, not rows in
  an object store. S3 isn't supported.
- **Tokens are HS256** (a secret in `secrets/jwt.key`), not EdDSA. The claim
  set is the same.
- **Refresh tokens and mailed codes are stored only as SHA-256 hashes.**
- **Rate limiting** covers login failures (per address) and reset mails (one
  per hour per address). There is no per-IP limiter, so put one in the reverse
  proxy if registration spam is a concern.
- **One app per server**, as described at the top, with one page owner
  instead of an owner per app.
- **Chunked request bodies aren't accepted** (`411`). Clients send
  `Content-Length`, as curl, browsers and Hurl do.

### V server routes

| V server | Now |
|---|---|
| `POST /api/authentication/register` | `POST /api/auth/v1/register` |
| `POST /api/authentication/login` | `POST /api/auth/v1/login` |
| `POST /api/authentication/logout` | `POST /api/auth/v1/logout` |
| `POST /api/authentication/forgot-password` | `POST /api/auth/v1/reset_password/request` |
| `POST /api/authentication/reset-password` | `POST /api/auth/v1/reset_password/update` |
| session cookie named `session` | `auth_token` (Bearer) + refresh token |
| `/shutdown?key=...` | send SIGTERM |
