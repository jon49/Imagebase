# Migrating a deployment from TrailBase

This guide moves a running ImageBase deployment from the TrailBase + WASM
server (up to commit `e444c51`) to the Goose server. The HTTP API is the same,
so frontends need no changes. Users keep their passwords, sync data, spaces and
published pages. They have to log in once more after the switch.

## What carries over

| TrailBase depot | Goose server | Notes |
|---|---|---|
| `_user` | `_user` | id, email, unverified email, admin flag, timestamps, Argon2id hash (verifies unchanged) |
| `user_data` | `user_data` | same ids and AUTOINCREMENT high-water mark, so `lastSyncedId` and space cursors stay valid |
| `spaces`, `space_members`, `space_invites` | same tables | open invite codes keep working until they expire |
| `app_owners` | `app_owners` | |
| `pages` + `uploads/<object id>` | `pages` | the file bytes move into the row |
| `_session` (session.db) | — | users log in again: TrailBase's tokens were signed with its own key |
| pending verification / reset codes | — | ask anyone mid-reset to request a new link |
| `admin@localhost` | — | TrailBase's auto-created admin; skipped unless `--keep-admin-localhost` |
| config.textproto | command-line flags | see the mapping below |

## Settings

| `config.textproto` | `server/imagebase` flag |
|---|---|
| `server.application_name` | `--app-name` (used in emails) |
| `server.site_url` | `--site-url` (base of emailed links) |
| `auth.auth_token_ttl_sec` | `--auth-ttl` (default 3600) |
| `auth.refresh_token_ttl_sec` | `--refresh-ttl` (default 2592000) |
| `email.smtp_*` | none: configure your MTA behind `--sendmail` (default `/usr/sbin/sendmail`) |
| email sender | `--mail-from "ImageBase <noreply@example.com>"` |
| CORS (TrailBase's default allows any origin) | `--cors '*'` (default), a single origin, or `''` for none |
| `trail run --address` | `--address host:port` |
| `--depot` | `--data DIR` (holds `imagebase.db` and `secrets/jwt.key`) |

TLS is not built in. If `trail` was serving HTTPS directly, put a reverse proxy
(Caddy, nginx) in front and give it `--address localhost:<port>`.

## Steps

1. **Build and smoke-test** the new server on the target machine. It needs
   Goose v2026.4, gcc and the SQLite dev library:

   ```sh
   make build && make test
   ```

2. **Rehearse** against a copy of the production depot:

   ```sh
   cp -r /srv/traildepot /tmp/depot-copy
   server/imagebase --data /tmp/rehearsal migrate
   python3 tools/import-from-trailbase.py --depot /tmp/depot-copy --data /tmp/rehearsal --dry-run
   python3 tools/import-from-trailbase.py --depot /tmp/depot-copy --data /tmp/rehearsal
   server/imagebase --data /tmp/rehearsal --address localhost:4100 &
   curl -s -X POST localhost:4100/api/auth/v1/login -H 'Content-Type: application/json' \
       -d '{"email":"<a real account>","password":"<its password>"}'
   server/imagebase --data /tmp/rehearsal user list
   server/imagebase --data /tmp/rehearsal owner list
   ```

   The dry run prints the row counts it will copy. If any page file is
   missing from `uploads/`, it says so, and that page is skipped.

3. **Cut over.** Stop `trail` so nothing writes during the copy. Then import
   into a fresh data dir:

   ```sh
   systemctl stop trailbase            # or however trail is run
   server/imagebase --data /srv/imagebase-data migrate
   python3 tools/import-from-trailbase.py --depot /srv/traildepot --data /srv/imagebase-data
   ```

4. **Start the new server**, for example with a systemd unit:

   ```ini
   [Service]
   ExecStart=/opt/imagebase/server/imagebase --data /srv/imagebase-data \
       --address localhost:4000 --site-url https://imagebase.example.com \
       --mail-from "ImageBase <noreply@example.com>"
   Restart=on-failure
   ```

   SIGTERM stops it cleanly. The nightly prune runs inside the server at
   03:30 UTC, so no cron job is needed.

5. **Check**: log in, sync, fetch a published page
   (`GET /api/pages/<app>/<id>`), and request a password reset to confirm mail
   gets delivered.

## Rolling back

The import only reads the TrailBase depot. To roll back, stop the new server
and start `trail` on the old depot again. Anything written in the meantime
stays in `imagebase.db` and won't be in the depot.

## Admin without the admin UI

| TrailBase admin UI | Now |
|---|---|
| verify a user | `imagebase --data DIR user verify <email>` |
| delete a user | `imagebase --data DIR user delete <email>` |
| toggle admin | `imagebase --data DIR user admin\|unadmin <email>` |
| list users | `imagebase --data DIR user list` |
| set an app's page owner (SQL on `app_owners`) | `imagebase --data DIR owner set <app> <email>` |
| run the prune job now | `imagebase --data DIR prune` |
| browse tables | `sqlite3 DIR/imagebase.db` (no TrailBase-only SQL functions are needed) |

All of these work while the server is running.
