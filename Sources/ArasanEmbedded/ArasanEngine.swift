import CArasanEmbedded
import Foundation

/// A Swift-friendly wrapper around an embedded Arasan UCI engine.
///
/// `ArasanEngine` owns one in-process Arasan engine loop and forwards UCI
/// output through the line handler supplied at initialization. The wrapper keeps
/// policy narrow: it starts and stops Arasan, applies resource-related UCI
/// options, and sends caller-provided UCI commands. It does not parse UCI output
/// into chess models or own game state.
public final class ArasanEngine: @unchecked Sendable {
    public typealias LineHandler = @Sendable (String) -> Void

    private let core: AEEngine
    private let configuration: Configuration

    /// Creates an embedded Arasan engine.
    ///
    /// - Parameters:
    ///   - configuration: Resource and option configuration to apply after the
    ///     engine enters UCI mode.
    ///   - lineHandler: Called for each UCI output line on Arasan's engine
    ///     thread. Dispatch to the main actor before updating UI.
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
        guard core.start() else {
            throw Error.startFailed
        }

        sendCommand("uci")
        for command in configuration.uciOptionCommands {
            sendCommand(command)
        }
        sendCommand("isready")
    }

    /// Sends one UCI command line to Arasan.
    public func sendCommand(_ command: String) {
        core.sendCommand(command)
    }

    /// Requests a normal UCI shutdown and tears down the engine loop.
    public func stop() {
        core.stop()
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

    enum Error: Swift.Error, Equatable, LocalizedError {
        case startFailed
        case missingNNUE(URL)
        case missingOpeningBook(URL)
        case missingTablebaseDirectory(URL)
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

        if useOpeningBook, let openingBookURL, !openingBookURL.isExistingFile {
            throw ArasanEngine.Error.missingOpeningBook(openingBookURL)
        }

        if useTablebases {
            guard let tablebaseDirectoryURL, tablebaseDirectoryURL.isExistingDirectory else {
                throw ArasanEngine.Error.missingTablebaseDirectory(
                    tablebaseDirectoryURL ?? URL(fileURLWithPath: "")
                )
            }
        }

        if let tablebaseProbeDepth, !(0...64).contains(tablebaseProbeDepth) {
            throw ArasanEngine.Error.invalidTablebaseProbeDepth(tablebaseProbeDepth)
        }
    }
}

private extension URL {
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
}
