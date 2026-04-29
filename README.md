# ImageBase

A major architectural rewrite of ImageBase, moving off V/`veb` and onto
[TrailBase](https://trailbase.io) for the underlying framework. The custom
sync endpoint preserves the original CRDT (last-write-wins) semantics;
everything authentication-shaped is delegated to TrailBase. The custom
code is a Rust → `wasm32-wasip2` component, which keeps the trail process
at ~63 MB RSS even under load.

## Layout

```
ImageBase/
├── Makefile                            # build + run helpers
├── traildepot/
│   ├── config.textproto                # TrailBase server config
│   ├── migrations/main/*.sql           # SQL migrations (run at startup)
│   └── wasm/imagebase_guest.wasm       # built guest component (gitignored)
├── guests/rust/                        # custom endpoint source
│   ├── Cargo.toml
│   └── src/lib.rs                      # /api/data/{app} handler
├── tests/                              # Hurl integration suite
├── tasks/                              # start.sh, test.sh wrappers
└── tools/import-from-v.py              # one-shot V → TrailBase importer
```

## Prerequisites

- [`trail`](https://trailbase.io) CLI on `$PATH`
- Rust toolchain via [rustup](https://rustup.rs) with the `wasm32-wasip2` target:
  ```sh
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --target wasm32-wasip2
  ```
- `sqlite3`, `python3`, `hurl` for the test runner

## Running

```sh
make dev             # build + run with --dev (permissive CORS, email logged to stderr)
# or
make build && make run
```

On first start TrailBase prints an auto-generated admin password. The admin
UI lives at `http://localhost:4000/_/admin/`.

## Custom endpoint

`POST /api/data/{app}` is the only custom route. The `{app}` segment
namespaces every read and write, so a single TrailBase instance can back
multiple frontends without cross-tenant reads. Pick a stable id per app
(e.g. `imagebase`, `notes`, `recipes`) and reuse it from the client.

Request:
```json
{
  "lastSyncedId": 0,
  "data": [{ "key": <json-value>, "data": <json-value>, "id": 0 }]
}
```

Response:
```json
{
  "data":         [{ "key": "<json-string>", "data": "<json-string>", "id": 42 }],
  "saved":        [{ "key": "<json-string>", "id": 43 }],
  "conflicted":   [{ "key": "<json-string>", "data": "<json-string>", "id": 12, "timestamp": "..." }],
  "lastSyncedId": 43
}
```

`key` and `data` are stored and echoed back as the JSON-serialised text of
whatever the client sent, matching the V server's `@[raw]` behaviour so
existing clients do not need to change their wire format.

## What happened to the V routes?

The V server shipped hand-written auth under `/api/authentication/*`. On
TrailBase those endpoints live under `/api/auth/v1/*` and return JWT auth
tokens (plus a refresh token and CSRF token). Frontends should call:

| V server                                       | TrailBase equivalent                        |
| ---------------------------------------------- | ------------------------------------------- |
| `POST /api/authentication/register`            | `POST /api/auth/v1/register`                |
| `POST /api/authentication/login`               | `POST /api/auth/v1/login`                   |
| `POST /api/authentication/logout`              | `POST /api/auth/v1/logout`                  |
| `POST /api/authentication/forgot-password`     | `POST /api/auth/v1/reset_password/request`  |
| `POST /api/authentication/reset-password`      | `POST /api/auth/v1/reset_password/update`   |
| session cookie named `session`                 | `auth_token` (Bearer) + refresh token       |
| `/shutdown?key=...`                            | drop — send SIGTERM to the process          |

Schema-side:

- `users` / `sessions` / `password_reset` tables are gone; TrailBase owns
  `_user`, `_session`, and JWT-based reset codes.
- `data` becomes `user_data` with a `BLOB user` (UUIDv4) and a new
  `app TEXT NOT NULL` column scoping each row to one frontend.

## Migrating from V ImageBase

`tools/import-from-v.py` reads a V SQLite database and inserts users +
data into TrailBase's `main.db`.

```sh
make build                         # ensures the schema is in place
python3 tools/import-from-v.py \
    --old-db /path/to/v/app/imagebase.db \
    --app imagebase                # the app id you'll pass in the URL
```

Use `--dry-run` first to see counts. Add `--wipe-app` to clear an existing
namespace before re-importing.

What gets ported:

- `users` rows → `_user` (fresh UUIDv4, `verified=1`, empty
  `password_hash`)
- `data` rows → `user_data` scoped to the chosen `--app`, in original id
  order so client-side `lastSyncedId` cursors stay monotonically usable

What does **not** get ported:

- **Password hashes.** V used SHA-256+salt; TrailBase uses Argon2id.
  Imported users cannot log in until they go through
  `POST /api/auth/v1/reset_password/request` followed by
  `/reset_password/update` — empty `password_hash` rejects every login.
  Tell users to use the "forgot password" link on first login.
- Sessions and `password_reset` rows. Short-lived; TrailBase manages its
  own.

The script registers Python sqlite stubs for TrailBase's custom
`is_uuid()` / `is_email()` SQL functions so the inserts go through against
plain `sqlite3` with no need to load a TrailBase extension.

## Tests

`tests/` contains Hurl scripts mirroring the original
`../ImageBase/tests/`, adapted to TrailBase's auth endpoints. The runner
spawns its own short-lived `trail` on a free port (so rate-limit state
starts empty every run and the password-reset JWT can be auto-extracted
from `--dev` stderr):

```sh
./tasks/test.sh
```

The test app id is `test`; routes hit are `POST /api/data/test`.
