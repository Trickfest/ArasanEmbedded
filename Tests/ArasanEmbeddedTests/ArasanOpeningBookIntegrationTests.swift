@testable import ArasanEmbedded
import XCTest

final class ArasanOpeningBookIntegrationTests: XCTestCase {
    func testOpeningBookFixtureSuppliesBestMove() async throws {
        let bookURL = try XCTUnwrap(Bundle.module.url(forResource: "book", withExtension: "bin"))
        let stream = AssetTestLineStream()
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
        XCTAssertTrue(bookLine.contains("choosing a3"))

        let bestMove = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(5))
        XCTAssertEqual(bestMove, "bestmove a2a3")
    }
}
