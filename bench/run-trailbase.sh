#!/usr/bin/env bash
# Benchmark the pre-rewrite TrailBase build (the "before" side): check out
# TRAILBASE_REV (default: the last TrailBase commit) into a temporary git
# worktree, build its wasm guest, spin up `trail` on a throwaway depot, seed
# users/rows/a page over HTTP, then run bench.py against its pid.
#   bench/run-trailbase.sh [extra bench.py args, e.g. --duration 20]
# Needs `trail` on PATH and the Rust wasm32-wasip2 toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
BENCH="$PWD/bench"

REV="${TRAILBASE_REV:-e444c51}"
TREE="$(mktemp -d)"
DATA_DIR="$(mktemp -d)"
PID=""
cleanup() {
    [ -n "$PID" ] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }
    rm -rf "$DATA_DIR"
    git worktree remove --force "$TREE" 2>/dev/null || rm -rf "$TREE"
}
trap cleanup EXIT
git worktree add --quiet --detach "$TREE" "$REV"
echo "building the TrailBase guest at $REV ..." >&2
make -C "$TREE" deploy >/dev/null 2>&1

cp "$TREE/traildepot/config.textproto" "$DATA_DIR/"
cp -r "$TREE/traildepot/migrations" "$DATA_DIR/"
mkdir -p "$DATA_DIR/wasm" "$DATA_DIR/uploads"
cp "$TREE/traildepot/wasm/imagebase_guest.wasm" "$DATA_DIR/wasm/"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
URL="http://localhost:$PORT"
trail --depot="$DATA_DIR" run --address="localhost:$PORT" --runtime-root-fs="$DATA_DIR/uploads" \
    >"$DATA_DIR/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do curl -sf -m 1 "$URL/api/auth/v1/status" >/dev/null 2>&1 && break; sleep 0.1; done
sleep 1   # let startup settle before the idle-RSS reading

PW='BenchPassword!123'
TOKENS=()
for i in $(seq 1 12); do
    curl -s -o /dev/null -X POST "$URL/api/auth/v1/register" -H 'Content-Type: application/json' \
        -d "{\"email\":\"bench$i@example.com\",\"password\":\"$PW\",\"password_repeat\":\"$PW\"}"
done
sqlite3 "$DATA_DIR/data/main.db" "PRAGMA ignore_check_constraints = ON;
    UPDATE _user SET email = unverified_email, unverified_email = NULL WHERE unverified_email LIKE 'bench%';
    INSERT INTO app_owners (app, owner) SELECT 'bench', id FROM _user WHERE email = 'bench1@example.com';"
for i in $(seq 1 12); do
    TOKENS+=("$(curl -sf -X POST "$URL/api/auth/v1/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"bench$i@example.com\",\"password\":\"$PW\"}" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth_token"])')")
done
# Users 1-4 hold the read data set, 5-8 write, 9-12 have no data.
csv() { local IFS=,; echo "$*"; }
READ=$(csv "${TOKENS[@]:0:4}"); WRITE=$(csv "${TOKENS[@]:4:4}"); EMPTY=$(csv "${TOKENS[@]:8:4}")

"$BENCH/seed.py" "$URL" "$READ"

PAGE_ID=0b0b0b0b-0000-4000-8000-000000000001
curl -sf -o /dev/null -X POST "$URL/api/records/v1/pages" -H "Authorization: Bearer ${TOKENS[0]}" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$PAGE_ID\",\"app\":\"bench\",\"html\":{\"filename\":\"index.html\",\"content_type\":\"text/html\",\"data\":\"$(python3 -c 'import base64;print(base64.b64encode(b"<!doctype html><h1>bench</h1>"+b"x"*4000).decode())')\"}}"

python3 "$BENCH/bench.py" --url "$URL" --pid "$PID" --read-tokens "$READ" --write-tokens "$WRITE" --empty-tokens "$EMPTY" \
    --login "bench1@example.com:$PW" --page-id "$PAGE_ID" \
    --label "trailbase $(trail --version | head -1 | awk '{print $2}')" "$@"
