import CArasanEmbedded
import Foundation

/// A Swift-friendly wrapper around an embedded Arasan UCI engine.
///
/// `ArasanEngine` owns one in-process Arasan engine loop and forwards UCI
/// output through the line handler supplied at initialization. The wrapper keeps
/// policy narrow: it starts and stops Arasan, applies resource-related UCI
/// options, and sends caller-provided UCI commands. It does not parse UCI output
/// into chess models or own game state.
///
/// Arasan uses process-global state and standard streams, so only one engine may
/// be active in a process at a time. Output is delivered in order on a
/// wrapper-owned serial background queue. `stop()` blocks until native teardown
/// completes, is safe from the line handler, and may be called repeatedly. A
/// stopped instance may be started again.
public final class ArasanEngine: @unchecked Sendable {
    public typealias LineHandler = @Sendable (String) -> Void

    private let core: AEEngine
    private let configuration: Configuration

    /// Creates an embedded Arasan engine.
    ///
    /// - Parameters:
    ///   - configuration: Resource and option configuration to apply after the
    ///     engine enters UCI mode.
    ///   - lineHandler: Called for each UCI output line in order on a
    ///     wrapper-owned serial background queue. Dispatch to the main actor
    ///     before updating UI, and use a weak capture when retaining the engine
    ///     from an object owned by this handler.
    public init(
        configuration: Configuration = .default,
        lineHandler: @escaping LineHandler
    ) {
        self.configuration = configuration
        self.core = AEEngine { line in
            lineHandler(line)
        }
    }

    deinit {
        stop()
    }

    /// Indicates whether this wrapper currently has an engine loop running.
    public var isRunning: Bool {
        core.isRunning
    }

    /// Starts Arasan and applies this instance's configuration.
    ///
    /// `start()` sends `uci`, the configured resource options, and `isready` in
    /// order. Consumers can wait for `uciok` and `readyok` in the line handler
    /// before starting searches.
    public func start() throws {
        try configuration.validate()
        let startupCommands = ["uci"] + configuration.uciOptionCommands + ["isready"]
        guard core.startEngine(commands: startupCommands) else {
            throw Error.startFailed
        }
    }

    /// Sends one trusted UCI command line to Arasan.
    ///
    /// One optional trailing LF or CRLF is accepted. Empty commands are
    /// ignored; embedded NULs, multiline input, commands larger than 1 MiB, and
    /// runtime NNUE-file changes are rejected through an `info string
    /// ArasanEmbedded error` callback. Create a fresh configured engine to use a
    /// different NNUE file. The embedded wrapper also rejects `Threads`
    /// changes and keeps Arasan at one search thread for safe native teardown.
    /// Do not pass untrusted user text directly to UCI.
    public func sendCommand(_ command: String) {
        core.sendCommand(command)
    }

    /// Requests a normal UCI shutdown and tears down the engine loop.
    public func stop() {
        core.stop()
    }

    /// Native engine-thread stack size, exposed internally for regression
    /// coverage of Arasan's 4 MiB minimum.
    var engineThreadStackSize: Int {
        Int(core.engineThreadStackSize)
    }
}

public extension ArasanEngine {
    /// Resource and UCI-option configuration applied when an engine starts.
    struct Configuration: Equatable, Sendable {
        /// Path to the NNUE network Arasan should load.
        public var nnueURL: URL
        /// Enables Arasan's opening book support.
        public var useOpeningBook: Bool
        /// Optional path to a caller-provided Arasan `book.bin` file.
        public var openingBookURL: URL?
        /// Enables Syzygy tablebase probing.
        public var useTablebases: Bool
        /// Directory containing caller-provided Syzygy tablebase files.
        public var tablebaseDirectoryURL: URL?
        /// Arasan's `SyzygyProbeDepth` UCI option.
        public var tablebaseProbeDepth: Int?
        /// Arasan's `SyzygyUse50MoveRule` UCI option.
        public var syzygyUses50MoveRule: Bool

        public init(
            nnueURL: URL = ArasanEngine.defaultNNUEURL,
            useOpeningBook: Bool = false,
            openingBookURL: URL? = nil,
            useTablebases: Bool = false,
            tablebaseDirectoryURL: URL? = nil,
            tablebaseProbeDepth: Int? = nil,
            syzygyUses50MoveRule: Bool = true
        ) {
            self.nnueURL = nnueURL
            self.useOpeningBook = useOpeningBook
            self.openingBookURL = openingBookURL
            self.useTablebases = useTablebases
            self.tablebaseDirectoryURL = tablebaseDirectoryURL
            self.tablebaseProbeDepth = tablebaseProbeDepth
            self.syzygyUses50MoveRule = syzygyUses50MoveRule
        }

        /// The default configuration: bundled NNUE, opening book disabled, and
        /// tablebases disabled.
        public static var `default`: Self {
            Self()
        }
    }

    /// The bundled Arasan NNUE network URL.
    static var defaultNNUEURL: URL {
        guard let url = Bundle.module.url(
            forResource: "arasanv8-20260622",
            withExtension: "nnue"
        ) else {
            preconditionFailure("Bundled Arasan NNUE resource is missing.")
        }
        return url
    }

    /// Errors detected before or while starting the embedded engine.
    enum Error: Swift.Error, Equatable, LocalizedError {
        /// The native process-wide engine slot or thread could not be started.
        case startFailed
        /// The configured NNUE file does not exist.
        case missingNNUE(URL)
        /// Opening-book mode named an explicit file that does not exist.
        case missingOpeningBook(URL)
        /// The configured tablebase directory does not exist.
        case missingTablebaseDirectory(URL)
        /// The configured Syzygy probe depth is outside Arasan's range.
        case invalidTablebaseProbeDepth(Int)

        public var errorDescription: String? {
            switch self {
            case .startFailed:
                "Arasan could not be started."
            case .missingNNUE(let url):
                "The configured Arasan NNUE file does not exist: \(url.path)"
            case .missingOpeningBook(let url):
                "Opening book was enabled, but no book file exists at: \(url.path)"
            case .missingTablebaseDirectory(let url):
                "Tablebases were enabled, but no tablebase directory exists at: \(url.path)"
            case .invalidTablebaseProbeDepth(let depth):
                "Tablebase probe depth must be between 0 and 64. Received \(depth)."
            }
        }
    }
}

extension ArasanEngine.Configuration {
    var uciOptionCommands: [String] {
        var commands: [String] = [
            "setoption name NNUE file value \(nnueURL.path)",
        ]

        if let openingBookURL {
            commands.append("setoption name BookPath value \(openingBookURL.path)")
        }
        commands.append("setoption name OwnBook value \(useOpeningBook ? "true" : "false")")

        if let tablebaseDirectoryURL {
            commands.append("setoption name SyzygyPath value \(tablebaseDirectoryURL.path)")
        }
        if let tablebaseProbeDepth {
            commands.append("setoption name SyzygyProbeDepth value \(tablebaseProbeDepth)")
        }
        commands.append("setoption name SyzygyUse50MoveRule value \(syzygyUses50MoveRule ? "true" : "false")")
        commands.append("setoption name Use tablebases value \(useTablebases ? "true" : "false")")

        return commands
    }

    func validate() throws {
        guard nnueURL.isExistingFile else {
            throw ArasanEngine.Error.missingNNUE(nnueURL)
        }
        guard nnueURL.hasSafeUCIPath else {
            throw ArasanConfigurationValidationError.invalidResourcePath(nnueURL)
        }
        guard nnueURL.isCompatibleArasanNNUE else {
            throw ArasanConfigurationValidationError.invalidNNUE(nnueURL)
        }

        if let openingBookURL {
            guard openingBookURL.hasSafeUCIPath else {
                throw ArasanConfigurationValidationError.invalidResourcePath(openingBookURL)
            }
            if useOpeningBook, !openingBookURL.isExistingFile {
                throw ArasanEngine.Error.missingOpeningBook(openingBookURL)
            }
        }

        if useTablebases {
            guard let tablebaseDirectoryURL else {
                throw ArasanConfigurationValidationError.missingTablebaseDirectoryURL
            }
            guard tablebaseDirectoryURL.hasSafeUCIPath else {
                throw ArasanConfigurationValidationError.invalidResourcePath(tablebaseDirectoryURL)
            }
            guard tablebaseDirectoryURL.isExistingDirectory else {
                throw ArasanEngine.Error.missingTablebaseDirectory(tablebaseDirectoryURL)
            }
        } else if let tablebaseDirectoryURL, !tablebaseDirectoryURL.hasSafeUCIPath {
            throw ArasanConfigurationValidationError.invalidResourcePath(tablebaseDirectoryURL)
        }

        if let tablebaseProbeDepth, !(0...64).contains(tablebaseProbeDepth) {
            throw ArasanEngine.Error.invalidTablebaseProbeDepth(tablebaseProbeDepth)
        }
    }
}

enum ArasanConfigurationValidationError: Swift.Error, Equatable, LocalizedError {
    case invalidNNUE(URL)
    case missingTablebaseDirectoryURL
    case invalidResourcePath(URL)

    var errorDescription: String? {
        switch self {
        case .invalidNNUE(let url):
            "The configured file is not a compatible Arasan NNUE network: \(url.path)"
        case .missingTablebaseDirectoryURL:
            "Tablebases were enabled, but no tablebase directory was provided."
        case .invalidResourcePath(let url):
            "The configured resource path cannot be represented as one UCI command: \(url.path)"
        }
    }
}

private extension URL {
    static let arasanNNUEByteCount = 25_024_576
    static let arasanNNUEHeader = Data([0x41, 0x52, 0x41, 0x08])

    var isExistingFile: Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    var isExistingDirectory: Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    var hasSafeUCIPath: Bool {
        !path.isEmpty
            && path.utf8.count <= 1024 * 1024
            && !path.contains("\0")
            && !path.contains("\r")
            && !path.contains("\n")
            && path.last?.isWhitespace == false
    }

    var isCompatibleArasanNNUE: Bool {
        guard let handle = try? FileHandle(forReadingFrom: self) else {
            return false
        }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size == UInt64(Self.arasanNNUEByteCount) else {
            return false
        }
        do {
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: Self.arasanNNUEHeader.count)
            return header == Self.arasanNNUEHeader
        } catch {
            return false
        }
    }
}
