import Foundation
import Testing
import CArasanEmbeddedTestSupport
@testable import ArasanEmbedded

private let externalAssetTestsEnabled =
    ProcessInfo.processInfo.environment["ARASAN_RUN_EXTERNAL_ASSET_TESTS"] == "1"

@Suite("Engine Integration", .serialized)
struct ArasanEngineIntegrationTests {
    @Test
    func uciHandshakeAndShortSearch() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            stream.append(line)
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(containing: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(containing: "readyok", timeout: .seconds(10))

        engine.sendCommand("position startpos moves e2e4")
        engine.sendCommand("go depth 1")

        let bestMove = try await stream.waitForLine(prefix: "bestmove", timeout: .seconds(20))
        #expect(bestMove.hasPrefix("bestmove "))
    }

    @Test
    func processWideSingleEnginePolicyAllowsRejectedInstanceToRetry() async throws {
        let first = ArasanEngine { _ in }
        let secondStream = EngineLineStream()
        let second = ArasanEngine { line in
            secondStream.append(line)
        }

        try first.start()

        #expect(throws: ArasanEngine.Error.startFailed) {
            try second.start()
        }

        first.stop()
        try second.start()
        defer { second.stop() }
        _ = try await secondStream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await secondStream.waitForLine(prefix: "readyok", timeout: .seconds(10))
    }

    @Test
    func startupEmitsIdentityOptionsAndReadySignals() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            stream.append(line)
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let lines = stream.allLines()
        #expect(lines.contains { $0.hasPrefix("id name Arasan") })
        #expect(lines.contains { $0 == "id author Jon Dart" })
        #expect(lines.contains { $0.hasPrefix("option name NNUE file") })
        #expect(lines.contains { $0.hasPrefix("option name OwnBook") })
        #expect(lines.contains { $0.hasPrefix("option name Use tablebases") })
    }

    @Test
    func readyProbeReturnsReadyOK() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = stream.lineCount
        engine.sendCommand("isready")
        let line = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))

        #expect(line == "readyok")
    }

    @Test
    func bestmoveHasValidUCISyntax() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = stream.lineCount
        engine.sendCommand("position startpos")
        engine.sendCommand("go depth 1")

        let line = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(10))
        let move = try #require(Self.bestmoveToken(from: line))
        #expect(Self.isValidBestmoveToken(move), "Unexpected bestmove token: \(move)")
    }

    @Test
    func materialImbalanceProducesLargeCentipawnScores() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let cases = [
            (
                name: "white up queen",
                fen: "rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                scoreRange: 800...10_000
            ),
            (
                name: "black up queen",
                fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNB1KBNR w KQkq - 0 1",
                scoreRange: -10_000 ... -800
            ),
        ]

        for testCase in cases {
            let resetIndex = stream.lineCount
            engine.sendCommand("ucinewgame")
            engine.sendCommand("isready")
            _ = try await stream.waitForLine(prefix: "readyok", after: resetIndex, timeout: .seconds(10))

            let startIndex = stream.lineCount
            engine.sendCommand("position fen \(testCase.fen)")
            engine.sendCommand("go depth 1")
            _ = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(10))

            let lines = stream.allLines()
            let score = try #require(Self.lastCentipawnScore(in: lines.dropFirst(startIndex)))
            #expect(
                testCase.scoreRange.contains(score),
                "\(testCase.name) expected score in \(testCase.scoreRange), got \(score)"
            )
        }
    }

    @Test
    func startAndStopArePredictable() throws {
        let engine = ArasanEngine { _ in }

        try engine.start()
        #expect(engine.isRunning)
        #expect(throws: ArasanEngine.Error.startFailed) {
            try engine.start()
        }

        engine.stop()
        #expect(!engine.isRunning)

        engine.stop()
        #expect(!engine.isRunning)
    }

    @Test
    func engineThreadUsesArasanMinimumStackSize() async throws {
        let (engine, _) = try await startEngine()
        defer { engine.stop() }

        #expect(engine.engineThreadStackSize >= 4 * 1024 * 1024)
    }

    @Test
    func embeddedGlobalsInitializeAndCleanUpAcrossRestart() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            stream.append(line)
        }
        defer { engine.stop() }

        try engine.start()
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))
        #expect(AEEmbeddedGlobalsAllocatedForTesting())

        engine.stop()
        #expect(!AEEmbeddedGlobalsAllocatedForTesting())

        let restartIndex = stream.lineCount
        try engine.start()
        _ = try await stream.waitForLine(
            prefix: "readyok",
            after: restartIndex,
            timeout: .seconds(10)
        )
        #expect(AEEmbeddedGlobalsAllocatedForTesting())

        engine.stop()
        #expect(!AEEmbeddedGlobalsAllocatedForTesting())
    }

    @Test
    func stopIsSafeFromLineHandlerAndSuppressesQueuedCallbacks() async throws {
        let holder = LockedEngineReference()
        let callbackCount = LockedCounter()
        let completion = EngineLineStream()
        let engine = ArasanEngine { _ in
            let count = callbackCount.increment()
            guard count == 1 else { return }

            // Let the engine enqueue the rest of the rapid UCI handshake while
            // this serial callback is occupied, then stop from the handler.
            Thread.sleep(forTimeInterval: 0.05)
            holder.withEngine { $0?.stop() }
            completion.append("stopped")
        }
        holder.set(engine)

        try engine.start()
        _ = try await completion.waitForLine(prefix: "stopped", timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(200))

        #expect(!engine.isRunning)
        #expect(callbackCount.value == 1)
        holder.set(nil)
    }

    @Test
    func releaseWithoutExplicitStopTearsDownNativeEngine() async throws {
        let stream = EngineLineStream()
        weak var releasedEngine: ArasanEngine?
        var engine: ArasanEngine? = ArasanEngine { line in
            stream.append(line)
        }
        try #require(engine).start()
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        releasedEngine = engine
        engine = nil
        #expect(releasedEngine == nil)

        let replacement = ArasanEngine { _ in }
        try replacement.start()
        replacement.stop()
    }

    @Test
    func rawQuitUpdatesRunningStateAndAllowsRestart() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        engine.sendCommand("quit")
        try await waitUntil(timeout: .seconds(5)) { !engine.isRunning }

        let restartIndex = stream.lineCount
        try engine.start()
        _ = try await stream.waitForLine(prefix: "uciok", after: restartIndex, timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", after: restartIndex, timeout: .seconds(10))
    }

    @Test
    func unsafeCommandShapesAreRejectedWithoutBreakingUCI() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = stream.lineCount
        engine.sendCommand("isready\nquit")
        engine.sendCommand("isready\0quit")
        engine.sendCommand(String(repeating: "x", count: 1024 * 1024 + 1))
        engine.sendCommand("setoption name NNUE file value /tmp/untrusted.nnue")
        engine.sendCommand("setoption name Threads value 2")
        engine.sendCommand("isready\r\n")

        try await stream.waitForCount(5, after: startIndex, timeout: .seconds(5)) {
            $0.hasPrefix("info string ArasanEmbedded error:")
        }
        let ready = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))
        #expect(ready == "readyok")
    }

    @Test
    func processOptionsResetBetweenEngineInstances() async throws {
        let (first, firstStream) = try await startEngine()
        let optionStart = firstStream.lineCount
        first.sendCommand("setoption name Hash value 64")
        first.sendCommand("setoption name Position learning value true")
        first.sendCommand("isready")
        _ = try await firstStream.waitForLine(prefix: "readyok", after: optionStart, timeout: .seconds(10))
        #expect(AECurrentHashBytesForTesting() == 64 * 1024 * 1024)
        #expect(AECurrentThreadCountForTesting() == 1)
        #expect(AECurrentPositionLearningForTesting())
        first.stop()

        let secondStream = EngineLineStream()
        let second = ArasanEngine { line in
            secondStream.append(line)
        }
        try second.start()
        defer { second.stop() }
        _ = try await secondStream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await secondStream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        #expect(AECurrentHashBytesForTesting() == 32 * 1024 * 1024)
        #expect(AECurrentThreadCountForTesting() == 1)
        #expect(!AECurrentPositionLearningForTesting())

        let lines = secondStream.allLines()
        #expect(lines.contains("option name Hash type spin default 32 min 4 max 64000"))
        #expect(lines.contains("option name Threads type spin default 1 min 1 max 512"))
        #expect(lines.contains("option name Position learning type check default false"))
    }

    @Test
    func concurrentLifecycleCallsRemainReusable() async throws {
        let engine = ArasanEngine { _ in }
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            switch index % 3 {
            case 0:
                try? engine.start()
            case 1:
                engine.sendCommand("isready")
            default:
                engine.stop()
            }
        }
        engine.stop()

        let stream = EngineLineStream()
        let replacement = ArasanEngine { line in
            stream.append(line)
        }
        try replacement.start()
        defer { replacement.stop() }
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))
    }

    @Test
    func outputFlushDoesNotCreateFalseLines() {
        #expect(AEOutputFlushPreservesLineForTesting())
    }

    @Test
    func concurrentNativeOutputPreservesLineSubmissionOrder() {
        #expect(AEConcurrentOutputPreservesSubmissionOrderForTesting())
    }

    @Test
    func nativeRunRestoresHostStandardStreamState() {
        #expect(AEStandardStreamsRestoreForTesting())
    }

    @Test
    func sendCommandBeforeStartIsIgnoredSafely() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            stream.append(line)
        }

        engine.sendCommand("isready")
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        let ready = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))
        #expect(ready == "readyok")
        try await Task.sleep(for: .milliseconds(100))
        #expect(stream.count { $0 == "readyok" } == 1)
    }

    @Test
    func sendCommandAfterStopIsIgnoredSafely() async throws {
        let (engine, stream) = try await startEngine()
        engine.stop()
        #expect(!engine.isRunning)

        engine.sendCommand("isready")

        let restartIndex = stream.lineCount
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", after: restartIndex, timeout: .seconds(10))
        let ready = try await stream.waitForLine(prefix: "readyok", after: restartIndex, timeout: .seconds(10))
        #expect(ready == "readyok")
        try await Task.sleep(for: .milliseconds(100))
        #expect(stream.allLines()[restartIndex...].count(where: { $0 == "readyok" }) == 1)
    }

    @Test
    func repeatedReadyProbesReturnReadyOKEachTime() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        for attempt in 1...3 {
            let startIndex = stream.lineCount
            engine.sendCommand("isready")
            let line = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))
            #expect(line == "readyok", "Expected readyok for attempt \(attempt)")
        }
    }

    @Test
    func uciCommandCanBeIssuedAgain() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = stream.lineCount
        engine.sendCommand("uci")
        let uciok = try await stream.waitForLine(prefix: "uciok", after: startIndex, timeout: .seconds(10))
        #expect(uciok == "uciok")

        let readyIndex = stream.lineCount
        engine.sendCommand("isready")
        let readyok = try await stream.waitForLine(prefix: "readyok", after: readyIndex, timeout: .seconds(5))
        #expect(readyok == "readyok")
    }

    @Test
    func concurrentCommandEnqueueDoesNotDeadlock() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = stream.lineCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    engine.sendCommand("isready")
                }
            }
        }

        try await stream.waitForCount(20, after: startIndex, timeout: .seconds(10)) {
            $0 == "readyok"
        }
    }

    @Test
    func backToBackSearchesProduceBestmoves() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let positions = [
            "startpos",
            "8/3B2pp/p5k1/6P1/1ppp1K2/8/1P6/8 w - - 0 39",
            "6k1/5p1p/4p3/4q3/3n4/2Q3P1/PP1N1P1P/6K1 b - - 3 37",
        ]

        for (index, fen) in positions.enumerated() {
            let startIndex = stream.lineCount
            if fen == "startpos" {
                engine.sendCommand("position startpos")
            } else {
                engine.sendCommand("position fen \(fen)")
            }
            engine.sendCommand("go depth 1")

            let line = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(10))
            let move = try #require(Self.bestmoveToken(from: line))
            #expect(
                Self.isValidBestmoveToken(move),
                "Unexpected bestmove token for search \(index + 1): \(move)"
            )
        }
    }

    @Test
    func stopDuringLongSearchReturnsPromptly() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let searchIndex = stream.lineCount
        engine.sendCommand("position startpos")
        engine.sendCommand("go movetime 500")
        _ = try await stream.waitForLine(after: searchIndex, timeout: .seconds(3)) {
            $0.hasPrefix("info ") && $0.contains(" depth ")
        }

        let stopIndex = stream.lineCount
        let start = Date()
        engine.sendCommand("stop")
        let line = try await stream.waitForLine(prefix: "bestmove", after: stopIndex, timeout: .seconds(3))
        let elapsed = Date().timeIntervalSince(start)
        let move = try #require(Self.bestmoveToken(from: line))

        #expect(elapsed < 3.0)
        #expect(Self.isValidBestmoveToken(move))
    }

    @Test
    func stoppingWrapperDuringActiveSearchAllowsFreshEngineStart() async throws {
        let firstStream = EngineLineStream()
        var firstEngine: ArasanEngine? = ArasanEngine { line in
            firstStream.append(line)
        }
        try #require(firstEngine).start()

        _ = try await firstStream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await firstStream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let activeSearchIndex = firstStream.lineCount
        firstEngine?.sendCommand("position startpos")
        firstEngine?.sendCommand("go depth 30")
        _ = try await firstStream.waitForLine(after: activeSearchIndex, timeout: .seconds(3)) {
            $0.hasPrefix("info ") && $0.contains(" depth ")
        }

        let stopStart = Date()
        firstEngine?.stop()
        firstEngine = nil
        let stopElapsed = Date().timeIntervalSince(stopStart)

        #expect(stopElapsed < 10.0)

        let secondStream = EngineLineStream()
        let secondEngine = ArasanEngine { line in
            secondStream.append(line)
        }
        try secondEngine.start()
        defer { secondEngine.stop() }

        _ = try await secondStream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await secondStream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        secondEngine.sendCommand("position startpos")
        secondEngine.sendCommand("go depth 1")

        let line = try await secondStream.waitForLine(prefix: "bestmove", timeout: .seconds(10))
        let move = try #require(Self.bestmoveToken(from: line))
        #expect(Self.isValidBestmoveToken(move))
    }

    @Test
    func repeatedStopsDuringSearchReturnBestmoves() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        for attempt in 1...5 {
            let startIndex = stream.lineCount
            engine.sendCommand("position startpos")
            engine.sendCommand("go movetime 500")
            _ = try await stream.waitForLine(after: startIndex, timeout: .seconds(3)) {
                $0.hasPrefix("info ") && $0.contains(" depth ")
            }

            let stopStart = Date()
            engine.sendCommand("stop")
            let line = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(3))
            let elapsed = Date().timeIntervalSince(stopStart)
            let move = try #require(Self.bestmoveToken(from: line))

            #expect(elapsed < 3.0, "Stop attempt \(attempt) took too long: \(elapsed)s")
            #expect(Self.isValidBestmoveToken(move), "Unexpected bestmove token on attempt \(attempt): \(move)")
        }
    }

    @Test
    func repeatedActiveSearchStopsAllowFreshEngineStarts() async throws {
        for attempt in 1...5 {
            do {
                let stream = EngineLineStream()
                let engine = ArasanEngine { line in
                    stream.append(line)
                }

                try engine.start()
                defer { engine.stop() }

                _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
                _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

                let activeSearchIndex = stream.lineCount
                engine.sendCommand("position startpos")
                engine.sendCommand("go depth 30")
                _ = try await stream.waitForLine(after: activeSearchIndex, timeout: .seconds(3)) {
                    $0.hasPrefix("info ") && $0.contains(" depth ")
                }

                let stopStart = Date()
                engine.stop()
                let elapsed = Date().timeIntervalSince(stopStart)

                #expect(elapsed < 10.0, "Fresh-start stop attempt \(attempt) took too long: \(elapsed)s")
            }
        }
    }

    @Test
    func soakRunnerCompletesShortRun() async {
        let configuration = ArasanSoakRunner.Configuration(
            positions: [
                .init(id: "startpos", fen: "startpos"),
                .init(id: "mate", fen: "8/3B2pp/p5k1/6P1/1ppp1K2/8/1P6/8 w - - 0 39"),
            ],
            searchLimit: .moveTimeMillis(50),
            maxIterations: 2,
            perMoveTimeout: 10,
            readyCheckEveryIteration: true
        )

        let summary = await ArasanSoakRunner(configuration: configuration).run()

        #expect(summary.iterationsAttempted == 2)
        #expect(summary.iterationsCompleted == 2)
        #expect(summary.timeouts == 0)
        #expect(summary.errors == 0)
    }

    @Test
    func soakRunnerRejectsInvalidConfigurationBeforeStartingEngine() async {
        let position = ArasanSoakRunner.PositionSpec(fen: "startpos")
        let configurations = [
            ArasanSoakRunner.Configuration(
                positions: [position],
                searchLimit: .depth(0),
                maxIterations: 1
            ),
            ArasanSoakRunner.Configuration(
                positions: [position],
                maxIterations: 0
            ),
            ArasanSoakRunner.Configuration(
                positions: [position],
                maxIterations: 1,
                perMoveTimeout: .nan
            ),
            ArasanSoakRunner.Configuration(
                positions: [position],
                maxIterations: 1,
                perMoveTimeout: 1e300
            ),
            ArasanSoakRunner.Configuration(
                positions: [position],
                maxIterations: 1,
                perMoveTimeout: .leastNonzeroMagnitude
            ),
            ArasanSoakRunner.Configuration(
                positions: [position],
                maxIterations: 1,
                delayBetweenIterations: .greatestFiniteMagnitude
            ),
            ArasanSoakRunner.Configuration(
                positions: [.init(fen: "8/8/8\nquit")],
                maxIterations: 1
            ),
        ]

        for configuration in configurations {
            let summary = await ArasanSoakRunner(configuration: configuration).run()
            #expect(summary.iterationsAttempted == 0)
            #expect(summary.errors == 1)
        }
    }

    @Test
    func soakRunnerStopsPromptlyFromStartedEventAndFinishesLast() async {
        let recorder = LockedEventRecorder()
        let runner = ArasanSoakRunner(configuration: .init(
            positions: [.init(fen: "startpos")],
            searchLimit: .depth(30)
        ))

        let summary = await runner.run { event in
            recorder.record(event)
            if case .started = event {
                runner.stop()
            }
        }

        #expect(summary.iterationsAttempted == 0)
        #expect(summary.errors == 0)
        #expect(Array(recorder.labels.suffix(2)) == ["stopped", "finished"])
    }

    @Test
    func soakRunnerSerializesEngineOutputBeforeCompletionEvents() async {
        let recorder = LockedEventRecorder()
        let runner = ArasanSoakRunner(configuration: .init(
            positions: [.init(fen: "startpos")],
            searchLimit: .depth(1),
            maxIterations: 1
        ))

        let summary = await runner.run { recorder.record($0) }
        let labels = recorder.labels

        #expect(summary.iterationsCompleted == 1)
        let bestmoveOutput = labels.firstIndex(of: "output:bestmove")
        let completed = labels.firstIndex(of: "completed")
        #expect(bestmoveOutput != nil)
        #expect(completed != nil)
        if let bestmoveOutput, let completed {
            #expect(bestmoveOutput < completed)
        }
        #expect(Array(labels.suffix(2)) == ["stopped", "finished"])
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutPreservesAnOperationResultReturnedAfterCancellation() async {
        let result: String? = await withTimeout(.milliseconds(1)) {
            while !Task.isCancelled {
                await Task.yield()
            }
            return "consumed"
        }

        #expect(result == "consumed")
    }

    @Test(.timeLimit(.minutes(1)))
    func soakRunnerRespondsToTaskCancellation() async throws {
        let recorder = LockedEventRecorder()
        let runner = ArasanSoakRunner(configuration: .init(
            positions: [.init(fen: "startpos")],
            searchLimit: .depth(30)
        ))
        let task = Task {
            await runner.run { recorder.record($0) }
        }

        try await waitUntil(timeout: .seconds(5)) { recorder.labels.contains("started") }
        task.cancel()
        let summary = await task.value

        #expect(summary.errors == 0)
        #expect(Array(recorder.labels.suffix(2)) == ["stopped", "finished"])
    }

    @Test(.timeLimit(.minutes(1)))
    func soakRunnerRejectsAConcurrentRunUntilTerminalEventsFinish() async throws {
        let firstRecorder = LockedEventRecorder()
        let runner = ArasanSoakRunner(configuration: .init(
            positions: [.init(fen: "startpos")],
            searchLimit: .depth(30)
        ))
        let firstTask = Task {
            await runner.run { firstRecorder.record($0) }
        }

        try await waitUntil(timeout: .seconds(5)) { firstRecorder.labels.contains("started") }
        let rejectedRecorder = LockedEventRecorder()
        let rejected = await runner.run { rejectedRecorder.record($0) }

        #expect(rejected.errors == 1)
        #expect(rejectedRecorder.labels == ["error", "finished"])

        runner.stop()
        let first = await firstTask.value
        #expect(first.errors == 0)
        #expect(Array(firstRecorder.labels.suffix(2)) == ["stopped", "finished"])
    }

    @Test
    func recoveredTimeoutConsumesTerminalBestmoveBeforeNextPosition() async {
        let recorder = LockedEventRecorder()
        let runner = ArasanSoakRunner(configuration: .init(
            positions: [
                .init(id: "first", fen: "startpos"),
                .init(id: "second", fen: "8/3B2pp/p5k1/6P1/1ppp1K2/8/1P6/8 w - - 0 39"),
            ],
            searchLimit: .depth(30),
            maxIterations: 2,
            perMoveTimeout: 0.000_001,
            stopTimeout: 5,
            stopOnTimeoutFailure: false
        ))

        let summary = await runner.run { recorder.record($0) }

        #expect(summary.iterationsAttempted == 2)
        #expect(summary.iterationsCompleted == 0)
        #expect(summary.timeouts == 2)
        #expect(summary.errors == 0)
        #expect(recorder.timeoutIndices == [0, 1])
        #expect(!recorder.labels.contains("completed"))
        let labels = recorder.labels
        let starts = labels.indices.filter { labels[$0] == "iterationStarted" }
        let firstTimeout = labels.firstIndex(of: "timeout")
        if starts.count == 2, let firstTimeout,
           let terminal = labels[(firstTimeout + 1)...].firstIndex(of: "output:bestmove") {
            #expect(firstTimeout < terminal)
            #expect(terminal < starts[1])
        } else {
            Issue.record("Expected timeout, terminal bestmove output, then the second iteration.")
        }
    }

    @Test
    func openingBookFixtureSuppliesBestMove() async throws {
        let bookURL = try #require(Bundle.module.url(forResource: "book", withExtension: "bin"))
        let stream = EngineLineStream()
        let engine = ArasanEngine(
            configuration: .init(useOpeningBook: true, openingBookURL: bookURL)
        ) { line in
            stream.append(line)
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(containing: "loaded opening book", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let startIndex = stream.lineCount
        engine.sendCommand("position startpos")
        engine.sendCommand("go depth 8")

        let bookLine = try await stream.waitForLine(
            containing: "book moves (a3), choosing a3",
            after: startIndex,
            timeout: .seconds(5)
        )
        #expect(bookLine.contains("choosing a3"))

        let bestMove = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(5))
        #expect(bestMove == "bestmove a2a3")
    }

    @Test
    func lichessPuzzleRegressionSuiteFindsAllowedMoves() async throws {
        let puzzles = try LichessPuzzleCorpus.load()
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            stream.append(line)
        }

        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        for puzzle in puzzles {
            let resetIndex = stream.lineCount
            engine.sendCommand("ucinewgame")
            engine.sendCommand("isready")
            _ = try await stream.waitForLine(prefix: "readyok", after: resetIndex, timeout: .seconds(10))

            let startIndex = stream.lineCount
            engine.sendCommand("position fen \(puzzle.fen)")
            engine.sendCommand("go depth 4")

            let line = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(20))
            let bestmove = try #require(Self.bestmoveToken(from: line))

            #expect(
                puzzle.allowedMoves.contains(bestmove),
                "\(puzzle.id) expected one of \(puzzle.allowedMoves.sorted()), got \(bestmove)"
            )
        }
    }

    @Test(.enabled(if: externalAssetTestsEnabled, "Set ARASAN_RUN_EXTERNAL_ASSET_TESTS=1 and run Scripts/test-external-assets.sh."))
    func downloadedKQvKSyzygyFixtureProducesTablebaseHits() async throws {
        let tablebaseURL = syzygyFixtureDirectory()
        try assertTablebaseFixtureExists(in: tablebaseURL)

        let stream = EngineLineStream()
        let engine = ArasanEngine(
            configuration: .init(
                useTablebases: true,
                tablebaseDirectoryURL: tablebaseURL,
                tablebaseProbeDepth: 0
            )
        ) { line in
            stream.append(line)
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(containing: "found 3-man Syzygy tablebases", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let startIndex = stream.lineCount
        engine.sendCommand("position fen 6k1/8/8/8/8/8/8/6KQ w - - 0 1")
        engine.sendCommand("go depth 1")

        let info = try await stream.waitForLine(after: startIndex, timeout: .seconds(5)) {
            Self.tablebaseHits(in: $0) > 0
        }
        #expect(Self.tablebaseHits(in: info) > 0, "Expected Syzygy tablebase hits in: \(info)")

        let bestMove = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(5))
        #expect(bestMove.hasPrefix("bestmove "))
    }

    private func startEngine() async throws -> (ArasanEngine, EngineLineStream) {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            stream.append(line)
        }

        try engine.start()
        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))
        return (engine, stream)
    }

    private func syzygyFixtureDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["ARASAN_SYZYGY_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-assets/syzygy")
    }

    private func assertTablebaseFixtureExists(in directory: URL) throws {
        let fileManager = FileManager.default
        let requiredFiles = ["KQvK.rtbw", "KQvK.rtbz"]
        for file in requiredFiles {
            let url = directory.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: url.path) else {
                Issue.record("Missing \(file). Run Scripts/test-external-assets.sh to download and verify Syzygy fixtures.")
                throw MissingSyzygyFixtureError()
            }
        }
    }

    private static func bestmoveToken(from line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "bestmove" else {
            return nil
        }
        return String(parts[1])
    }

    private static func isValidBestmoveToken(_ token: String) -> Bool {
        if token == "(none)" {
            return true
        }

        guard token.count == 4 || token.count == 5 else {
            return false
        }
        let characters = Array(token)
        guard
            ("a"..."h").contains(characters[0]),
            ("1"..."8").contains(characters[1]),
            ("a"..."h").contains(characters[2]),
            ("1"..."8").contains(characters[3])
        else {
            return false
        }

        if characters.count == 5 {
            return ["q", "r", "b", "n"].contains(characters[4])
        }
        return true
    }

    private static func lastCentipawnScore<S: Sequence>(in lines: S) -> Int? where S.Element == String {
        lines.compactMap(centipawnScore).last
    }

    private static func centipawnScore(in line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard
            let scoreIndex = parts.firstIndex(of: "score"),
            parts.indices.contains(parts.index(scoreIndex, offsetBy: 2)),
            parts[parts.index(after: scoreIndex)] == "cp"
        else {
            return nil
        }

        return Int(parts[parts.index(scoreIndex, offsetBy: 2)])
    }

    private static func tablebaseHits(in line: String) -> Int {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: "tbhits"), parts.indices.contains(parts.index(after: index)) else {
            return 0
        }
        return Int(parts[parts.index(after: index)]) ?? 0
    }
}

private struct MissingSyzygyFixtureError: Error {}

private final class LockedEngineReference: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: ArasanEngine?

    func set(_ engine: ArasanEngine?) {
        lock.withLock {
            self.engine = engine
        }
    }

    func withEngine(_ operation: (ArasanEngine?) -> Void) {
        let engine = lock.withLock { self.engine }
        operation(engine)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class LockedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLabels: [String] = []
    private var recordedTimeoutIndices: [Int] = []

    var labels: [String] {
        lock.withLock { recordedLabels }
    }

    var timeoutIndices: [Int] {
        lock.withLock { recordedTimeoutIndices }
    }

    func record(_ event: ArasanSoakRunner.Event) {
        lock.withLock {
            switch event {
            case .started:
                recordedLabels.append("started")
            case .engineOutput(let line):
                recordedLabels.append(parseArasanBestmove(line) == nil ? "output" : "output:bestmove")
            case .iterationStarted:
                recordedLabels.append("iterationStarted")
            case .iterationCompleted:
                recordedLabels.append("completed")
            case .timeout(let index, _, _):
                recordedLabels.append("timeout")
                recordedTimeoutIndices.append(index)
            case .error:
                recordedLabels.append("error")
            case .stopped:
                recordedLabels.append("stopped")
            case .finished:
                recordedLabels.append("finished")
            }
        }
    }
}

private func waitUntil(
    timeout: Duration,
    predicate: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if !predicate() {
        throw WaitUntilTimeoutError()
    }
}

private struct WaitUntilTimeoutError: Error {}
