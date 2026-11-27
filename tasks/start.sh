#!/usr/bin/env bash
# Build and run the server in dev mode, with ../goose when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
source tasks/goose-env.sh
make dev
