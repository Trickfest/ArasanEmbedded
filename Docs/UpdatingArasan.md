# Updating Vendored Arasan

Use this process when refreshing `ThirdParty/Arasan` from upstream `master`.

## 1. Fetch Upstream

```sh
git clone --recurse-submodules https://github.com/jdart1/arasan-chess.git /tmp/arasan-chess
cd /tmp/arasan-chess
git rev-parse HEAD
```

Record the commit SHA and commit message.

## 2. Re-vendor Source

Copy only the package-relevant upstream material into `ThirdParty/Arasan`.
This keeps the Swift package focused on the embedded engine wrapper and avoids
vendoring GUI/font assets, upstream tests, tools, and opening-book source
material:

```sh
rm -rf ThirdParty/Arasan
mkdir -p ThirdParty/Arasan/network

rsync -a \
  --exclude='.git' \
  --exclude='.gitmodules' \
  --exclude='.gitattributes' \
  /tmp/arasan-chess/src/ ThirdParty/Arasan/src/

rsync -a /tmp/arasan-chess/doc/ ThirdParty/Arasan/doc/
cp /tmp/arasan-chess/LICENSE ThirdParty/Arasan/LICENSE
cp /tmp/arasan-chess/README.md ThirdParty/Arasan/README.md
cp /tmp/arasan-chess/network/<current-network>.nnue ThirdParty/Arasan/network/
```

Keep the Fathom Syzygy source materialized under `ThirdParty/Arasan/src/syzygy`.
Do not copy nested `.git` directories from the `src/syzygy` submodule.

## 3. Check Runtime Assets

Check the expected NNUE filename:

```sh
rg -n 'NETWORK \\?=|nnueFile|\\.nnue' ThirdParty/Arasan/src ThirdParty/Arasan/network
```

If Arasan changed the default NNUE:

- update `Package.swift`
- update `ArasanEngine.defaultNNUEURL`
- keep only the current required NNUE resource
- update `README.md` and `Docs/Provenance.md`

Opening books and Syzygy tablebases are caller-provided runtime options and are
not bundled by default.

## 4. Audit The Shim

Compare `ThirdParty/Arasan/src/arasanx.cpp` with
`Sources/CArasanEmbedded/ArasanEmbeddedUCI.cpp`. The shim should continue to
match Arasan's initialization sequence while redirecting UCI input/output to
the wrapper streams.

## 5. Validate

```sh
swift package dump-package
swift build
swift test
swift run arasan-smoke --depth 1
xcodebuild -scheme ArasanEmbedded -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -derivedDataPath .build/xcode-ios build
```
