#!/usr/bin/env bash
# Integration tests for ImageBase. Builds the server, spawns its own short-lived
# instance on a free port with `--dev`, so mails go to a captured stderr log
# (used to auto-extract the password-reset code for create-new-password).
#
# By default it runs against an isolated, throwaway data dir, so autoincrement
# ids start clean (several tests assert exact ids) and real dev data is never
# read or written. Set DATA_DIR to point the tests at an existing one instead.

set -euo pipefail

ENV_FILE="${ENV_FILE:-local.env}"

cd "$(dirname "$0")"

if [ -n "${DATA_DIR:-}" ]; then
    OWN_DATA_DIR=0
else
    DATA_DIR="$(mktemp -d)"
    OWN_DATA_DIR=1
fi
IMAGEBASE="$(cd .. && pwd)/server/imagebase"
ib() { "$IMAGEBASE" --data "$DATA_DIR" "$@"; }
DB="$DATA_DIR/imagebase.db"

email=$(grep '^email=' "$ENV_FILE" | cut -d= -f2-)

TEST_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
TEST_URL="http://localhost:$TEST_PORT"
LOG_FILE="$(mktemp)"
SERVER_PID=""

cleanup() {
    status=$?
    if [ "$status" != 0 ] && [ -s "$LOG_FILE" ]; then
        echo "--- last server log lines ---"
        tail -20 "$LOG_FILE"
    fi
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

echo "--- building server ---"
(cd .. && make build >/dev/null)

echo "--- starting imagebase on $TEST_URL ---"
PAGES="$DATA_DIR/pages"
ib --address "localhost:$TEST_PORT" --dev --pages-dir "$PAGES" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    if curl -sf -m 1 "$TEST_URL/api/auth/v1/status" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "imagebase failed to start. Last log lines:"
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

# Unverified users can't log in; skip opening the emailed link.
verify() {
    ib user verify "$1" >/dev/null
}

echo "--- mark user verified so login can succeed ---"
verify "$email"

echo "--- invalid login attempts ---"
run_hurl invalid-login.tests.hurl

echo "--- login & capture token ---"
token=$(hurl --variables-file "$ENV_FILE" --variable "url=$TEST_URL" login.hurl \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth_token"])')

echo "--- forgot-password request ---"
run_hurl forgot-password.tests.hurl

# In --dev mode the server logs the email body containing
# `/_/auth/reset_password/update/<code>` to stderr — grab the code and feed
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
sqlite3 "$DB" \
    "DELETE FROM user_data WHERE user = (SELECT id FROM _user WHERE email = '$email'); \
     DELETE FROM sqlite_sequence WHERE name = 'user_data';"

echo "--- sync tests ---"
run_hurl --variable "token=$token" add-data.tests.hurl
run_hurl --variable "token=$token" validation.tests.hurl

echo "--- register + verify + log in a second user (not the page owner) ---"
email_b=$(grep '^email_b=' "$ENV_FILE" | cut -d= -f2-)
password=$(grep '^password=' "$ENV_FILE" | cut -d= -f2-)
curl -s -o /dev/null -X POST "$TEST_URL/api/auth/v1/register" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email_b\",\"password\":\"$password\",\"password_repeat\":\"$password\"}"
verify "$email_b"
token_b=$(curl -sf -X POST "$TEST_URL/api/auth/v1/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email_b\",\"password\":\"$password\"}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth_token"])')

echo "--- publish page: make the test user the page owner ---"
ib owner set "$email" >/dev/null

echo "--- publish page: create / fetch inline / overwrite / authz ---"
run_hurl --variable "token=$token" --variable "token_b=$token_b" publish-page.tests.hurl

# Pages are files in --pages-dir, which nginx serves in production. The page
# owner's page has no space.
p1="$PAGES/11111111-1111-1111-1111-111111111111.html"
if ! grep -q "PUBLISHED-V2" "$p1" || [ -e "$PAGES/.spaces/11111111-1111-1111-1111-111111111111" ]; then
    echo "FAIL: the owner's page isn't $p1 with no space file"
    exit 1
fi
echo "page file assertions passed (owner page on disk, no space)"

# Spaces tests count A's personal rows from scratch.
sqlite3 "$DB" "DELETE FROM user_data WHERE user = (SELECT id FROM _user WHERE email = '$email');"

echo "--- spaces: seed spaces + memberships ---"
sqlite3 "$DB" "
    INSERT INTO spaces (id) VALUES
      (X'55555555555555555555555555555555'),
      (X'66666666666666666666666666666666');
    INSERT INTO space_members (space, user)
      SELECT X'55555555555555555555555555555555', id FROM _user WHERE email IN ('$email', '$email_b')
      UNION ALL SELECT X'66666666666666666666666666666666', id FROM _user WHERE email = '$email';"

echo "--- spaces: shared sync + space-member page publishing ---"
run_hurl --variable "token=$token" --variable "token_b=$token_b" spaces.tests.hurl

# The space member's page records its space beside it; the refused writes
# left nothing behind.
space_of=$(cat "$PAGES/.spaces/88888888-8888-8888-8888-888888888888" 2>/dev/null || true)
if [ "$space_of" != "55555555-5555-5555-5555-555555555555" ] || ! grep -q "SHARED-A" "$PAGES/88888888-8888-8888-8888-888888888888.html" \
   || [ -e "$PAGES/99999999-9999-9999-9999-999999999999.html" ] || grep -q HIJACK "$p1" \
   || [ -e "$PAGES/77777777-7777-4777-8777-777777777777.html" ] || [ -e "$PAGES/.spaces/77777777-7777-4777-8777-777777777777" ]; then
    echo "FAIL: space page files are wrong (space=$space_of)"
    exit 1
fi
echo "space page file assertions passed"

# Pages expire --pages-max-age (90) days after their last write. Age two, keep
# one fresh, prune, and check what's left.
echo "--- pages: expiry after 90 days without a write ---"
p8="$PAGES/88888888-8888-8888-8888-888888888888.html"
touch -d '100 days ago' "$p1" "$p8"
curl -sf -o /dev/null -X POST "$TEST_URL/api/records/v1/pages" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d '{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","html":{"filename":"f.html","content_type":"text/html","data":"PGgxPkZSRVNIPC9oMT4="}}'
ib --pages-dir "$PAGES" prune
fresh=$(find "$PAGES" -maxdepth 1 -name '*.html' | wc -l)
if [ -e "$p1" ] || [ -e "$p8" ] || [ ! -e "$PAGES/cccccccc-cccc-4ccc-8ccc-cccccccccccc.html" ] || [ "$(cat "$PAGES/.spaces/11111111-1111-1111-1111-111111111111")" != "owner" ] \
   || [ "$(cat "$PAGES/.spaces/88888888-8888-8888-8888-888888888888")" != "55555555-5555-5555-5555-555555555555" ]; then
    echo "FAIL: expired pages weren't deleted with their owners kept"
    exit 1
fi
echo "page expiry assertions passed (2 expired, $fresh fresh left, owners kept)"
run_hurl --variable "token=$token" --variable "token_b=$token_b" page-expiry.tests.hurl
if [ -e "$PAGES/.spaces/11111111-1111-1111-1111-111111111111" ]; then
    echo "FAIL: the owner's republished page still has an owner marker"
    exit 1
fi

echo "--- spaces: create / invite / accept / remove / leave ---"
spaces_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM spaces;")
run_hurl --variable "token=$token" --variable "token_b=$token_b" invites.tests.hurl

# The space invites.tests.hurl made lost its last member, so it must be gone.
spaces_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM spaces;")
if [ "$spaces_after" != "$spaces_before" ]; then
    echo "FAIL: memberless space was not garbage-collected (spaces $spaces_before -> $spaces_after)"
    exit 1
fi

# Expiry can't be fast-forwarded over HTTP: mint a space, plant an already
# expired invite next to a live one, and check only the live one is accepted.
echo "--- spaces: expired invites are refused ---"
expiry_space=$(curl -sf -X POST "$TEST_URL/api/spaces" -H "Authorization: Bearer $token" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["space"].replace("-",""))')
sqlite3 "$DB" "
    INSERT INTO space_invites (code, space, created_by, expires)
      SELECT X'aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa', X'$expiry_space', id, UNIXEPOCH() - 1 FROM _user WHERE email = '$email';
    INSERT INTO space_invites (code, space, created_by, expires)
      SELECT X'bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb', X'$expiry_space', id, UNIXEPOCH() + 60 FROM _user WHERE email = '$email';"
expired_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $token_b" \
    "$TEST_URL/api/invites/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/accept")
live_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $token_b" \
    "$TEST_URL/api/invites/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/accept")
if [ "$expired_status" != "404" ] || [ "$live_status" != "200" ]; then
    echo "FAIL: invite expiry (expired=$expired_status, expect 404; live=$live_status, expect 200)"
    exit 1
fi
echo "invite expiry assertions passed"

# Deleting a member must drop their personal rows and memberships but keep what
# they wrote into a shared space (authorless), so the other members' data
# doesn't roll back to older values.
echo "--- spaces: delete the second user ---"
b_space_rows=$(sqlite3 "$DB" "
    SELECT COUNT(*) FROM user_data
     WHERE space IS NOT NULL AND user = (SELECT id FROM _user WHERE email = '$email_b');")
# Via the CLI, which deletes exactly as the self-service API does (FKs on).
ib user delete "$email_b" >/dev/null
orphaned=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE user IS NULL AND space IS NOT NULL;")
personal_left=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE value = '{\"b\":\"personal\"}';")
s1_members=$(sqlite3 "$DB" "SELECT COUNT(*) FROM space_members WHERE space = X'55555555555555555555555555555555';")
if [ "$b_space_rows" = "0" ] || [ "$orphaned" != "$b_space_rows" ] || [ "$personal_left" != "0" ] || [ "$s1_members" != "1" ]; then
    echo "FAIL: user delete left spaces in an unexpected state" \
         "(b_space_rows=$b_space_rows orphaned=$orphaned personal_left=$personal_left s1_members=$s1_members)"
    exit 1
fi
echo "user-delete assertions passed (kept $orphaned shared row(s), dropped personal rows + membership)"

echo "--- prune job: seed overwrite history (keys \"old\" and \"recent\") ---"
run_hurl --variable "token=$token" prune-seed.tests.hurl

# Age the older "old" row (every non-latest row for that key) past the one-month
# retention window so the prune job becomes eligible to delete it. "recent" rows
# are left untouched and must survive.
echo "--- prune job: age the overwritten 'old' row past retention ---"
sqlite3 "$DB" "
    UPDATE user_data
       SET timestamp = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 months')
     WHERE key = '\"old\"'
       AND id < (SELECT MAX(id) FROM user_data WHERE key = '\"old\"');"

before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE key IN ('\"old\"', '\"recent\"');")
echo "prune rows before prune: $before (expect 4)"

echo "--- prune job: run it on demand ---"
ib prune

after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE key IN ('\"old\"', '\"recent\"');")
old_left=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE key = '\"old\"';")
recent_left=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE key = '\"recent\"';")
echo "prune rows after prune: $after (expect 3)"

# The aged "old" overwrite must be gone (key keeps only its latest), while both
# "recent" rows survive because they're inside the retention window.
if [ "$after" != "3" ] || [ "$old_left" != "1" ] || [ "$recent_left" != "2" ]; then
    echo "FAIL: prune left the old/recent rows in an unexpected state" \
         "(total=$after old=$old_left recent=$recent_left; expected 3/1/2)"
    exit 1
fi
echo "prune assertions passed (deleted the aged overwrite, kept latest + recent)"

echo "--- logout flow ---"
run_hurl logout.tests.hurl

# Runs last so its user_data rows can't shift the exact ids earlier tests assert.
echo "--- delete account: register + verify a throwaway user ---"
email_c=$(grep '^email_c=' "$ENV_FILE" | cut -d= -f2-)
curl -s -o /dev/null -X POST "$TEST_URL/api/auth/v1/register" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email_c\",\"password\":\"$password\",\"password_repeat\":\"$password\"}"
verify "$email_c"
c_id=$(sqlite3 "$DB" "SELECT hex(id) FROM _user WHERE email = '$email_c';")

echo "--- delete account: self-service delete, stale token rejected ---"
spaces_before_delete=$(sqlite3 "$DB" "SELECT COUNT(*) FROM spaces;")
run_hurl delete-account.tests.hurl

users_left=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _user WHERE id = X'$c_id';")
rows_left=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user_data WHERE key = '\"doomed\"';")
spaces_left=$(( $(sqlite3 "$DB" "SELECT COUNT(*) FROM spaces;") - spaces_before_delete ))
if [ "$users_left" != "0" ] || [ "$rows_left" != "0" ] || [ "$spaces_left" != "0" ]; then
    echo "FAIL: account delete left data behind" \
         "(users=$users_left rows=$rows_left spaces=$spaces_left; expected 0/0/0)"
    exit 1
fi
echo "delete-account assertions passed (user, personal rows and sole-member space gone)"

echo "--- done ---"
