import Foundation

/// Runs repeated UCI searches against a single embedded Arasan engine.
///
/// The runner validates its configuration before starting native state,
/// serializes UCI output and structured events, and requires every timed-out
/// search to reach its terminal `bestmove` before another position may start.
public final class ArasanSoakRunner: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        struct StopTargets {
            let engine: ArasanEngine?
            let lineQueue: LineQueue?
        }

        private let queue = DispatchQueue(label: "ArasanSoakRunner.State")
        private var running = false
        private var engine: ArasanEngine?
        private var lineQueue: LineQueue?
        private var stopRequested = false

        func beginRun() -> Bool {
            queue.sync {
                guard !running else { return false }
                running = true
                stopRequested = false
                return true
            }
        }

        func install(engine: ArasanEngine, lineQueue: LineQueue) {
            queue.sync {
                self.engine = engine
                self.lineQueue = lineQueue
            }
        }

        func requestStop() -> StopTargets {
            queue.sync {
                stopRequested = true
                return StopTargets(engine: engine, lineQueue: lineQueue)
            }
        }

        func endRun() {
            queue.sync {
                engine = nil
                lineQueue = nil
                running = false
            }
        }

        func shouldStop() -> Bool {
            queue.sync { stopRequested }
        }
    }

    private let configuration: Configuration
    private let state = State()

    /// Creates a soak runner.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Requests cooperative shutdown. Safe to call from any thread.
    ///
    /// This wakes an in-progress wait and blocks while the native engine joins.
    public func stop() {
        let targets = state.requestStop()
        targets.lineQueue?.finish()
        targets.engine?.stop()
    }

    /// Runs the configured soak loop and returns a summary.
    ///
    /// Only one `run` call may be active on a runner. A `nil` iteration limit
    /// runs until `stop()` is called or the surrounding task is cancelled.
    /// Events are delivered serially in protocol order; `.finished` is always
    /// terminal, and a successfully started engine emits `.stopped` first.
    /// The handler participates in protocol consumption and must return
    /// promptly; long blocking work can delay response recognition.
    public func run(
        eventHandler: @escaping @Sendable (Event) -> Void = { _ in }
    ) async -> Summary {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var summary = Summary(
            iterationsAttempted: 0,
            iterationsCompleted: 0,
            timeouts: 0,
            errors: 0,
            elapsed: 0
        )

        func finalizeSummary() -> Summary {
            summary.elapsed = timeInterval(clock.now - startedAt)
            return summary
        }

        guard state.beginRun() else {
            summary.errors = 1
            eventHandler(.error("This soak runner is already running."))
            eventHandler(.finished)
            return finalizeSummary()
        }
        defer {
            eventHandler(.finished)
            state.endRun()
        }

        if let validationError = configuration.validationError {
            summary.errors = 1
            eventHandler(.error(validationError))
            return finalizeSummary()
        }

        let lineQueue = LineQueue()
        let engine = ArasanEngine(configuration: configuration.engineConfiguration) { line in
            lineQueue.push(line)
        }
        state.install(engine: engine, lineQueue: lineQueue)

        if state.shouldStop() || Task.isCancelled {
            lineQueue.finish()
            return finalizeSummary()
        }

        do {
            try engine.start()
        } catch {
            summary.errors = 1
            eventHandler(.error("Failed to start Arasan: \(error.localizedDescription)"))
            lineQueue.finish()
            return finalizeSummary()
        }

        eventHandler(.started(configuration))
        defer {
            engine.stop()
            lineQueue.finish()
            eventHandler(.stopped)
        }

        let state = self.state
        let shouldStop: @Sendable () -> Bool = {
            Task.isCancelled || state.shouldStop()
        }

        @Sendable func nextLine() async -> String? {
            guard !shouldStop(), let line = await lineQueue.next() else {
                return nil
            }
            eventHandler(.engineOutput(line))
            return line
        }

        func waitForLine(
            timeout: TimeInterval,
            matching predicate: @escaping @Sendable (String) -> Bool
        ) async -> String? {
            await withTimeout(.seconds(timeout)) {
                while let line = await nextLine() {
                    if predicate(line) {
                        return line
                    }
                }
                return nil
            }
        }

        func waitForExact(_ expected: String, timeout: TimeInterval) async -> String? {
            await waitForLine(timeout: timeout) { $0 == expected }
        }

        func waitForBestmove(timeout: TimeInterval) async -> String? {
            await waitForLine(timeout: timeout) {
                $0 == "bestmove" || $0.hasPrefix("bestmove ")
            }
        }

        // ArasanEngine.start() atomically queued uci, resource options, and the
        // initial isready. Consume both responses before applying runner-only
        // options so the later readiness probe cannot match the wrong readyok.
        guard await waitForExact("uciok", timeout: configuration.handshakeTimeout) != nil else {
            if !shouldStop() {
                summary.errors += 1
                eventHandler(.error("Timed out waiting for uciok."))
            }
            return finalizeSummary()
        }
        guard await waitForExact("readyok", timeout: configuration.handshakeTimeout) != nil else {
            if !shouldStop() {
                summary.errors += 1
                eventHandler(.error("Timed out waiting for startup readyok."))
            }
            return finalizeSummary()
        }

        for option in configuration.engineOptions {
            engine.sendCommand(option)
        }
        engine.sendCommand("isready")
        guard await waitForExact("readyok", timeout: configuration.handshakeTimeout) != nil else {
            if !shouldStop() {
                summary.errors += 1
                eventHandler(.error("Timed out waiting for post-option readyok."))
            }
            return finalizeSummary()
        }

        var index = 0
        while !shouldStop() {
            if let maximum = configuration.maxIterations, index >= maximum {
                break
            }

            let position = configuration.positions[index % configuration.positions.count]
            eventHandler(.iterationStarted(index: index, position: position))
            if shouldStop() { break }

            if configuration.readyCheckEveryIteration {
                engine.sendCommand("isready")
                guard await waitForExact("readyok", timeout: configuration.handshakeTimeout) != nil else {
                    if !shouldStop() {
                        summary.errors += 1
                        eventHandler(.error("Timed out waiting for readyok before iteration \(index + 1)."))
                    }
                    break
                }
            }

            let searchStartedAt = clock.now
            summary.iterationsAttempted += 1
            engine.sendCommand(position.positionCommand)
            engine.sendCommand(configuration.searchLimit.command)

            if let line = await waitForBestmove(timeout: configuration.perMoveTimeout) {
                guard let bestmove = parseArasanBestmove(line) else {
                    summary.errors += 1
                    eventHandler(.error("Received malformed bestmove: \(line)"))
                    break
                }
                summary.iterationsCompleted += 1
                eventHandler(.iterationCompleted(
                    index: index,
                    position: position,
                    bestmove: bestmove,
                    elapsed: timeInterval(clock.now - searchStartedAt)
                ))
            } else if shouldStop() {
                break
            } else {
                summary.timeouts += 1
                eventHandler(.timeout(
                    index: index,
                    position: position,
                    elapsed: timeInterval(clock.now - searchStartedAt)
                ))

                engine.sendCommand("stop")
                guard let terminalLine = await waitForBestmove(timeout: configuration.stopTimeout) else {
                    if !shouldStop() {
                        summary.errors += 1
                        eventHandler(.error("Timed out waiting for terminal bestmove after stop."))
                    }
                    break
                }
                guard parseArasanBestmove(terminalLine) != nil else {
                    summary.errors += 1
                    eventHandler(.error("Received malformed bestmove after stop: \(terminalLine)"))
                    break
                }

                // The legacy property remains source-compatible. A recovered
                // timeout may continue only after its terminal barrier; an
                // unrecovered timeout always stops above.
                if configuration.stopOnTimeoutFailure {
                    break
                }
            }

            index += 1
            if let delay = configuration.delayBetweenIterations {
                let deadline = clock.now.advanced(by: .seconds(delay))
                while !shouldStop() {
                    let remaining = clock.now.duration(to: deadline)
                    if remaining <= .zero { break }
                    try? await Task.sleep(for: min(remaining, .milliseconds(50)))
                }
            }
        }

        return finalizeSummary()
    }
}

public extension ArasanSoakRunner {
    /// A UCI position to search during a soak run.
    struct PositionSpec: Equatable, Sendable {
        /// Optional stable identifier used in logs and test failures.
        public var id: String
        /// Either the literal `startpos` or a full four/six-field FEN.
        public var fen: String

        public init(id: String = "", fen: String) {
            self.id = id
            self.fen = fen
        }

        var positionCommand: String {
            fen == "startpos" ? "position startpos" : "position fen \(fen)"
        }
    }

    /// The single UCI search limit used for each iteration.
    enum SearchLimit: Equatable, Sendable {
        /// Search to a positive depth.
        case depth(Int)
        /// Search a positive node count.
        case nodes(Int)
        /// Search for a positive number of milliseconds.
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
        /// Positive iteration cap. `nil` runs until stopped or cancelled.
        public var maxIterations: Int?
        /// Positive seconds to wait for each `bestmove`, capped at one year.
        public var perMoveTimeout: TimeInterval
        /// Positive seconds to wait after sending `stop`, capped at one year.
        public var stopTimeout: TimeInterval
        /// Positive seconds to wait for handshake responses, capped at one year.
        public var handshakeTimeout: TimeInterval
        /// Optional nonnegative delay between iterations, capped at one year.
        public var delayBetweenIterations: TimeInterval?
        /// Sends `isready` before every search when enabled.
        public var readyCheckEveryIteration: Bool
        /// Stops after a recovered timeout when true. When false, continuation
        /// is allowed only after that search's terminal `bestmove` is consumed.
        public var stopOnTimeoutFailure: Bool
        /// Extra trusted, single-line UCI options sent after startup readiness.
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

        var validationError: String? {
            guard !positions.isEmpty else { return "No positions were configured." }
            guard positions.allSatisfy({ isValidArasanPosition($0.fen) }) else {
                return "Every position must be startpos or a plausible single-line four/six-field FEN."
            }
            switch searchLimit {
            case .depth(let value) where value <= 0:
                return "Search depth must be greater than zero."
            case .nodes(let value) where value <= 0:
                return "Node limit must be greater than zero."
            case .moveTimeMillis(let value) where value <= 0:
                return "Move time must be greater than zero."
            default:
                break
            }
            if let maxIterations, maxIterations <= 0 {
                return "Maximum iterations must be greater than zero."
            }
            guard isRepresentableArasanSoakDuration(perMoveTimeout, allowsZero: false) else {
                return "Per-move timeout must be greater than zero and at most one year."
            }
            guard isRepresentableArasanSoakDuration(stopTimeout, allowsZero: false) else {
                return "Stop timeout must be greater than zero and at most one year."
            }
            guard isRepresentableArasanSoakDuration(handshakeTimeout, allowsZero: false) else {
                return "Handshake timeout must be greater than zero and at most one year."
            }
            if let delayBetweenIterations,
               !isRepresentableArasanSoakDuration(delayBetweenIterations, allowsZero: true) {
                return "Delay between iterations must be nonnegative and at most one year."
            }
            guard engineOptions.allSatisfy(isValidSingleLineUCICommand) else {
                return "Every engine option must be a nonempty single-line UTF-8 command of at most 1 MiB."
            }
            guard !engineOptions.contains(where: isRuntimeNNUEFileOption) else {
                return "Configure NNUE files through ArasanEngine.Configuration, not runner engineOptions."
            }
            guard !engineOptions.contains(where: isRuntimeThreadsOption) else {
                return "The embedded wrapper fixes Arasan Threads at 1 for safe teardown."
            }
            return nil
        }
    }

    /// Final counters for a run.
    struct Summary: Equatable, Sendable {
        /// Searches issued to Arasan.
        public var iterationsAttempted: Int
        /// Searches that completed before their normal deadline.
        public var iterationsCompleted: Int
        /// Searches that reached the per-move timeout.
        public var timeouts: Int
        /// Configuration, startup, protocol, or recovery failures.
        public var errors: Int
        /// Monotonic elapsed seconds through search-loop completion. Native
        /// teardown occurs immediately afterward and is not included.
        public var elapsed: TimeInterval
    }

    /// Structured progress emitted serially during a run.
    enum Event: Sendable {
        /// Native startup succeeded.
        case started(Configuration)
        /// One raw UCI output line.
        case engineOutput(String)
        /// A position is about to be searched.
        case iterationStarted(index: Int, position: PositionSpec)
        /// A search completed before its normal deadline.
        case iterationCompleted(index: Int, position: PositionSpec, bestmove: String, elapsed: TimeInterval)
        /// A search exceeded its normal deadline.
        case timeout(index: Int, position: PositionSpec, elapsed: TimeInterval)
        /// A validation, startup, protocol, or recovery error.
        case error(String)
        /// A started native engine has completed teardown.
        case stopped
        /// Terminal event for every run.
        case finished
    }
}

/// Returns whether a value is the supported `startpos` literal or a plausible
/// four/six-field FEN. This deliberately checks protocol shape, not chess legality.
private let maximumArasanSoakDuration: TimeInterval = 365 * 24 * 60 * 60

private func isRepresentableArasanSoakDuration(
    _ interval: TimeInterval,
    allowsZero: Bool
) -> Bool {
    guard interval.isFinite,
          (allowsZero ? interval >= 0 : interval > 0),
          interval <= maximumArasanSoakDuration else {
        return false
    }
    return allowsZero || Duration.seconds(interval) > .zero
}

func isValidArasanPosition(_ value: String) -> Bool {
    guard !value.contains("\0"), !value.contains("\r"), !value.contains("\n") else {
        return false
    }
    if value == "startpos" { return true }

    let fields = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard fields.count == 4 || fields.count == 6 else { return false }

    let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
    guard ranks.count == 8 else { return false }
    for rank in ranks {
        var squareCount = 0
        for character in rank {
            if let ascii = character.asciiValue, (49...56).contains(ascii) {
                squareCount += Int(ascii - 48)
            } else {
                guard "prnbqkPRNBQK".contains(character) else { return false }
                squareCount += 1
            }
        }
        guard squareCount == 8 else { return false }
    }

    guard fields[1] == "w" || fields[1] == "b" else { return false }
    guard fields[2] == "-" || fields[2].allSatisfy({ "KQkq".contains($0) }) else {
        return false
    }
    guard fields[3] == "-" || fields[3].range(
        of: #"^[a-h][36]$"#,
        options: .regularExpression
    ) != nil else {
        return false
    }
    if fields.count == 6 {
        guard let halfmove = Int(fields[4]), halfmove >= 0,
              let fullmove = Int(fields[5]), fullmove >= 1 else {
            return false
        }
    }
    return true
}

func parseArasanBestmove(_ line: String) -> String? {
    let parts = line.split(separator: " ")
    guard (parts.count == 2 || parts.count == 4), parts[0] == "bestmove" else { return nil }
    let move = String(parts[1])
    guard isValidArasanMoveToken(move) else {
        return nil
    }
    if parts.count == 4 {
        guard parts[2] == "ponder",
              isCoordinateArasanMoveToken(move),
              isCoordinateArasanMoveToken(String(parts[3])) else {
            return nil
        }
    }
    return move
}

private func isValidArasanMoveToken(_ move: String) -> Bool {
    move.range(
        of: #"^(?:[a-h][1-8][a-h][1-8][nbrq]?|0000|\(none\))$"#,
        options: .regularExpression
    ) != nil
}

private func isCoordinateArasanMoveToken(_ move: String) -> Bool {
    move.range(
        of: #"^[a-h][1-8][a-h][1-8][nbrq]?$"#,
        options: .regularExpression
    ) != nil
}

private func isValidSingleLineUCICommand(_ command: String) -> Bool {
    !command.isEmpty
        && command.utf8.count <= 1024 * 1024
        && !command.contains("\0")
        && !command.contains("\r")
        && !command.contains("\n")
}

private func isRuntimeNNUEFileOption(_ command: String) -> Bool {
    let normalized = command
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
        .lowercased()
    return normalized == "setoption name nnue file"
        || normalized.hasPrefix("setoption name nnue file ")
}

private func isRuntimeThreadsOption(_ command: String) -> Bool {
    let normalized = command
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
        .lowercased()
    return normalized == "setoption name threads"
        || normalized.hasPrefix("setoption name threads ")
}

private func timeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds)
        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
}

private final class LineQueue: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<String?, Never>
    }

    private let lock = NSLock()
    private var buffer: [String] = []
    private var bufferHead = 0
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private var finished = false

    func push(_ line: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.continuation.resume(returning: line)
        } else {
            buffer.append(line)
            lock.unlock()
        }
    }

    func next() async -> String? {
        let id = allocateWaiterID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if bufferHead < buffer.count {
                    let line = buffer[bufferHead]
                    bufferHead += 1
                    compactBufferIfNeeded()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if finished || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuations = waiters.map(\.continuation)
        waiters.removeAll()
        buffer.removeAll()
        bufferHead = 0
        lock.unlock()
        continuations.forEach { $0.resume(returning: nil) }
    }

    private func allocateWaiterID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextWaiterID
        nextWaiterID += 1
        return id
    }

    private func cancelWaiter(id: Int) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }

    private func compactBufferIfNeeded() {
        if bufferHead >= 1_024, bufferHead * 2 >= buffer.count {
            buffer.removeFirst(bufferHead)
            bufferHead = 0
        }
    }
}

func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let firstResult = await group.next() ?? nil
        group.cancelAll()
        if let firstResult {
            return firstResult
        }

        // Preserve a line consumed exactly when the timeout task won. Without
        // this barrier, a terminal bestmove could be lost and misattributed.
        while let trailingResult = await group.next() {
            if let trailingResult {
                return trailingResult
            }
        }
        return nil
    }
}
