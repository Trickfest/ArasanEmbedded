#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARASAN_SRC="$ROOT_DIR/ThirdParty/Arasan/src"
OUTPUT="$ROOT_DIR/Resources/OpeningBooks/book.bin"
PGN="$ROOT_DIR/Resources/OpeningBooks/fixture.pgn"
ARCHITECTURE="$(uname -m)"

case "$ARCHITECTURE" in
  arm64|aarch64)
    BUILD_TYPE=neon
    ;;
  *)
    BUILD_TYPE=modern
    ;;
esac

make -C "$ARASAN_SRC" clean >/dev/null
make -C "$ARASAN_SRC" dirs >/dev/null
make -C "$ARASAN_SRC" BUILD_TYPE="$BUILD_TYPE" ../bin/makebook >/dev/null
"$ROOT_DIR/ThirdParty/Arasan/bin/makebook" -n 1 -p 1 -m 1 -o "$OUTPUT" "$PGN" >/dev/null

printf 'Generated %s\n' "$OUTPUT"
shasum -a 256 "$OUTPUT"
