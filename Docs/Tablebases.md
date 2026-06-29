# Syzygy Tablebases

Syzygy tablebases provide perfect endgame information for positions with a small
number of pieces. Arasan supports Syzygy through UCI options, and
`ArasanEmbedded` exposes those options directly.

## Why Tablebases Are Not Bundled

Tablebases are much larger than normal Swift package assets. The 5-piece set is
already close to a gigabyte, the 6-piece set is around hundreds of gigabytes,
and 7-piece tablebases are measured in terabytes. Bundling them would make the
package painful to clone, resolve, cache, and submit to the Swift Package Index.

Instead, `ArasanEmbedded` supports caller-provided tablebase directories.

## macOS Example

```swift
let tablebaseURL = URL(fileURLWithPath: "/Users/me/Chess/Syzygy345")

let configuration = ArasanEngine.Configuration(
    useTablebases: true,
    tablebaseDirectoryURL: tablebaseURL,
    tablebaseProbeDepth: 4,
    syzygyUses50MoveRule: true
)

let engine = ArasanEngine(configuration: configuration) { line in
    print(line)
}
```

## iOS/iPadOS Example

For iOS, store tablebases in a writable app-controlled location such as
Application Support. Do not assume tablebases can be bundled in the app itself;
even the small sets may be too large for practical distribution.

```swift
let supportDirectory = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)

let tablebaseURL = supportDirectory.appending(path: "Syzygy345")

let configuration = ArasanEngine.Configuration(
    useTablebases: true,
    tablebaseDirectoryURL: tablebaseURL,
    tablebaseProbeDepth: 4,
    syzygyUses50MoveRule: true
)
```

A real app can download or import tablebase files into that directory, verify
them, and then create the engine configuration.

## UCI Mapping

The Swift configuration maps to Arasan UCI options:

```text
setoption name SyzygyPath value /path/to/syzygy
setoption name SyzygyProbeDepth value 4
setoption name SyzygyUse50MoveRule value true
setoption name Use tablebases value true
```

## Failure Behavior

`ArasanEmbedded` validates the tablebase directory before engine startup when
`useTablebases` is true. If the directory is missing, startup throws
`ArasanEngine.Error.missingTablebaseDirectory`.

The wrapper validates that a directory exists. It does not validate that the
tablebase set is complete, checksum-valid, or useful for a specific position.
Arasan reports missing or incomplete tablebase content through normal UCI output.

## Optional Test Fixture

`ArasanEmbedded` includes an optional Syzygy integration test that downloads the
small `KQvK` WDL and DTZ files into `.build/test-assets/syzygy`, verifies their
published sizes and SHA-256 checksums, and confirms Arasan reports real
tablebase hits.

Run it with:

```sh
Scripts/test-external-assets.sh
```

The script is opt-in so normal `swift test` remains offline. See
`Docs/Testing.md` for cache location, environment variables, and direct XCTest
commands.

## CLI Example

```sh
swift run arasan-smoke \
  --tablebases /Users/me/Chess/Syzygy345 \
  --probe-depth 4 \
  --fen "8/8/8/8/8/8/4K3/4k3 w - - 0 1"
```
