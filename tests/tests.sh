#!/usr/bin/env bash
# Integration tests for NewImageBase. Spawns its own short-lived `trail` so
# every run starts with empty in-memory rate-limit state and `--dev`-mode
# stderr captured to a temp file (used to auto-extract the password-reset
# JWT for create-new-password).
#
# Picks a free port to avoid clashing with a long-running `make dev`. Both
# servers share the same data dir; SQLite multi-process locking handles it.

set -euo pipefail

ENV_FILE="${ENV_FILE:-local.env}"
DATA_DIR="${DATA_DIR:-../traildepot}"

cd "$(dirname "$0")"

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
}
trap cleanup EXIT

echo "--- building wasm guest ---"
(cd .. && make deploy >/dev/null)

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

echo "--- logout flow ---"
run_hurl logout.tests.hurl

echo "--- done ---"
