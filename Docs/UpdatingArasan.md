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
The core `src` tree intentionally retains `src/util`; `makebook` is used for the
package's opening-book fixture even though the utility programs are not package
products. Avoid vendoring GUI/font assets, external test corpora, and
opening-book source material:

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
Record the exact `jdart1/Fathom` commit in `Docs/Provenance.md` rather than only
recording the parent Arasan commit.

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
- update the expected byte count and format header in
  `Sources/ArasanEmbedded/ArasanEngine.swift`
- update the native startup preflight constants in
  `Sources/CArasanEmbedded/AEEngine.mm`
- update the pinned filename, byte count, and SHA-256 in
  `Scripts/validate.sh`

Always record the network byte count and SHA-256 in `Docs/Provenance.md` and
confirm the resource in a clean package build. The format preflight deliberately
tracks the current vendored snapshot; it is not a generic NNUE parser.

Opening books and Syzygy tablebases are caller-provided runtime options and are
not bundled by default.

## 4. Audit The Shim

Compare `ThirdParty/Arasan/src/arasanx.cpp` with
`Sources/CArasanEmbedded/ArasanEmbeddedUCI.cpp`. The shim should continue to
match Arasan's initialization sequence while redirecting UCI input/output to
the wrapper streams.

The embedded entry path intentionally calls the package-owned
`initArasanEmbeddedGlobals()` instead of upstream `globals::initGlobals()`.
Upstream's function mutates the process-wide stack resource limit and can call
`exit(-1)` when a physical Apple device rejects that change; `AEEngine` instead
creates the UCI loop on an explicit 4 MiB pthread. On every upstream refresh,
compare `globals::initGlobals()` with `initArasanEmbeddedGlobals()` and carry
forward all non-stack initialization changes. Compare `globals::cleanupGlobals()`
as well so allocation and teardown remain symmetric, and confirm Arasan's
required thread-stack size has not changed. Do not copy the process-wide
stack-limit block into the embedded initializer, and keep the source comment
that records this replacement.

## 5. Reconcile Local Vendored Adjustments

Check `Docs/Provenance.md` for local vendored-source adjustments. Preserve the
`ARASAN_EMBEDDED_STREAM_INPUT` polling path in
`ThirdParty/Arasan/src/input.cpp`; the embedded wrapper depends on it to feed
UCI commands through redirected C++ streams.

Also verify whether upstream still carries fixes previously patched locally.
For example, the arm64 NEON `dpbusd_epi32` accumulator fix was accepted
upstream in Arasan commit `58c58cf9`, so it should not be carried as a duplicate
local patch.

Likewise, the mate-distance-pruning fix for Arasan issue #70 was accepted
upstream in Arasan commit `b2cbcae8`, so the older local `hash.h` clamp
workaround should not be reintroduced.

## 6. Validate

Confirm that the explicit native source list in `Package.swift` still matches
the upstream engine entry path. Keep Release-only `NDEBUG` and the current
compile-time SIMD backend in view. The package presently supports Apple arm64
targets only; adding x86_64 requires an explicit, tested per-architecture
backend design rather than global unsafe flags or a casual vendor edit.

Run the full local release gate:

```sh
Scripts/validate.sh
```

When preparing a new release, update the script's default `API_BASELINE` to the
most recent released tag that existing consumers may be using. The
`ARASAN_API_BASELINE_TAG` environment variable can override it for an ad hoc
comparison.

Then run `Scripts/test-external-assets.sh` when tablebase integration changed.
