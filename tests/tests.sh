#!/usr/bin/env bash
# Integration tests for ImageBase. Spawns its own short-lived `trail` on a free
# port so every run starts with empty in-memory rate-limit state and `--dev`-mode
# stderr captured to a temp file (used to auto-extract the password-reset JWT for
# create-new-password).
#
# By default it runs against an isolated, throwaway data dir seeded from the
# project depot, so autoincrement ids start clean (several tests assert exact
# ids) and real dev data is never read or written. Set DATA_DIR to point the
# tests at an existing depot instead.

set -euo pipefail

ENV_FILE="${ENV_FILE:-local.env}"
SRC_DEPOT="${SRC_DEPOT:-../traildepot}"

cd "$(dirname "$0")"

if [ -n "${DATA_DIR:-}" ]; then
    OWN_DATA_DIR=0
else
    DATA_DIR="$(mktemp -d)"
    OWN_DATA_DIR=1
    cp "$SRC_DEPOT/config.textproto" "$DATA_DIR/"
    cp -r "$SRC_DEPOT/migrations" "$DATA_DIR/"
    mkdir -p "$DATA_DIR/wasm"
fi

email=$(grep '^email=' "$ENV_FILE" | cut -d= -f2-)

TEST_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
TEST_URL="http://localhost:$TEST_PORT"
LOG_FILE="$(mktemp)"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$LOG_FILE"
    if [ "${OWN_DATA_DIR:-0}" = 1 ]; then
        rm -rf "$DATA_DIR"
    fi
}
trap cleanup EXIT

echo "--- building wasm guest ---"
(cd .. && make deploy >/dev/null)
# make deploy copies the freshly built wasm into the source depot; mirror it
# into the isolated data dir the test server actually runs against.
if [ "$OWN_DATA_DIR" = 1 ]; then
    cp "$SRC_DEPOT/wasm/imagebase_guest.wasm" "$DATA_DIR/wasm/"
fi

echo "--- starting trail on $TEST_URL ---"
trail --data-dir="$DATA_DIR" run --address="localhost:$TEST_PORT" --dev --stderr-logging \
    >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    if curl -sf -m 1 "$TEST_URL/api/auth/v1/status" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "trail failed to start. Last log lines:"
        tail -30 "$LOG_FILE"
        exit 1
    fi
    sleep 0.1
done

run_hurl() {
    hurl --test --jobs 1 --variables-file "$ENV_FILE" --variable "url=$TEST_URL" "$@"
}

echo "--- unauthorized probe ---"
run_hurl unauthorized.tests.hurl

echo "--- invalid register payloads ---"
run_hurl invalid-register.tests.hurl

echo "--- register canonical user (idempotent) ---"
run_hurl register-user.tests.hurl

echo "--- mark user verified so login can succeed ---"
sqlite3 "$DATA_DIR/data/main.db" \
    "UPDATE _user SET verified = 1 WHERE email = '$email';"

echo "--- invalid login attempts ---"
run_hurl invalid-login.tests.hurl

echo "--- login & capture token ---"
token=$(hurl --variables-file "$ENV_FILE" --variable "url=$TEST_URL" login.hurl \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth_token"])')

echo "--- forgot-password request ---"
run_hurl forgot-password.tests.hurl

# In --dev mode trailbase logs the email body containing
# `/_/auth/reset_password/update/<jwt>` to stderr — grab the JWT and feed
# it to create-new-password. The sleep gives the log a moment to flush.
sleep 0.3
RESET_CODE=$(grep -oE '/_/auth/reset_password/update/[A-Za-z0-9._-]+' "$LOG_FILE" \
    | tail -1 | awk -F/ '{print $NF}')
if [ -n "$RESET_CODE" ]; then
    echo "--- create-new-password (auto-extracted code) ---"
    run_hurl --variable "reset_code=$RESET_CODE" create-new-password.tests.hurl
else
    echo "--- create-new-password skipped (no reset code in dev log) ---"
fi

echo "--- wipe previous test rows ---"
sqlite3 "$DATA_DIR/data/main.db" \
    "DELETE FROM user_data WHERE user = (SELECT id FROM _user WHERE email = '$email'); \
     DELETE FROM sqlite_sequence WHERE name = 'user_data';"

echo "--- sync tests ---"
run_hurl --variable "token=$token" add-data.tests.hurl
run_hurl --variable "token=$token" validation.tests.hurl

echo "--- prune job: seed overwrite history under app=prune ---"
run_hurl --variable "token=$token" prune-seed.tests.hurl

# Age the older "old" row (every non-latest row for that key) past the one-month
# retention window so the prune job becomes eligible to delete it. "recent" rows
# are left untouched and must survive.
echo "--- prune job: age the overwritten 'old' row past retention ---"
sqlite3 "$DATA_DIR/data/main.db" "
    UPDATE user_data
       SET timestamp = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 months')
     WHERE app = 'prune' AND key = '\"old\"'
       AND id < (SELECT MAX(id) FROM user_data WHERE app = 'prune' AND key = '\"old\"');"

before=$(sqlite3 "$DATA_DIR/data/main.db" "SELECT COUNT(*) FROM user_data WHERE app = 'prune';")
echo "rows under app=prune before prune: $before (expect 4)"

# The admin job API requires an admin user + matching CSRF token. Promote the
# canonical test user, then log in fresh so the token carries admin rights and
# we capture the CSRF token that pairs with it.
echo "--- prune job: promote test user to admin ---"
sqlite3 "$DATA_DIR/data/main.db" "UPDATE _user SET admin = 1 WHERE email = '$email';"

login_json=$(hurl --variables-file "$ENV_FILE" --variable "url=$TEST_URL" login.hurl)
admin_token=$(echo "$login_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth_token"])')
admin_csrf=$(echo "$login_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["csrf_token"])')

echo "--- prune job: trigger on demand via admin API ---"
run_hurl --variable "token=$admin_token" --variable "csrf=$admin_csrf" prune-run.tests.hurl

after=$(sqlite3 "$DATA_DIR/data/main.db" "SELECT COUNT(*) FROM user_data WHERE app = 'prune';")
old_left=$(sqlite3 "$DATA_DIR/data/main.db" "SELECT COUNT(*) FROM user_data WHERE app = 'prune' AND key = '\"old\"';")
recent_left=$(sqlite3 "$DATA_DIR/data/main.db" "SELECT COUNT(*) FROM user_data WHERE app = 'prune' AND key = '\"recent\"';")
echo "rows under app=prune after prune: $after (expect 3)"

# The aged "old" overwrite must be gone (key keeps only its latest), while both
# "recent" rows survive because they're inside the retention window.
if [ "$after" != "3" ] || [ "$old_left" != "1" ] || [ "$recent_left" != "2" ]; then
    echo "FAIL: prune left app=prune in an unexpected state" \
         "(total=$after old=$old_left recent=$recent_left; expected 3/1/2)"
    exit 1
fi
echo "prune assertions passed (deleted the aged overwrite, kept latest + recent)"

echo "--- logout flow ---"
run_hurl logout.tests.hurl

echo "--- done ---"
