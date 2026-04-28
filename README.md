# NewImageBase

A port of [ImageBase](../ImageBase) from V/`veb` to
[TrailBase](https://trailbase.io). It keeps the same CRDT (last-write-wins)
sync semantics on `POST /api/data`, but delegates users, sessions, and
password reset flows to TrailBase's built-in auth rather than hand-rolling
them in V.

## Layout

```
NewImageBase/
├── Makefile                         # build + run helpers
├── traildepot/
│   ├── config.textproto             # TrailBase server config
│   ├── migrations/main/*.sql        # SQL migrations (run at startup)
│   └── wasm/imagebase_guest.wasm    # compiled custom endpoint (built)
├── guests/typescript/               # custom endpoint source
│   ├── src/index.ts                 # /api/data handler
│   ├── src/component.js             # WASM component entry
│   ├── package.json
│   ├── tsconfig.json
│   └── vite.config.ts
└── tests/                           # Hurl integration tests
```

## Prerequisites

- [`trail`](https://trailbase.io) CLI on `$PATH`
- Node.js (20+) and `npm`

## Running

```sh
make dev             # build + run with --dev (permissive CORS)
# or
make build && make run
```

On first start TrailBase prints an auto-generated admin password to stdout.
Admin UI lives at `http://localhost:4000/_/admin/`.

## Custom endpoint

`POST /api/data` is the only custom endpoint. It reads the authenticated
user from the request context (populated by TrailBase from the `Bearer`
auth token or session cookie) and implements the sync protocol:

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
  "data":       [{ "key": "<json-string>", "data": "<json-string>", "id": 42 }],
  "saved":      [{ "key": "<json-string>", "id": 43 }],
  "conflicted": [{ "key": "<json-string>", "data": "<json-string>", "id": 12, "timestamp": "..." }],
  "lastSyncedId": 43
}
```

`key` and `data` are stored and echoed back as the JSON-serialised text of
whatever the client sent, matching the V server's `@[raw]` behaviour so
existing clients do not need to change.

## What happened to the V routes?

The V server shipped hand-written auth under `/api/authentication/*`. On
TrailBase those endpoints live under `/api/auth/v1/*` and return JWT auth
tokens (plus a refresh token and CSRF token). Clients should:

| V server                                       | TrailBase equivalent                  |
| ---------------------------------------------- | ------------------------------------- |
| `POST /api/authentication/register`            | `POST /api/auth/v1/register`          |
| `POST /api/authentication/login`               | `POST /api/auth/v1/login`             |
| `POST /api/authentication/logout`              | `POST /api/auth/v1/logout`            |
| `POST /api/authentication/forgot-password`     | `POST /api/auth/v1/reset_password/request` |
| `POST /api/authentication/reset-password`      | `POST /api/auth/v1/reset_password/update`  |
| session cookie named `session`                 | `auth_token` (Bearer) + refresh token |
| `/shutdown?key=...`                            | drop – send SIGTERM to the process    |
| `/hello`                                       | drop – wire up as a WASM route if needed |

The CRDT data model changes slightly:

- `users` / `sessions` / `password_reset` tables are gone – TrailBase owns
  them in `_user` + `_user_session` + friends.
- `data` becomes `user_data` with a `BLOB user` foreign key to `_user(id)`
  (UUIDv7) instead of an `INTEGER user_id`.

## Tests

`tests/` contains Hurl scripts mirroring the original `../ImageBase/tests/`,
adapted to TrailBase's auth endpoints. Run with:

```sh
make dev &                 # or run in another terminal
tests/tests.sh
```

The test script registers + verifies a user directly against SQLite (TrailBase
sends a verification email that we cannot receive locally), logs in to obtain
a Bearer token, and exercises the sync endpoint.
