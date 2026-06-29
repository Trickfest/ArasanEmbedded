# External Test Assets

This directory stores manifests for optional integration-test assets that are
not committed to the repository.

`syzygy_kqvk.tsv` describes the tiny `KQvK` Syzygy tablebase fixture used by
`Scripts/test-external-assets.sh`. The script downloads files into
`.build/test-assets/syzygy`, verifies byte counts and SHA-256 checksums, and
reuses the cached files on later runs.

These assets are deliberately outside the default `swift test` path so the
normal release gate remains offline and fast.
