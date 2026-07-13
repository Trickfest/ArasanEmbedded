#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARASAN_SRC="$ROOT_DIR/ThirdParty/Arasan/src"
OUTPUT="$ROOT_DIR/Resources/OpeningBooks/book.bin"
PGN="$ROOT_DIR/Resources/OpeningBooks/fixture.pgn"
ARCHITECTURE="$(uname -m)"
TEMPORARY="$(mktemp "$ROOT_DIR/Resources/OpeningBooks/.book.bin.XXXXXX")"

cleanup() {
  rm -f "$TEMPORARY"
}
trap cleanup EXIT

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
"$ROOT_DIR/ThirdParty/Arasan/bin/makebook" -n 1 -p 1 -m 1 -o "$TEMPORARY" "$PGN" >/dev/null

if [[ ! -s "$TEMPORARY" ]]; then
  printf 'Generated opening-book fixture is empty.\n' >&2
  exit 1
fi

mv -f "$TEMPORARY" "$OUTPUT"
trap - EXIT
printf 'Generated %s\n' "$OUTPUT"
shasum -a 256 "$OUTPUT"
