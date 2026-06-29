import Foundation
import Testing
@testable import ArasanEmbedded

private let externalAssetTestsEnabled =
    ProcessInfo.processInfo.environment["ARASAN_RUN_EXTERNAL_ASSET_TESTS"] == "1"

@Suite("Engine Integration", .serialized)
struct ArasanEngineIntegrationTests {
    @Test
    func uciHandshakeAndShortSearch() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            Task {
                await stream.append(line)
            }
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
    func processWideSingleEnginePolicy() throws {
        let first = ArasanEngine { _ in }
        let second = ArasanEngine { _ in }

        try first.start()
        defer { first.stop() }

        #expect(throws: ArasanEngine.Error.startFailed) {
            try second.start()
        }
    }

    @Test
    func startupEmitsIdentityOptionsAndReadySignals() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            Task {
                await stream.append(line)
            }
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let lines = await stream.allLines()
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

        let startIndex = await stream.lineCount
        engine.sendCommand("isready")
        let line = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))

        #expect(line == "readyok")
    }

    @Test
    func bestmoveHasValidUCISyntax() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = await stream.lineCount
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
            let resetIndex = await stream.lineCount
            engine.sendCommand("ucinewgame")
            engine.sendCommand("isready")
            _ = try await stream.waitForLine(prefix: "readyok", after: resetIndex, timeout: .seconds(10))

            let startIndex = await stream.lineCount
            engine.sendCommand("position fen \(testCase.fen)")
            engine.sendCommand("go depth 1")
            _ = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(10))

            let lines = await stream.allLines()
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
    func sendCommandBeforeStartIsIgnoredSafely() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            Task {
                await stream.append(line)
            }
        }

        engine.sendCommand("isready")
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        let ready = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))
        #expect(ready == "readyok")
    }

    @Test
    func sendCommandAfterStopIsIgnoredSafely() async throws {
        let (engine, stream) = try await startEngine()
        engine.stop()
        #expect(!engine.isRunning)

        engine.sendCommand("isready")

        let restartIndex = await stream.lineCount
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", after: restartIndex, timeout: .seconds(10))
        let ready = try await stream.waitForLine(prefix: "readyok", after: restartIndex, timeout: .seconds(10))
        #expect(ready == "readyok")
    }

    @Test
    func repeatedReadyProbesReturnReadyOKEachTime() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        for attempt in 1...3 {
            let startIndex = await stream.lineCount
            engine.sendCommand("isready")
            let line = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))
            #expect(line == "readyok", "Expected readyok for attempt \(attempt)")
        }
    }

    @Test
    func uciCommandCanBeIssuedAgain() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = await stream.lineCount
        engine.sendCommand("uci")
        let uciok = try await stream.waitForLine(prefix: "uciok", after: startIndex, timeout: .seconds(10))
        #expect(uciok == "uciok")

        let readyIndex = await stream.lineCount
        engine.sendCommand("isready")
        let readyok = try await stream.waitForLine(prefix: "readyok", after: readyIndex, timeout: .seconds(5))
        #expect(readyok == "readyok")
    }

    @Test
    func concurrentCommandEnqueueDoesNotDeadlock() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = await stream.lineCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    engine.sendCommand("isready")
                }
            }
        }

        let readyok = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(10))
        #expect(readyok == "readyok")
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
            let startIndex = await stream.lineCount
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

        engine.sendCommand("position startpos")
        engine.sendCommand("go movetime 500")
        try await Task.sleep(for: .milliseconds(50))

        let stopIndex = await stream.lineCount
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
            Task {
                await firstStream.append(line)
            }
        }
        try #require(firstEngine).start()

        _ = try await firstStream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await firstStream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        firstEngine?.sendCommand("position startpos")
        firstEngine?.sendCommand("go depth 30")
        try await Task.sleep(for: .milliseconds(50))

        let stopStart = Date()
        firstEngine?.stop()
        firstEngine = nil
        let stopElapsed = Date().timeIntervalSince(stopStart)

        #expect(stopElapsed < 10.0)

        let secondStream = EngineLineStream()
        let secondEngine = ArasanEngine { line in
            Task {
                await secondStream.append(line)
            }
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
    func openingBookFixtureSuppliesBestMove() async throws {
        let bookURL = try #require(Bundle.module.url(forResource: "book", withExtension: "bin"))
        let stream = EngineLineStream()
        let engine = ArasanEngine(
            configuration: .init(useOpeningBook: true, openingBookURL: bookURL)
        ) { line in
            Task {
                await stream.append(line)
            }
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(containing: "loaded opening book", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let startIndex = await stream.lineCount
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
            Task {
                await stream.append(line)
            }
        }

        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        for puzzle in puzzles {
            let resetIndex = await stream.lineCount
            engine.sendCommand("ucinewgame")
            engine.sendCommand("isready")
            _ = try await stream.waitForLine(prefix: "readyok", after: resetIndex, timeout: .seconds(10))

            let startIndex = await stream.lineCount
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
            Task {
                await stream.append(line)
            }
        }
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", timeout: .seconds(10))
        _ = try await stream.waitForLine(containing: "found 3-man Syzygy tablebases", timeout: .seconds(10))
        _ = try await stream.waitForLine(prefix: "readyok", timeout: .seconds(10))

        let startIndex = await stream.lineCount
        engine.sendCommand("position fen 6k1/8/8/8/8/8/8/6KQ w - - 0 1")
        engine.sendCommand("go depth 1")

        let info = try await stream.waitForLine(containing: "tbhits", after: startIndex, timeout: .seconds(5))
        #expect(Self.tablebaseHits(in: info) > 0, "Expected Syzygy tablebase hits in: \(info)")

        let bestMove = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(5))
        #expect(bestMove.hasPrefix("bestmove "))
    }

    private func startEngine() async throws -> (ArasanEngine, EngineLineStream) {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            Task {
                await stream.append(line)
            }
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
