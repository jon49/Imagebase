#!/usr/bin/env bash
# Run the Hurl integration tests. Self-contained: tests/tests.sh builds the
# server and spawns its own short-lived instance on a random free port, so no
# server needs to be running first.
set -euo pipefail
cd "$(dirname "$0")/../tests"
./tests.sh "$@"
