#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_DIR="$PWD"
MANIFEST="${ARASAN_SYZYGY_MANIFEST:-$ROOT_DIR/Resources/ExternalAssets/syzygy_kqvk.tsv}"
DESTINATION="${ARASAN_SYZYGY_FIXTURE_DIR:-$ROOT_DIR/.build/test-assets/syzygy}"

[[ "$MANIFEST" = /* ]] || MANIFEST="$CALLER_DIR/$MANIFEST"
[[ "$DESTINATION" = /* ]] || DESTINATION="$CALLER_DIR/$DESTINATION"

if [[ ! -f "$MANIFEST" ]]; then
  printf 'Syzygy manifest not found: %s\n' "$MANIFEST" >&2
  exit 1
fi

mkdir -p "$DESTINATION"
entry_count=0

while IFS=$'\t' read -r file url expected_bytes expected_sha256 extra; do
  [[ -z "${file:-}" || "$file" == \#* ]] && continue
  entry_count=$((entry_count + 1))

  if [[ -n "${extra:-}" || "$file" != "$(basename "$file")" || "$file" == *..* ]]; then
    printf 'Invalid Syzygy fixture filename in manifest: %s\n' "$file" >&2
    exit 1
  fi
  if [[ "$url" != https://* ]]; then
    printf 'Syzygy fixture URL must use HTTPS: %s\n' "$url" >&2
    exit 1
  fi
  if [[ ! "$expected_bytes" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid expected byte count for %s: %s\n' "$file" "$expected_bytes" >&2
    exit 1
  fi
  if [[ ! "$expected_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf 'Invalid SHA-256 for %s: %s\n' "$file" "$expected_sha256" >&2
    exit 1
  fi

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
    temporary="$(mktemp "$DESTINATION/.${file}.XXXXXX")"
    cleanup() {
      rm -f "$temporary"
    }
    trap cleanup EXIT

    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -L --fail --retry 3 \
      --connect-timeout 20 --max-time 120 -o "$temporary" "$url"
    actual_sha256="$(shasum -a 256 "$temporary" | awk '{print $1}')"
    actual_bytes="$(wc -c < "$temporary" | tr -d ' ')"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      printf 'Checksum mismatch for %s\nexpected %s\nactual   %s\n' \
        "$file" "$expected_sha256" "$actual_sha256" >&2
      exit 1
    fi
    if [[ "$actual_bytes" != "$expected_bytes" ]]; then
      printf 'Size mismatch for %s\nexpected %s\nactual   %s\n' \
        "$file" "$expected_bytes" "$actual_bytes" >&2
      exit 1
    fi
    mv -f "$temporary" "$output"
    trap - EXIT
  else
    printf 'Using cached %s\n' "$file"
  fi
done < "$MANIFEST"

if [[ "$entry_count" == 0 ]]; then
  printf 'Syzygy manifest contained no fixture entries: %s\n' "$MANIFEST" >&2
  exit 1
fi

printf 'Syzygy fixtures ready at %s\n' "$DESTINATION"
