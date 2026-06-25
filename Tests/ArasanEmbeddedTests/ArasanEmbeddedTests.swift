@testable import ArasanEmbedded
import XCTest

final class ArasanEmbeddedTests: XCTestCase {
    func testDefaultConfigurationUsesBundledNNUE() throws {
        let configuration = ArasanEngine.Configuration.default
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.nnueURL.path))
        XCTAssertFalse(configuration.useOpeningBook)
        XCTAssertFalse(configuration.useTablebases)
        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name OwnBook value false"))
        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name Use tablebases value false"))
    }

    func testOpeningBookConfigurationBuildsExpectedUCIOptions() {
        let url = URL(fileURLWithPath: "/tmp/book.bin")
        let configuration = ArasanEngine.Configuration(useOpeningBook: true, openingBookURL: url)

        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name BookPath value /tmp/book.bin"))
        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name OwnBook value true"))
    }

    func testTablebaseConfigurationBuildsExpectedUCIOptions() {
        let url = URL(fileURLWithPath: "/tmp/syzygy")
        let configuration = ArasanEngine.Configuration(
            useTablebases: true,
            tablebaseDirectoryURL: url,
            tablebaseProbeDepth: 4,
            syzygyUses50MoveRule: false
        )

        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name SyzygyPath value /tmp/syzygy"))
        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name SyzygyProbeDepth value 4"))
        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name SyzygyUse50MoveRule value false"))
        XCTAssertTrue(configuration.uciOptionCommands.contains("setoption name Use tablebases value true"))
    }

    func testMissingNNUEIsRejectedBeforeEngineStart() {
        let configuration = ArasanEngine.Configuration(
            nnueURL: URL(fileURLWithPath: "/tmp/does-not-exist.nnue")
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                error as? ArasanEngine.Error,
                .missingNNUE(URL(fileURLWithPath: "/tmp/does-not-exist.nnue"))
            )
        }
    }

    func testMissingOpeningBookIsRejectedWhenBookIsEnabled() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-book.bin")
        let configuration = ArasanEngine.Configuration(useOpeningBook: true, openingBookURL: url)

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ArasanEngine.Error, .missingOpeningBook(url))
        }
    }

    func testMissingTablebaseDirectoryIsRejectedWhenTablebasesAreEnabled() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-syzygy")
        let configuration = ArasanEngine.Configuration(useTablebases: true, tablebaseDirectoryURL: url)

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ArasanEngine.Error, .missingTablebaseDirectory(url))
        }
    }

    func testInvalidTablebaseProbeDepthIsRejected() {
        let configuration = ArasanEngine.Configuration(tablebaseProbeDepth: 65)

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ArasanEngine.Error, .invalidTablebaseProbeDepth(65))
        }
    }

    func testUCIHandshakeAndShortSearch() async throws {
        let stream = EngineLineStream()
        let engine = ArasanEngine { line in
            Task {
                await stream.append(line)
            }
        }
        try engine.start()
        defer { engine.stop() }

        try await stream.waitForLine(containing: "uciok", timeout: .seconds(10))
        try await stream.waitForLine(containing: "readyok", timeout: .seconds(10))

        engine.sendCommand("position startpos moves e2e4")
        engine.sendCommand("go depth 1")

        let bestMove = try await stream.waitForLine(prefix: "bestmove", timeout: .seconds(20))
        XCTAssertTrue(bestMove.hasPrefix("bestmove "))
    }

    func testProcessWideSingleEnginePolicy() throws {
        let first = ArasanEngine { _ in }
        let second = ArasanEngine { _ in }

        try first.start()
        defer { first.stop() }

        XCTAssertThrowsError(try second.start())
    }
}

private actor EngineLineStream {
    private var lines: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func append(_ line: String) {
        lines.append(line)
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitForLine(
        containing needle: String? = nil,
        prefix: String? = nil,
        timeout: Duration
    ) async throws {
        _ = try await waitForLineValue(containing: needle, prefix: prefix, timeout: timeout)
    }

    func waitForLine(
        prefix: String,
        timeout: Duration
    ) async throws -> String {
        try await waitForLineValue(prefix: prefix, timeout: timeout)
    }

    private func waitForLineValue(
        containing needle: String? = nil,
        prefix: String? = nil,
        timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                while true {
                    if let line = await self.matchingLine(containing: needle, prefix: prefix) {
                        return line
                    }
                    await self.waitForNewLine()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            let line = try await group.next()!
            group.cancelAll()
            return line
        }
    }

    private func matchingLine(containing needle: String?, prefix: String?) -> String? {
        if let needle {
            return lines.first { $0.contains(needle) }
        }
        if let prefix {
            return lines.first { $0.hasPrefix(prefix) }
        }
        return nil
    }

    private func waitForNewLine() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct TimeoutError: Error {}
