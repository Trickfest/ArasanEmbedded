import ArasanEmbedded
import Foundation

@main
struct ArasanSoak {
    static func main() async throws {
        do {
            let options = try SoakOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let positions = try loadPositions(from: options.positionFiles)
            let runner = ArasanSoakRunner(configuration: options.configuration(positions: positions))
            let logOutput = options.logOutput

            let summary = await runner.run { event in
                switch event {
                case .started(let configuration):
                    print("Starting soak test (positions: \(configuration.positions.count))")
                case .engineOutput(let line):
                    if logOutput {
                        print("uci> \(line)")
                    }
                case .iterationStarted(let index, let position):
                    print("[#\(index + 1)] \(describe(position))")
                case .iterationCompleted(let index, _, let bestmove, let elapsed):
                    print("[#\(index + 1)] bestmove \(bestmove) in \(formatDuration(elapsed))")
                case .timeout(let index, _, let elapsed):
                    fputs("[#\(index + 1)] timeout after \(formatDuration(elapsed))\n", stderr)
                case .error(let message):
                    fputs("error: \(message)\n", stderr)
                case .stopped:
                    print("Stopped")
                case .finished:
                    break
                }
            }

            print("Completed \(summary.iterationsCompleted)/\(summary.iterationsAttempted) iterations")
            print("Timeouts: \(summary.timeouts), Errors: \(summary.errors)")
            print("Elapsed: \(formatDuration(summary.elapsed))")

            if summary.errors > 0 || summary.timeouts > 0 {
                throw ExitCode.failure
            }
        } catch SoakError.help {
            print(usage)
        }
    }
}

private struct SoakOptions {
    var positionFiles: [String] = ["Resources/Soak/lichess_puzzles.tsv"]
    var depth: Int?
    var nodes: Int?
    var movetime: Int?
    var iterations: Int?
    var timeout: TimeInterval = 30
    var stopTimeout: TimeInterval = 5
    var handshakeTimeout: TimeInterval = 10
    var delayMilliseconds: Int?
    var readyEach = false
    var logOutput = false
    var continueOnTimeout = false
    var nnueURL: URL?
    var openingBookURL: URL?
    var useOpeningBook = false
    var tablebaseDirectoryURL: URL?
    var useTablebases = false
    var tablebaseProbeDepth: Int?
    var syzygyUses50MoveRule = true

    init(arguments: [String]) throws {
        var explicitPositions = false
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--positions":
                let value = try Self.value(after: option, in: arguments, index: &index)
                if !explicitPositions {
                    positionFiles.removeAll()
                    explicitPositions = true
                }
                positionFiles.append(value)
            case "--depth":
                depth = try Self.integer(after: option, in: arguments, index: &index)
            case "--nodes":
                nodes = try Self.integer(after: option, in: arguments, index: &index)
            case "--movetime":
                movetime = try Self.integer(after: option, in: arguments, index: &index)
            case "--iterations":
                iterations = try Self.integer(after: option, in: arguments, index: &index)
            case "--timeout":
                timeout = try Self.timeInterval(after: option, in: arguments, index: &index)
            case "--stop-timeout":
                stopTimeout = try Self.timeInterval(after: option, in: arguments, index: &index)
            case "--handshake-timeout":
                handshakeTimeout = try Self.timeInterval(after: option, in: arguments, index: &index)
            case "--delay-ms":
                delayMilliseconds = try Self.integer(after: option, in: arguments, index: &index)
            case "--ready-each":
                readyEach = true
            case "--log-output":
                logOutput = true
            case "--continue-on-timeout":
                continueOnTimeout = true
            case "--nnue":
                nnueURL = URL(fileURLWithPath: try Self.value(after: option, in: arguments, index: &index))
            case "--book":
                openingBookURL = URL(fileURLWithPath: try Self.value(after: option, in: arguments, index: &index))
                useOpeningBook = true
            case "--use-book":
                useOpeningBook = true
            case "--tablebases":
                tablebaseDirectoryURL = URL(fileURLWithPath: try Self.value(after: option, in: arguments, index: &index))
                useTablebases = true
            case "--probe-depth":
                tablebaseProbeDepth = try Self.integer(after: option, in: arguments, index: &index)
            case "--ignore-50-move-rule":
                syzygyUses50MoveRule = false
            case "--help", "-h":
                throw SoakError.help
            default:
                throw SoakError.unknownOption(option)
            }
            index += 1
        }

        let providedLimits = [depth != nil, nodes != nil, movetime != nil].filter { $0 }.count
        if providedLimits > 1 {
            throw SoakError.invalidSearchLimit
        }
    }

    func configuration(positions: [ArasanSoakRunner.PositionSpec]) -> ArasanSoakRunner.Configuration {
        let searchLimit: ArasanSoakRunner.SearchLimit
        if let depth {
            searchLimit = .depth(depth)
        } else if let nodes {
            searchLimit = .nodes(nodes)
        } else if let movetime {
            searchLimit = .moveTimeMillis(movetime)
        } else {
            searchLimit = .depth(8)
        }

        return ArasanSoakRunner.Configuration(
            positions: positions,
            engineConfiguration: ArasanEngine.Configuration(
                nnueURL: nnueURL ?? ArasanEngine.defaultNNUEURL,
                useOpeningBook: useOpeningBook,
                openingBookURL: openingBookURL,
                useTablebases: useTablebases,
                tablebaseDirectoryURL: tablebaseDirectoryURL,
                tablebaseProbeDepth: tablebaseProbeDepth,
                syzygyUses50MoveRule: syzygyUses50MoveRule
            ),
            searchLimit: searchLimit,
            maxIterations: iterations,
            perMoveTimeout: timeout,
            stopTimeout: stopTimeout,
            handshakeTimeout: handshakeTimeout,
            delayBetweenIterations: delayMilliseconds.map { TimeInterval($0) / 1_000 },
            readyCheckEveryIteration: readyEach,
            stopOnTimeoutFailure: !continueOnTimeout
        )
    }

    private static func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw SoakError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func integer(after option: String, in arguments: [String], index: inout Int) throws -> Int {
        guard let value = Int(try value(after: option, in: arguments, index: &index)) else {
            throw SoakError.invalidInteger(option)
        }
        return value
    }

    private static func timeInterval(after option: String, in arguments: [String], index: inout Int) throws -> TimeInterval {
        guard let value = TimeInterval(try value(after: option, in: arguments, index: &index)) else {
            throw SoakError.invalidInteger(option)
        }
        return value
    }
}

private func loadPositions(from paths: [String]) throws -> [ArasanSoakRunner.PositionSpec] {
    var positions: [ArasanSoakRunner.PositionSpec] = []
    for path in paths {
        positions.append(contentsOf: try loadPositions(from: resolvePath(path)))
    }
    guard !positions.isEmpty else {
        throw SoakError.noPositions
    }
    return positions
}

private func loadPositions(from path: String) throws -> [ArasanSoakRunner.PositionSpec] {
    guard FileManager.default.fileExists(atPath: path) else {
        throw SoakError.positionsFileNotFound(path)
    }

    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let lines = contents
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

    guard let firstLine = lines.first else {
        return []
    }

    if firstLine.contains("\t") && firstLine.split(separator: "\t").contains("fen") {
        return try loadTSVPositions(from: lines, path: path)
    }

    return lines.enumerated().map { index, line in
        ArasanSoakRunner.PositionSpec(id: "\(URL(fileURLWithPath: path).lastPathComponent)#\(index + 1)", fen: line)
    }
}

private func loadTSVPositions(from lines: [String], path: String) throws -> [ArasanSoakRunner.PositionSpec] {
    let headers = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard let fenIndex = headers.firstIndex(of: "fen") else {
        throw SoakError.invalidPositionsFile(path)
    }
    let idIndex = headers.firstIndex(of: "id")

    return lines.dropFirst().enumerated().map { rowIndex, line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let id = idIndex.flatMap { $0 < fields.count ? fields[$0] : nil }
            ?? "\(URL(fileURLWithPath: path).lastPathComponent)#\(rowIndex + 1)"
        let fen = fenIndex < fields.count ? fields[fenIndex] : ""
        return ArasanSoakRunner.PositionSpec(id: id, fen: fen)
    }.filter { !$0.fen.isEmpty }
}

private func resolvePath(_ path: String) -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    if expandedPath.hasPrefix("/") {
        return expandedPath
    }

    let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expandedPath)
        .path
    if FileManager.default.fileExists(atPath: cwdPath) {
        return cwdPath
    }

    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let repoPath = repoRoot.appendingPathComponent(expandedPath).path
    if FileManager.default.fileExists(atPath: repoPath) {
        return repoPath
    }

    return cwdPath
}

private func describe(_ position: ArasanSoakRunner.PositionSpec) -> String {
    let prefix = position.id.isEmpty ? "" : "\(position.id): "
    return "\(prefix)\(position.fen)"
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    String(format: "%.3fs", seconds)
}

private let usage = """
Usage:
  arasan-soak [--positions PATH] [--iterations N] [--depth N]
  arasan-soak [--positions PATH] [--iterations N] --movetime MS
  arasan-soak [--positions PATH] [--iterations N] --nodes N

Options:
  --positions PATH            TSV corpus or plain FEN file. Can be repeated.
  --iterations N              Maximum number of iterations. Omit to run forever.
  --depth N                   Search depth. Defaults to 8.
  --movetime MS               Search movetime in milliseconds.
  --nodes N                   Search node limit.
  --timeout SECONDS           Per-position bestmove timeout. Defaults to 30.
  --stop-timeout SECONDS      Timeout after sending stop. Defaults to 5.
  --handshake-timeout SECONDS Timeout waiting for uciok/readyok. Defaults to 10.
  --delay-ms MS               Delay between iterations.
  --ready-each                Send isready before each iteration.
  --continue-on-timeout       Continue after a timeout instead of failing fast.
  --log-output                Print all engine output lines.
  --nnue PATH                 Override the bundled NNUE file.
  --use-book                  Enable Arasan opening book with its default path.
  --book PATH                 Enable Arasan opening book and set BookPath.
  --tablebases PATH           Enable Syzygy tablebases from a directory.
  --probe-depth N             Set SyzygyProbeDepth.
  --ignore-50-move-rule       Set SyzygyUse50MoveRule to false.
"""

private enum SoakError: Error, LocalizedError {
    case help
    case missingValue(String)
    case unknownOption(String)
    case invalidInteger(String)
    case invalidSearchLimit
    case noPositions
    case positionsFileNotFound(String)
    case invalidPositionsFile(String)

    var errorDescription: String? {
        switch self {
        case .help:
            nil
        case .missingValue(let option):
            "Missing value after \(option)."
        case .unknownOption(let option):
            "Unknown option: \(option)."
        case .invalidInteger(let option):
            "Expected a numeric value for \(option)."
        case .invalidSearchLimit:
            "Choose only one of --depth, --nodes, or --movetime."
        case .noPositions:
            "No positions were loaded."
        case .positionsFileNotFound(let path):
            "Positions file not found: \(path)"
        case .invalidPositionsFile(let path):
            "Invalid positions file: \(path)"
        }
    }
}

private enum ExitCode: Error {
    case failure
}
