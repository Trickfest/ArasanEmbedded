#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ARASAN_SYZYGY_MANIFEST:-$ROOT_DIR/Resources/ExternalAssets/syzygy_kqvk.tsv}"
DESTINATION="${ARASAN_SYZYGY_FIXTURE_DIR:-$ROOT_DIR/.build/test-assets/syzygy}"

mkdir -p "$DESTINATION"

while IFS=$'\t' read -r file url expected_bytes expected_sha256; do
  [[ -z "${file:-}" || "$file" == \#* ]] && continue

  output="$DESTINATION/$file"
  needs_download=1
  if [[ -f "$output" ]]; then
    actual_sha256="$(shasum -a 256 "$output" | awk '{print $1}')"
    actual_bytes="$(wc -c < "$output" | tr -d ' ')"
    if [[ "$actual_sha256" == "$expected_sha256" && "$actual_bytes" == "$expected_bytes" ]]; then
      needs_download=0
    fi
  fi

  if [[ "$needs_download" == 1 ]]; then
    printf 'Downloading %s\n' "$file"
    curl -L --fail --retry 3 --connect-timeout 20 --max-time 120 -o "$output.tmp" "$url"
    actual_sha256="$(shasum -a 256 "$output.tmp" | awk '{print $1}')"
    actual_bytes="$(wc -c < "$output.tmp" | tr -d ' ')"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      printf 'Checksum mismatch for %s\nexpected %s\nactual   %s\n' "$file" "$expected_sha256" "$actual_sha256" >&2
      rm -f "$output.tmp"
      exit 1
    fi
    if [[ "$actual_bytes" != "$expected_bytes" ]]; then
      printf 'Size mismatch for %s\nexpected %s\nactual   %s\n' "$file" "$expected_bytes" "$actual_bytes" >&2
      rm -f "$output.tmp"
      exit 1
    fi
    mv "$output.tmp" "$output"
  else
    printf 'Using cached %s\n' "$file"
  fi
done < "$MANIFEST"

printf 'Syzygy fixtures ready at %s\n' "$DESTINATION"
