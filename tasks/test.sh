#!/usr/bin/env bash
# Run the Hurl integration tests. Expects the server to already be running
# (start it with ./tasks/start.sh in another terminal).
set -euo pipefail
cd "$(dirname "$0")/../tests"
./tests.sh "$@"
