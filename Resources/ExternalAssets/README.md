# External Test Assets

This directory stores manifests for optional integration-test assets that are
not committed to the repository.

`syzygy_kqvk.tsv` describes the tiny `KQvK` Syzygy tablebase fixture used by
`Scripts/test-external-assets.sh`. The script downloads files into
`.build/test-assets/syzygy`, verifies byte counts and SHA-256 checksums, and
reuses the cached files on later runs.

The manifest accepts only HTTPS URLs, safe basenames, positive byte counts, and
64-digit SHA-256 values. Downloads use temporary files and atomically replace a
cache entry only after validation. A relative `ARASAN_SYZYGY_FIXTURE_DIR` is
resolved from the caller's current working directory before the test changes
into the repository root.

These assets are deliberately outside the default `swift test` path so the
normal release gate remains offline and fast.
