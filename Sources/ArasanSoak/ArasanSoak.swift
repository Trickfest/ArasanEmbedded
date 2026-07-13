import ArasanEmbedded
import Darwin
import Foundation

@main
struct ArasanSoak {
    static func main() async {
        do {
            let options = try SoakOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let positions: [ArasanSoakRunner.PositionSpec]
            if options.positionFiles.isEmpty {
                let bundledCorpus = Bundle.module.url(
                    forResource: "lichess_puzzles",
                    withExtension: "tsv"
                )
                positions = try loadPositions(from: [try bundledCorpus.requiredCorpusURL().path])
            } else {
                positions = try loadPositions(from: options.positionFiles)
            }
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
        } catch ExitCode.failure {
            Darwin.exit(EXIT_FAILURE)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

private struct SoakOptions {
    var positionFiles: [String] = []
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
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--positions":
                let value = try Self.value(after: option, in: arguments, index: &index)
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

    let maximumBytes = 10 * 1024 * 1024
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    if data.count > maximumBytes {
        throw SoakError.positionsFileTooLarge(path)
    }
    guard let contents = String(data: data, encoding: .utf8) else {
        throw SoakError.invalidPositionsFile(path)
    }

    let normalizedNewlines = contents
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalizedNewlines
        .split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .compactMap { index, rawLine -> PositionFileLine? in
            let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            return PositionFileLine(number: index + 1, text: text)
        }

    guard let firstLine = lines.first else {
        return []
    }

    if firstLine.text.contains("\t") || URL(fileURLWithPath: path).pathExtension.lowercased() == "tsv" {
        return try loadTSVPositions(from: lines, path: path)
    }

    return try lines.map { line in
        guard isPlausiblePosition(line.text) else {
            throw SoakError.invalidPosition(path: path, line: line.number)
        }
        return ArasanSoakRunner.PositionSpec(
            id: "\(URL(fileURLWithPath: path).lastPathComponent)#\(line.number)",
            fen: line.text
        )
    }
}

private struct PositionFileLine {
    let number: Int
    let text: String
}

private func loadTSVPositions(
    from lines: [PositionFileLine],
    path: String
) throws -> [ArasanSoakRunner.PositionSpec] {
    let headers = lines[0].text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard let fenIndex = headers.firstIndex(of: "fen") else {
        throw SoakError.invalidPositionsFile(path)
    }
    let idIndex = headers.firstIndex(of: "id")

    return try lines.dropFirst().map { line in
        let fields = line.text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == headers.count else {
            throw SoakError.invalidPositionsRow(path: path, line: line.number)
        }
        let id = idIndex.flatMap { $0 < fields.count ? fields[$0] : nil }
            ?? "\(URL(fileURLWithPath: path).lastPathComponent)#\(line.number)"
        let fen = fenIndex < fields.count ? fields[fenIndex] : ""
        guard isPlausiblePosition(fen) else {
            throw SoakError.invalidPosition(path: path, line: line.number)
        }
        return ArasanSoakRunner.PositionSpec(id: id, fen: fen)
    }
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
  --continue-on-timeout       Continue only after stop yields that search's terminal bestmove.
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
    case positionsFileTooLarge(String)
    case invalidPositionsFile(String)
    case invalidPositionsRow(path: String, line: Int)
    case invalidPosition(path: String, line: Int)

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
        case .positionsFileTooLarge(let path):
            "Positions file exceeds the 10 MiB safety limit: \(path)"
        case .invalidPositionsFile(let path):
            "Invalid positions file: \(path)"
        case .invalidPositionsRow(let path, let line):
            "Invalid column count in positions file \(path) at line \(line)."
        case .invalidPosition(let path, let line):
            "Invalid startpos/FEN value in positions file \(path) at line \(line)."
        }
    }
}

private enum ExitCode: Error {
    case failure
}

private extension Optional where Wrapped == URL {
    func requiredCorpusURL() throws -> URL {
        guard let self else { throw SoakError.noPositions }
        return self
    }
}

private func isPlausiblePosition(_ value: String) -> Bool {
    guard !value.contains("\0"), !value.contains("\r"), !value.contains("\n") else {
        return false
    }
    if value == "startpos" { return true }
    let fields = value.split(separator: " ").map(String.init)
    guard fields.count == 4 || fields.count == 6 else { return false }
    let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
    guard ranks.count == 8 else { return false }
    for rank in ranks {
        var count = 0
        for character in rank {
            if let ascii = character.asciiValue, (49...56).contains(ascii) {
                count += Int(ascii - 48)
            } else {
                guard "prnbqkPRNBQK".contains(character) else { return false }
                count += 1
            }
        }
        guard count == 8 else { return false }
    }
    guard fields[1] == "w" || fields[1] == "b" else { return false }
    guard fields[2] == "-" || fields[2].allSatisfy({ "KQkq".contains($0) }) else { return false }
    guard fields[3] == "-" || fields[3].range(
        of: #"^[a-h][36]$"#,
        options: .regularExpression
    ) != nil else { return false }
    if fields.count == 6 {
        guard let halfmove = Int(fields[4]), halfmove >= 0,
              let fullmove = Int(fields[5]), fullmove >= 1 else { return false }
    }
    return true
}
