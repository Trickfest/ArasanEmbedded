# Architecture

ArasanEmbedded keeps its Swift API and Objective-C++ transport separate from
the vendored engine. It owns configuration and UCI lifecycle, not chess rules,
game state, UI, or a typed UCI model.

## Engine lifecycle

`ArasanEngine` validates resource configuration, starts the native loop, and
queues `uci`, resource options, and `isready`. A returned `start()` call is not
a completed handshake: wait for `uciok` and `readyok` before searching.
`isRunning` reports the loop state, not search readiness.

Send one search at a time and consume its terminal bestmove before submitting
an independent search. UCI `stop` requests a search result; wrapper `stop()`
shuts down the loop and waits for teardown. A stopped ArasanEngine can be
started again. There is no state-preserving suspend/resume API analogous to
Stockfish's; consumers should not pretend these lifecycles are identical.

## Threads and process ownership

The bridge delivers UCI output in order on a serial background queue. Keep
handlers brief, dispatch UI work to the main actor, and perform blocking
teardown away from that actor. Callback-initiated stop is supported.

Arasan uses process-global state and redirected C++ streams. Only one instance
may run within one linked copy of the package. Its guard does not protect
separately linked copies: an app must not load multiple copies and run them
concurrently. The app must serialize Arasan with other embedded engines too;
native per-package guards are not a shared scheduler. Unrelated host C++ output
can be captured while streams are redirected.

The native thread has an explicit 4 MiB stack. The embedded entry point calls
the package-owned `initArasanEmbeddedGlobals()` instead of upstream
`globals::initGlobals()`. Upstream's initializer attempts a process-wide
stack-limit increase that physical Apple devices can reject even when the
explicitly sized engine thread is valid. The package initializer mirrors all
non-stack initialization without changing the host's stack resource limit;
reconcile it with upstream whenever the vendored source changes. Runtime search
Threads remains fixed at one because the vendored pool cannot safely shrink
in-process workers during teardown. Supporting dynamic worker changes requires
resolving that vendor limitation, not merely removing the wrapper's guard.

## Commands and runtime assets

`sendCommand(_:)` accepts a trusted single UCI line with one optional trailing
LF/CRLF. It rejects NULs, multiple lines, commands over 1 MiB, runtime NNUE-file
changes, and Threads changes. Validate user positions in the app before
generating commands. Rejected malformed FEN preserving the old board is a
recovery safeguard, not a replacement for app validation.

The Swift package bundles the required NNUE. Caller-provided networks must pass
the pinned size/header preflight. Books and Syzygy paths are optional and are
configured before startup. Package-owned containment around Fathom is distinct
from the materialized upstream source. See [Provenance](Provenance.md) for all
retained adjustments and notices.

## Repository layout

- `Package.swift`: SwiftPM library, CLI products, and test-target definitions.
- `.spi.yml`: Swift Package Index build and DocC configuration.
- `Sources/ArasanEmbedded`: Swift API, public soak runner, and DocC catalog.
- `Sources/CArasanEmbedded`: native bridge and embedded entry point.
- `ThirdParty/Arasan`: selected engine sources/docs, current network, Fathom.
- `Sources/ArasanSmoke`, `Sources/ArasanSoak`: existing CLI products.
- `Tests/ArasanEmbeddedTests`: configuration, integration, hash, and corpus tests.
- `Tests/CArasanEmbeddedTestSupport`: native regression probes.
- `Resources`: attributed soak data, offline book fixture, optional-asset metadata.

ArasanSoakRunner serializes events on the protocol-consumption path. A slow
event handler can delay recognition and grow its output backlog; dispatch slow
logging elsewhere. See [Testing](Testing.md) for the actual validation scope.
