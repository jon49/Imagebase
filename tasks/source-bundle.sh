#!/usr/bin/env bash
# Write a self-contained C source bundle of the server, for building it on a
# machine without Goose (the arm64 Pi): the program as one standalone C file
# (runtime included), the native sources, goose.h, and a build.sh that needs
# only a C compiler and the SQLite headers (libsqlite3-dev).
#   tasks/source-bundle.sh [OUT.tar.gz]     default: dist/imagebase-src.tar.gz
# Then, on the target:  tar xzf imagebase-src.tar.gz && imagebase-src/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source tasks/goose-env.sh
GOOSE="${GOOSE:-goose}"
OUT="${1:-dist/imagebase-src.tar.gz}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
B="$STAGE/imagebase-src"
mkdir -p "$B"

(cd server && "$GOOSE" --standalone -o "$B/imagebase.c" imagebase.goose)
cp -r server/native "$B/native"
# goose.h is generated beside every native build; take it from the compiler's
# cache after an ordinary build (make build), so it matches this compiler.
(cd server && "$GOOSE" build imagebase.goose >/dev/null)
H="$(ls -t "${GOOSE_HOME:-$HOME/.goose}"/build/prog/imagebase-*/native/*/include/goose.h | head -1)"
cp "$H" "$B/native/goose.h"
"$GOOSE" --version > "$B/GOOSE_VERSION"
git rev-parse --short HEAD > "$B/IMAGEBASE_COMMIT" 2>/dev/null || true
git diff --quiet 2>/dev/null || echo "(with uncommitted changes)" >> "$B/IMAGEBASE_COMMIT"

cat > "$B/build.sh" <<'SH'
#!/usr/bin/env bash
# Builds ./imagebase from this bundle: needs cc and libsqlite3-dev.
set -euo pipefail
cd "$(dirname "$0")"
CC="${CC:-cc}"
N=native
"$CC" -O3 -o imagebase imagebase.c \
    $N/http.c $N/db.c $N/crypto.c $N/argon2_fill.c $N/argon2_fill_avx2.c \
    $N/argon2/argon2.c $N/argon2/core.c $N/argon2/encoding.c $N/argon2/blake2/blake2b.c \
    -I$N -I$N/argon2 -DARGON2_NO_THREADS -lsqlite3 -lm -pthread -ldl
echo "built $(pwd)/imagebase"
SH
chmod +x "$B/build.sh"

mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$STAGE" imagebase-src
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
