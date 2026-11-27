#!/usr/bin/env bash
# Run the Hurl integration tests. Self-contained: tests/tests.sh builds the
# server and spawns its own short-lived instance on a random free port, so no
# server needs to be running first. Builds with ../goose when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
source tasks/goose-env.sh
cd tests
./tests.sh "$@"
