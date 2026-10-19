# Troubleshooting

## Configuration or startup fails

Observe errors thrown by `start()` and diagnostic output. The default network
comes from the package bundle; it does not need an app-level manual copy.
For custom files, check the path, required network format/size, and that the
file stays stable through startup. Caller-provided paths must fit one safe UCI
line. Books and tablebases need explicit valid paths when enabled.

See [Opening books](OpeningBooks.md) and [Tablebases](Tablebases.md) for their
resource-specific failure behavior. Do not enable either merely to make a basic
search work; both are disabled by default.

## Startup returned but no move arrives

`start()` sends UCI setup commands but does not wait for readiness. Observe both
`uciok` and `readyok` before sending position/go. `isRunning` alone is not enough.
Keep the session owner alive and keep callbacks brief. The README's async sample
must be awaited in a command-line program so the process does not exit early;
observe its throwing task's result to report startup errors. Add client deadlines
in production rather than waiting indefinitely.

## Another engine is already active

Serialize Arasan instances and all other in-process engine sessions. Wait for
the previous wrapper's teardown or supported suspension before starting the
next. A stopped ArasanEngine can restart; it does not expose Stockfish's
state-preserving suspend/resume API. See [Architecture](Architecture.md).

## The UI freezes during shutdown or playback looks slow

Wrapper `stop()` blocks until teardown. Schedule it away from the main actor.
UCI `stop` is a different operation: it requests the current search's terminal
bestmove. Search time, engine startup, app pacing, and animation are separate
costs. A client timeout should not allow a late result to be attributed to the
next position. SwiftChessDemo demonstrates serialized session ownership.

## A build or test is unsupported or skipped

Use Apple arm64, not Intel/x86_64. The optional Syzygy integration test is
skipped unless explicitly enabled; the offline opening-book fixture is part of
normal package tests. A simulator build does not establish physical-device
startup safety. Do not remove the package-owned initializer or its explicit
stack size to imitate upstream's standalone entry point.

See [Testing](Testing.md) for build-only versus runtime checks and the separate
physical-device smoke requirements. Future test additions are not part of the
current gate until implemented.
