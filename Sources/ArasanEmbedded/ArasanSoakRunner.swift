import Foundation

/// Runs repeated UCI searches against a single embedded Arasan engine.
///
/// `ArasanSoakRunner` is intended for release validation, CI smoke soaking, and
/// lightweight integration tests. It keeps the same boundary as `ArasanEngine`:
/// the runner sends caller-provided UCI positions and search limits, then
/// verifies that Arasan continues to answer with `bestmove` lines. It does not
/// decide whether a move is legal or strategically correct.
public final class ArasanSoakRunner: @unchecked Sendable {
    private let configuration: Configuration

    /// Creates a soak runner.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Runs the configured soak loop and returns a summary.
    ///
    /// The runner starts one engine, waits for `uciok` and `readyok`, then
    /// cycles through the configured positions until `maxIterations` is reached
    /// or a stop-on-timeout failure occurs.
    public func run(
        eventHandler: @escaping @Sendable (Event) -> Void = { _ in }
    ) async -> Summary {
        let startedAt = Date()
        var summary = Summary(
            iterationsAttempted: 0,
            iterationsCompleted: 0,
            timeouts: 0,
            errors: 0,
            elapsed: 0
        )

        func finish() -> Summary {
            summary.elapsed = Date().timeIntervalSince(startedAt)
            eventHandler(.finished)
            return summary
        }

        guard !configuration.positions.isEmpty else {
            summary.errors += 1
            eventHandler(.error("No positions were configured."))
            return finish()
        }

        let stream = LockedArasanLineStream()
        let engine = ArasanEngine(configuration: configuration.engineConfiguration) { line in
            stream.append(line)
            eventHandler(.engineOutput(line))
        }

        eventHandler(.started(configuration))

        do {
            try engine.start()
        } catch {
            summary.errors += 1
            eventHandler(.error("Failed to start Arasan: \(error.localizedDescription)"))
            return finish()
        }

        defer {
            engine.stop()
            eventHandler(.stopped)
        }

        guard stream.waitForLine(
            prefix: "uciok",
            startingAt: 0,
            timeout: configuration.handshakeTimeout
        ) != nil else {
            summary.errors += 1
            eventHandler(.error("Timed out waiting for uciok."))
            return finish()
        }

        let readyStart = stream.lineCount
        for option in configuration.engineOptions {
            engine.sendCommand(option)
        }
        engine.sendCommand("isready")

        guard stream.waitForLine(
            prefix: "readyok",
            startingAt: readyStart,
            timeout: configuration.handshakeTimeout
        ) != nil else {
            summary.errors += 1
            eventHandler(.error("Timed out waiting for readyok."))
            return finish()
        }

        var positionIndex = 0
        while shouldContinue(summary: summary) {
            let iteration = summary.iterationsAttempted
            let position = configuration.positions[positionIndex % configuration.positions.count]
            positionIndex += 1

            eventHandler(.iterationStarted(index: iteration, position: position))

            if configuration.readyCheckEveryIteration {
                let readyEachStart = stream.lineCount
                engine.sendCommand("isready")
                guard stream.waitForLine(
                    prefix: "readyok",
                    startingAt: readyEachStart,
                    timeout: configuration.handshakeTimeout
                ) != nil else {
                    summary.errors += 1
                    eventHandler(.error("Timed out waiting for readyok before iteration \(iteration + 1)."))
                    break
                }
            }

            let searchStartedAt = Date()
            let searchStart = stream.lineCount
            summary.iterationsAttempted += 1

            engine.sendCommand(position.positionCommand)
            engine.sendCommand(configuration.searchLimit.command)

            if let bestmoveLine = stream.waitForLine(
                prefix: "bestmove",
                startingAt: searchStart,
                timeout: configuration.perMoveTimeout
            ) {
                summary.iterationsCompleted += 1
                eventHandler(.iterationCompleted(
                    index: iteration,
                    position: position,
                    bestmove: Self.bestmoveToken(from: bestmoveLine) ?? bestmoveLine,
                    elapsed: Date().timeIntervalSince(searchStartedAt)
                ))
            } else {
                summary.timeouts += 1
                eventHandler(.timeout(
                    index: iteration,
                    position: position,
                    elapsed: Date().timeIntervalSince(searchStartedAt)
                ))

                let stopStart = stream.lineCount
                engine.sendCommand("stop")
                _ = stream.waitForLine(
                    prefix: "bestmove",
                    startingAt: stopStart,
                    timeout: configuration.stopTimeout
                )

                if configuration.stopOnTimeoutFailure {
                    break
                }
            }

            if let delay = configuration.delayBetweenIterations, delay > 0 {
                await Self.sleep(seconds: delay)
            }
        }

        return finish()
    }

    private func shouldContinue(summary: Summary) -> Bool {
        guard let maxIterations = configuration.maxIterations else {
            return true
        }
        return summary.iterationsAttempted < maxIterations
    }

    private static func bestmoveToken(from line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "bestmove" else {
            return nil
        }
        return String(parts[1])
    }

    private static func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

public extension ArasanSoakRunner {
    /// A UCI position to search during a soak run.
    struct PositionSpec: Equatable, Sendable {
        /// Optional stable identifier used in logs and test failures.
        public var id: String
        /// Either `startpos` or a full FEN string.
        public var fen: String

        public init(id: String = "", fen: String) {
            self.id = id
            self.fen = fen
        }

        var positionCommand: String {
            if fen == "startpos" {
                return "position startpos"
            }
            return "position fen \(fen)"
        }
    }

    /// The UCI search limit sent for each position.
    enum SearchLimit: Equatable, Sendable {
        case depth(Int)
        case nodes(Int)
        case moveTimeMillis(Int)

        var command: String {
            switch self {
            case .depth(let depth):
                "go depth \(depth)"
            case .nodes(let nodes):
                "go nodes \(nodes)"
            case .moveTimeMillis(let milliseconds):
                "go movetime \(milliseconds)"
            }
        }
    }

    /// Configuration for a soak run.
    struct Configuration: Sendable {
        /// Positions to search. The runner cycles through this list.
        public var positions: [PositionSpec]
        /// Engine resource configuration.
        public var engineConfiguration: ArasanEngine.Configuration
        /// Search limit used for every iteration.
        public var searchLimit: SearchLimit
        /// Optional maximum number of iterations. `nil` means run until stopped.
        public var maxIterations: Int?
        /// Seconds to wait for each `bestmove`.
        public var perMoveTimeout: TimeInterval
        /// Seconds to wait for `bestmove` after sending `stop`.
        public var stopTimeout: TimeInterval
        /// Seconds to wait for `uciok` and `readyok`.
        public var handshakeTimeout: TimeInterval
        /// Optional delay between iterations.
        public var delayBetweenIterations: TimeInterval?
        /// Sends `isready` before every search when enabled.
        public var readyCheckEveryIteration: Bool
        /// Stops the soak run after the first timeout when enabled.
        public var stopOnTimeoutFailure: Bool
        /// Extra UCI options sent after `uciok` and before the runner's
        /// readiness probe.
        public var engineOptions: [String]

        public init(
            positions: [PositionSpec],
            engineConfiguration: ArasanEngine.Configuration = .default,
            searchLimit: SearchLimit = .depth(8),
            maxIterations: Int? = nil,
            perMoveTimeout: TimeInterval = 30,
            stopTimeout: TimeInterval = 5,
            handshakeTimeout: TimeInterval = 10,
            delayBetweenIterations: TimeInterval? = nil,
            readyCheckEveryIteration: Bool = false,
            stopOnTimeoutFailure: Bool = true,
            engineOptions: [String] = []
        ) {
            self.positions = positions
            self.engineConfiguration = engineConfiguration
            self.searchLimit = searchLimit
            self.maxIterations = maxIterations
            self.perMoveTimeout = perMoveTimeout
            self.stopTimeout = stopTimeout
            self.handshakeTimeout = handshakeTimeout
            self.delayBetweenIterations = delayBetweenIterations
            self.readyCheckEveryIteration = readyCheckEveryIteration
            self.stopOnTimeoutFailure = stopOnTimeoutFailure
            self.engineOptions = engineOptions
        }
    }

    /// Final counters for a soak run.
    struct Summary: Equatable, Sendable {
        public var iterationsAttempted: Int
        public var iterationsCompleted: Int
        public var timeouts: Int
        public var errors: Int
        public var elapsed: TimeInterval
    }

    /// Structured progress event emitted during a soak run.
    enum Event: Sendable {
        case started(Configuration)
        case engineOutput(String)
        case iterationStarted(index: Int, position: PositionSpec)
        case iterationCompleted(index: Int, position: PositionSpec, bestmove: String, elapsed: TimeInterval)
        case timeout(index: Int, position: PositionSpec, elapsed: TimeInterval)
        case error(String)
        case stopped
        case finished
    }
}

private final class LockedArasanLineStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [String] = []

    var lineCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return lines.count
    }

    func append(_ line: String) {
        condition.lock()
        defer { condition.unlock() }
        lines.append(line)
        condition.broadcast()
    }

    func waitForLine(prefix: String, startingAt startIndex: Int, timeout: TimeInterval) -> String? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let line = lines.dropFirst(startIndex).first(where: { $0.hasPrefix(prefix) }) {
                return line
            }
            if Date() >= deadline {
                return nil
            }
            condition.wait(until: deadline)
        }
    }
}
