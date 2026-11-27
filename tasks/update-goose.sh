#!/usr/bin/env bash
# Update the Goose compiler checked out beside this repo (../goose), cloning it
# the first time, then rebuild the server with it and run the tests.
#   tasks/update-goose.sh            pull, build Goose, rebuild, test
#   tasks/update-goose.sh --no-test  skip the tests
# Needs git, cmake >= 3.27 and a C++20 compiler.
set -euo pipefail
cd "$(dirname "$0")/.."

GOOSE_DIR=../goose
if [ -d "$GOOSE_DIR/.git" ]; then
    git -C "$GOOSE_DIR" pull --ff-only
else
    git clone https://github.com/aardappel/goose "$GOOSE_DIR"
fi
[ -f "$GOOSE_DIR/build/CMakeCache.txt" ] ||
    cmake -S "$GOOSE_DIR" -B "$GOOSE_DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$GOOSE_DIR/build" --config Release -j"$(nproc)"

source tasks/goose-env.sh
"$GOOSE" --version

# make only watches the sources, so force the rebuild for the new compiler.
make -B build
if [ "${1:-}" != --no-test ]; then
    ./tasks/test.sh
fi
