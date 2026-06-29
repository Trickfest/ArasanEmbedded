@testable import ArasanEmbedded
import XCTest

final class ArasanEngineContractTests: XCTestCase {
    func testContractStartupEmitsIdentityOptionsAndReadySignals() async throws {
        let stream = TestEngineLineStream()
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
        XCTAssertTrue(lines.contains { $0.hasPrefix("id name Arasan") })
        XCTAssertTrue(lines.contains { $0 == "id author Jon Dart" })
        XCTAssertTrue(lines.contains { $0.hasPrefix("option name NNUE file") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("option name OwnBook") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("option name Use tablebases") })
    }

    func testContractReadyProbeReturnsReadyOK() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = await stream.lineCount
        engine.sendCommand("isready")
        let line = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))

        XCTAssertEqual(line, "readyok")
    }

    func testContractBestmoveHasValidUCISyntax() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = await stream.lineCount
        engine.sendCommand("position startpos")
        engine.sendCommand("go depth 1")

        let line = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(10))
        let move = try XCTUnwrap(Self.bestmoveToken(from: line))
        XCTAssertTrue(Self.isValidBestmoveToken(move), "Unexpected bestmove token: \(move)")
    }

    func testContractStartAndStopArePredictable() throws {
        let engine = ArasanEngine { _ in }

        try engine.start()
        XCTAssertTrue(engine.isRunning)
        XCTAssertThrowsError(try engine.start())

        engine.stop()
        XCTAssertFalse(engine.isRunning)

        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    func testContractSendCommandBeforeStartIsIgnoredSafely() async throws {
        let stream = TestEngineLineStream()
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
        XCTAssertEqual(ready, "readyok")
    }

    func testContractSendCommandAfterStopIsIgnoredSafely() async throws {
        let (engine, stream) = try await startEngine()
        engine.stop()
        XCTAssertFalse(engine.isRunning)

        engine.sendCommand("isready")

        let restartIndex = await stream.lineCount
        try engine.start()
        defer { engine.stop() }

        _ = try await stream.waitForLine(prefix: "uciok", after: restartIndex, timeout: .seconds(10))
        let ready = try await stream.waitForLine(prefix: "readyok", after: restartIndex, timeout: .seconds(10))
        XCTAssertEqual(ready, "readyok")
    }

    func testContractRepeatedReadyProbesReturnReadyOKEachTime() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        for attempt in 1...3 {
            let startIndex = await stream.lineCount
            engine.sendCommand("isready")
            let line = try await stream.waitForLine(prefix: "readyok", after: startIndex, timeout: .seconds(5))
            XCTAssertEqual(line, "readyok", "Expected readyok for attempt \(attempt)")
        }
    }

    func testContractUCICommandCanBeIssuedAgain() async throws {
        let (engine, stream) = try await startEngine()
        defer { engine.stop() }

        let startIndex = await stream.lineCount
        engine.sendCommand("uci")
        let uciok = try await stream.waitForLine(prefix: "uciok", after: startIndex, timeout: .seconds(10))
        XCTAssertEqual(uciok, "uciok")

        let readyIndex = await stream.lineCount
        engine.sendCommand("isready")
        let readyok = try await stream.waitForLine(prefix: "readyok", after: readyIndex, timeout: .seconds(5))
        XCTAssertEqual(readyok, "readyok")
    }

    func testContractConcurrentCommandEnqueueDoesNotDeadlock() async throws {
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
        XCTAssertEqual(readyok, "readyok")
    }

    func testContractBackToBackSearchesProduceBestmoves() async throws {
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
            let move = try XCTUnwrap(Self.bestmoveToken(from: line))
            XCTAssertTrue(
                Self.isValidBestmoveToken(move),
                "Unexpected bestmove token for search \(index + 1): \(move)"
            )
        }
    }

    func testContractStopDuringLongSearchReturnsPromptly() async throws {
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
        let move = try XCTUnwrap(Self.bestmoveToken(from: line))

        XCTAssertLessThan(elapsed, 3.0)
        XCTAssertTrue(Self.isValidBestmoveToken(move))
    }

    func testSoakRunnerCompletesShortRun() async {
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

        XCTAssertEqual(summary.iterationsAttempted, 2)
        XCTAssertEqual(summary.iterationsCompleted, 2)
        XCTAssertEqual(summary.timeouts, 0)
        XCTAssertEqual(summary.errors, 0)
    }

    private func startEngine() async throws -> (ArasanEngine, TestEngineLineStream) {
        let stream = TestEngineLineStream()
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
}

private actor TestEngineLineStream {
    private var lines: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var lineCount: Int {
        lines.count
    }

    func append(_ line: String) {
        lines.append(line)
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func allLines() -> [String] {
        lines
    }

    func waitForLine(prefix: String, timeout: Duration) async throws -> String {
        try await waitForLine(prefix: prefix, after: 0, timeout: timeout)
    }

    func waitForLine(prefix: String, after startIndex: Int = 0, timeout: Duration) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                while true {
                    if let line = await self.matchingLine(prefix: prefix, after: startIndex) {
                        return line
                    }
                    await self.waitForNewLine()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeoutError()
            }
            let line = try await group.next()!
            group.cancelAll()
            return line
        }
    }

    private func matchingLine(prefix: String, after startIndex: Int) -> String? {
        lines.dropFirst(startIndex).first { $0.hasPrefix(prefix) }
    }

    private func waitForNewLine() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct TestTimeoutError: Error {}
