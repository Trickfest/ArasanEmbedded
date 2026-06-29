@testable import ArasanEmbedded
import XCTest

final class ArasanExternalAssetIntegrationTests: XCTestCase {
    func testDownloadedKQvKSyzygyFixtureProducesTablebaseHits() async throws {
        guard ProcessInfo.processInfo.environment["ARASAN_RUN_EXTERNAL_ASSET_TESTS"] == "1" else {
            throw XCTSkip("Set ARASAN_RUN_EXTERNAL_ASSET_TESTS=1 and run Scripts/test-external-assets.sh.")
        }

        let tablebaseURL = syzygyFixtureDirectory()
        try assertTablebaseFixtureExists(in: tablebaseURL)

        let stream = AssetTestLineStream()
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
        XCTAssertGreaterThan(Self.tablebaseHits(in: info), 0, "Expected Syzygy tablebase hits in: \(info)")

        let bestMove = try await stream.waitForLine(prefix: "bestmove", after: startIndex, timeout: .seconds(5))
        XCTAssertTrue(bestMove.hasPrefix("bestmove "))
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
                XCTFail(
                    "Missing \(file). Run Scripts/test-external-assets.sh to download and verify Syzygy fixtures."
                )
                throw MissingSyzygyFixtureError()
            }
        }
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
