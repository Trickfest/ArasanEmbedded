#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR_NAME="${ARASAN_IOS_SIMULATOR_NAME:-iPhone 17 Pro}"
API_BASELINE="${ARASAN_API_BASELINE_TAG:-v1.0.6}"
NNUE_PATH="ThirdParty/Arasan/network/arasanv8-20260622.nnue"
NNUE_BYTES=25024576
NNUE_SHA256="b42f9e13a37debb4af425d2ca74b5edff1d8034a616806bccdb67b79530201ac"

cd "$ROOT_DIR"

actual_nnue_bytes="$(wc -c < "$NNUE_PATH" | tr -d ' ')"
actual_nnue_sha256="$(shasum -a 256 "$NNUE_PATH" | awk '{print $1}')"
actual_nnue_header="$(xxd -p -l 4 "$NNUE_PATH")"
if [[ "$actual_nnue_bytes" != "$NNUE_BYTES" ||
      "$actual_nnue_sha256" != "$NNUE_SHA256" ||
      "$actual_nnue_header" != "41524108" ]]; then
  printf 'Bundled NNUE does not match its pinned size, hash, and format header: %s\n' "$NNUE_PATH" >&2
  exit 1
fi

swift package dump-package >/dev/null
swift build
swift build -c release --product arasan-smoke

release_bin="$(swift build -c release --show-bin-path)/arasan-smoke"
if nm -u "$release_bin" | grep '___assert_rtn' >/dev/null; then
  printf 'Release engine binary still references native assertions: %s\n' "$release_bin" >&2
  exit 1
fi

swift test
swift test --sanitize=thread
swift run arasan-smoke --depth 1
debug_smoke_bin="$(swift build --show-bin-path)/arasan-smoke"
(
  ulimit -S -s 2048
  ulimit -H -s 2048
  "$debug_smoke_bin" --depth 1
)
swift run arasan-soak --iterations 5 --movetime 500

if swift run arasan-smoke --depth 0 >/dev/null 2>&1; then
  printf 'arasan-smoke unexpectedly accepted an invalid depth.\n' >&2
  exit 1
fi
if swift run arasan-soak --iterations 0 >/dev/null 2>&1; then
  printf 'arasan-soak unexpectedly accepted zero iterations.\n' >&2
  exit 1
fi
if swift run arasan-soak --iterations 1 --timeout 1e300 >/dev/null 2>&1; then
  printf 'arasan-soak unexpectedly accepted an unrepresentable timeout.\n' >&2
  exit 1
fi

xcodebuild \
  -scheme ArasanEmbedded \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME,OS=latest" \
  -derivedDataPath .build/xcode-ios-simulator \
  build

xcodebuild \
  -scheme ArasanEmbedded \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/xcode-ios-device \
  build

swift package diagnose-api-breaking-changes "$API_BASELINE" \
  --products ArasanEmbedded \
  --baseline-dir .build/api-baseline \
  --regenerate-baseline

for license in LICENSE ThirdParty/Arasan/LICENSE ThirdParty/Arasan/src/syzygy/LICENSE; do
  if [[ ! -f "$license" ]]; then
    printf 'Current worktree is missing required license: %s\n' "$license" >&2
    exit 1
  fi
done

if [[ -z "$(git status --porcelain)" ]]; then
  source_archive="$ROOT_DIR/.build/ArasanEmbedded-source.zip"
  rm -f "$source_archive"
  swift package archive-source --output "$source_archive"
  archive_root="$(basename "$source_archive" .zip)"
  for license in LICENSE ThirdParty/Arasan/LICENSE ThirdParty/Arasan/src/syzygy/LICENSE; do
    if ! unzip -Z1 "$source_archive" | grep -Fx "$archive_root/$license" >/dev/null; then
      printf 'Source archive is missing required license: %s\n' "$license" >&2
      exit 1
    fi
  done
else
  printf 'Skipping committed-source archive check for a dirty worktree; current license files are present.\n'
fi

printf 'ArasanEmbedded validation succeeded.\n'
