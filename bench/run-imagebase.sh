#!/usr/bin/env bash
# Benchmark the Goose server: start it on a throwaway data dir, seed the same
# users/rows/page as run-trailbase.sh over HTTP, then run bench.py on its pid.
#   bench/run-imagebase.sh [extra bench.py args, e.g. --duration 20]
set -euo pipefail
cd "$(dirname "$0")/.."

make build >/dev/null
DATA_DIR="$(mktemp -d)"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
URL="http://localhost:$PORT"
IB=(server/imagebase --data "$DATA_DIR")
"${IB[@]}" --address "localhost:$PORT" --dev >"$DATA_DIR/server.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$DATA_DIR"' EXIT
for _ in $(seq 1 100); do curl -sf -m 1 "$URL/api/auth/v1/status" >/dev/null 2>&1 && break; sleep 0.1; done
sleep 1   # let startup settle before the idle-RSS reading

PW='BenchPassword!123'
TOKENS=()
for i in 1 2 3 4; do
    curl -s -o /dev/null -X POST "$URL/api/auth/v1/register" -H 'Content-Type: application/json' \
        -d "{\"email\":\"bench$i@example.com\",\"password\":\"$PW\",\"password_repeat\":\"$PW\"}"
    "${IB[@]}" user verify "bench$i@example.com" >/dev/null
done
"${IB[@]}" owner set bench bench1@example.com >/dev/null
for i in 1 2 3 4; do
    TOKENS+=("$(curl -sf -X POST "$URL/api/auth/v1/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"bench$i@example.com\",\"password\":\"$PW\"}" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth_token"])')")
done
TOKEN_CSV=$(IFS=,; echo "${TOKENS[*]}")

bench/seed.py "$URL" "$TOKEN_CSV"

PAGE_ID=0b0b0b0b-0000-4000-8000-000000000001
curl -sf -o /dev/null -X POST "$URL/api/records/v1/pages" -H "Authorization: Bearer ${TOKENS[0]}" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$PAGE_ID\",\"app\":\"bench\",\"html\":{\"filename\":\"index.html\",\"content_type\":\"text/html\",\"data\":\"$(python3 -c 'import base64;print(base64.b64encode(b"<!doctype html><h1>bench</h1>"+b"x"*4000).decode())')\"}}"

python3 bench/bench.py --url "$URL" --pid "$PID" --tokens "$TOKEN_CSV" \
    --login "bench1@example.com:$PW" --page-app bench --page-id "$PAGE_ID" \
    --label "imagebase (goose $(goose --version | awk '{print $2}'))" "$@"
