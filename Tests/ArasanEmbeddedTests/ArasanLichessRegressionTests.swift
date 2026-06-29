@testable import ArasanEmbedded
import XCTest

final class ArasanLichessRegressionTests: XCTestCase {
    func testLichessPuzzleCorpusHasRequiredCoverage() throws {
        let puzzles = try Self.loadCorpus()

        XCTAssertEqual(puzzles.count, 36)
        XCTAssertEqual(Set(puzzles.map(\.id)).count, puzzles.count)
        XCTAssertGreaterThanOrEqual(puzzles.count(where: { $0.themes.contains("mateIn1") }), 5)
        XCTAssertGreaterThanOrEqual(puzzles.count(where: { $0.themes.contains("mateIn2") }), 8)
        XCTAssertGreaterThanOrEqual(puzzles.count(where: { $0.themes.contains("fork") }), 5)
        XCTAssertGreaterThanOrEqual(puzzles.count(where: { $0.themes.contains("hangingPiece") }), 5)
        XCTAssertGreaterThanOrEqual(puzzles.count(where: { $0.themes.contains("endgame") }), 10)
        XCTAssertGreaterThanOrEqual(puzzles.count(where: { $0.themes.contains("promotion") }), 10)

        for puzzle in puzzles {
            XCTAssertFalse(puzzle.id.isEmpty)
            XCTAssertFalse(puzzle.sourceFEN.isEmpty)
            XCTAssertFalse(puzzle.firstMove.isEmpty)
            XCTAssertFalse(puzzle.fen.isEmpty)
            XCTAssertFalse(puzzle.expectedMove.isEmpty)
            XCTAssertFalse(puzzle.allowedMoves.isEmpty)
            XCTAssertTrue(puzzle.allowedMoves.contains(puzzle.expectedMove))
            XCTAssertTrue(puzzle.sourceURL.absoluteString.hasPrefix("https://lichess.org/"))
        }
    }

    func testLichessPuzzleRegressionSuiteFindsAllowedMoves() async throws {
        let puzzles = try Self.loadCorpus()
        let stream = RegressionLineStream()
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
            let bestmove = try XCTUnwrap(Self.bestmoveToken(from: line))

            XCTAssertTrue(
                puzzle.allowedMoves.contains(bestmove),
                "\(puzzle.id) expected one of \(puzzle.allowedMoves.sorted()), got \(bestmove)"
            )
        }
    }

    private static func loadCorpus() throws -> [LichessPuzzle] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Soak/lichess_puzzles.tsv")

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard let headerLine = lines.first else {
            return []
        }

        let headers = headerLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let rows = try lines.dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return try LichessPuzzle(headers: headers, fields: fields)
        }
        return rows
    }

    private static func bestmoveToken(from line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "bestmove" else {
            return nil
        }
        return String(parts[1])
    }
}

private struct LichessPuzzle {
    var id: String
    var sourceFEN: String
    var firstMove: String
    var fen: String
    var expectedMove: String
    var allowedMoves: Set<String>
    var themes: Set<String>
    var sourceURL: URL

    init(headers: [String], fields: [String]) throws {
        func value(_ name: String) throws -> String {
            guard let index = headers.firstIndex(of: name), index < fields.count else {
                throw CorpusError.missingColumn(name)
            }
            return fields[index]
        }

        id = try value("id")
        sourceFEN = try value("source_fen")
        firstMove = try value("first_move")
        fen = try value("fen")
        expectedMove = try value("expected_move")
        allowedMoves = Set(try value("allowed_moves").split(separator: ",").map(String.init))
        themes = Set(try value("themes").split(separator: " ").map(String.init))
        sourceURL = try XCTUnwrap(URL(string: try value("source_url")))
    }
}

private actor RegressionLineStream {
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

    func waitForLine(prefix: String, timeout: Duration) async throws -> String {
        try await waitForLine(prefix: prefix, after: 0, timeout: timeout)
    }

    func waitForLine(prefix: String, after startIndex: Int, timeout: Duration) async throws -> String {
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
                throw RegressionTimeoutError()
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

private enum CorpusError: Error {
    case missingColumn(String)
}

private struct RegressionTimeoutError: Error {}
