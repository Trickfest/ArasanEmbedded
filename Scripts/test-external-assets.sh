#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYZYGY_DIR="${ARASAN_SYZYGY_FIXTURE_DIR:-$ROOT_DIR/.build/test-assets/syzygy}"

"$ROOT_DIR/Scripts/prepare-syzygy-fixtures.sh"

cd "$ROOT_DIR"

ARASAN_RUN_EXTERNAL_ASSET_TESTS=1 \
ARASAN_SYZYGY_PATH="$SYZYGY_DIR" \
swift test --filter ArasanExternalAssetIntegrationTests
