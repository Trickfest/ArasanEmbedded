import Foundation
import Testing
@testable import ArasanEmbedded

@Suite("Configuration")
struct ArasanConfigurationTests {
    @Test
    func defaultConfigurationUsesBundledNNUE() {
        let configuration = ArasanEngine.Configuration.default

        #expect(FileManager.default.fileExists(atPath: configuration.nnueURL.path))
        #expect(!configuration.useOpeningBook)
        #expect(!configuration.useTablebases)
        #expect(configuration.uciOptionCommands.contains("setoption name OwnBook value false"))
        #expect(configuration.uciOptionCommands.contains("setoption name Use tablebases value false"))
    }

    @Test
    func openingBookConfigurationBuildsExpectedUCIOptions() {
        let url = URL(fileURLWithPath: "/tmp/book.bin")
        let configuration = ArasanEngine.Configuration(useOpeningBook: true, openingBookURL: url)

        #expect(configuration.uciOptionCommands.contains("setoption name BookPath value /tmp/book.bin"))
        #expect(configuration.uciOptionCommands.contains("setoption name OwnBook value true"))
    }

    @Test
    func tablebaseConfigurationBuildsExpectedUCIOptions() {
        let url = URL(fileURLWithPath: "/tmp/syzygy")
        let configuration = ArasanEngine.Configuration(
            useTablebases: true,
            tablebaseDirectoryURL: url,
            tablebaseProbeDepth: 4,
            syzygyUses50MoveRule: false
        )

        #expect(configuration.uciOptionCommands.contains("setoption name SyzygyPath value /tmp/syzygy"))
        #expect(configuration.uciOptionCommands.contains("setoption name SyzygyProbeDepth value 4"))
        #expect(configuration.uciOptionCommands.contains("setoption name SyzygyUse50MoveRule value false"))
        #expect(configuration.uciOptionCommands.contains("setoption name Use tablebases value true"))
    }

    @Test
    func missingNNUEIsRejectedBeforeEngineStart() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist.nnue")
        let configuration = ArasanEngine.Configuration(nnueURL: url)

        expectValidationError(ArasanEngine.Error.missingNNUE(url)) {
            try configuration.validate()
        }
    }

    @Test
    func incompatibleNNUEIsRejectedBeforeEngineStart() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "invalid-\(UUID().uuidString).nnue")
        try Data([0x41, 0x52, 0x41, 0x08]).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = ArasanEngine.Configuration(nnueURL: url)
        expectValidationError(ArasanConfigurationValidationError.invalidNNUE(url)) {
            try configuration.validate()
        }
    }

    @Test
    func missingOpeningBookIsRejectedWhenBookIsEnabled() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-book.bin")
        let configuration = ArasanEngine.Configuration(useOpeningBook: true, openingBookURL: url)

        expectValidationError(ArasanEngine.Error.missingOpeningBook(url)) {
            try configuration.validate()
        }
    }

    @Test
    func missingTablebaseDirectoryIsRejectedWhenTablebasesAreEnabled() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-syzygy")
        let configuration = ArasanEngine.Configuration(useTablebases: true, tablebaseDirectoryURL: url)

        expectValidationError(ArasanEngine.Error.missingTablebaseDirectory(url)) {
            try configuration.validate()
        }
    }

    @Test
    func missingTablebaseDirectoryURLIsReportedExplicitly() {
        let configuration = ArasanEngine.Configuration(useTablebases: true)

        expectValidationError(ArasanConfigurationValidationError.missingTablebaseDirectoryURL) {
            try configuration.validate()
        }
    }

    @Test
    func multilineResourcePathIsRejected() {
        let url = URL(fileURLWithPath: "/tmp/book.bin\nsetoption name OwnBook value true")
        let configuration = ArasanEngine.Configuration(openingBookURL: url)

        expectValidationError(ArasanConfigurationValidationError.invalidResourcePath(url)) {
            try configuration.validate()
        }
    }

    @Test
    func trailingWhitespaceResourcePathIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "book-(UUID().uuidString).bin ")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = ArasanEngine.Configuration(openingBookURL: url)
        expectValidationError(ArasanConfigurationValidationError.invalidResourcePath(url)) {
            try configuration.validate()
        }
    }

    @Test
    func invalidTablebaseProbeDepthIsRejected() {
        let configuration = ArasanEngine.Configuration(tablebaseProbeDepth: 65)

        expectValidationError(ArasanEngine.Error.invalidTablebaseProbeDepth(65)) {
            try configuration.validate()
        }
    }

    private func expectValidationError<E: Error & Equatable>(
        _ expectedError: E,
        performing operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected \(expectedError), but validation succeeded.")
        } catch {
            #expect(error as? E == expectedError)
        }
    }
}
