import ArasanEmbedded
import Darwin
import Foundation

@main
struct ArasanSmoke {
    static func main() {
        do {
            let arguments = CommandLine.arguments.dropFirst()
            let options = try SmokeOptions(arguments: Array(arguments))
            let runner = SmokeRunner(options: options)
            try runner.run()
        } catch SmokeError.help {
            print(SmokeRunner.usage)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

private struct SmokeOptions {
    var fen = "startpos"
    var depth = 1
    var movetime: Int?
    var nnueURL: URL?
    var openingBookURL: URL?
    var useOpeningBook = false
    var tablebaseDirectoryURL: URL?
    var useTablebases = false
    var tablebaseProbeDepth: Int?
    var syzygyUses50MoveRule = true

    init(arguments: [String]) throws {
        var depthWasProvided = false
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--fen":
                fen = try Self.value(after: option, in: arguments, index: &index)
            case "--depth":
                depth = try Int(Self.value(after: option, in: arguments, index: &index))
                    .requiredInteger(option)
                depthWasProvided = true
            case "--movetime":
                movetime = try Int(Self.value(after: option, in: arguments, index: &index))
                    .requiredInteger(option)
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
                tablebaseProbeDepth = try Int(Self.value(after: option, in: arguments, index: &index))
                    .requiredInteger(option)
            case "--ignore-50-move-rule":
                syzygyUses50MoveRule = false
            case "--help", "-h":
                throw SmokeError.help
            default:
                throw SmokeError.unknownOption(option)
            }
            index += 1
        }

        guard depth > 0 else { throw SmokeError.invalidValue("--depth must be greater than zero") }
        if let movetime, movetime <= 0 {
            throw SmokeError.invalidValue("--movetime must be greater than zero")
        }
        if depthWasProvided, movetime != nil {
            throw SmokeError.invalidValue("choose either --depth or --movetime")
        }
        guard isPlausiblePosition(fen) else {
            throw SmokeError.invalidValue("--fen must be startpos or a plausible single-line four/six-field FEN")
        }
    }

    var configuration: ArasanEngine.Configuration {
        .init(
            nnueURL: nnueURL ?? ArasanEngine.defaultNNUEURL,
            useOpeningBook: useOpeningBook,
            openingBookURL: openingBookURL,
            useTablebases: useTablebases,
            tablebaseDirectoryURL: tablebaseDirectoryURL,
            tablebaseProbeDepth: tablebaseProbeDepth,
            syzygyUses50MoveRule: syzygyUses50MoveRule
        )
    }

    private static func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw SmokeError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private final class SmokeRunner: @unchecked Sendable {
    private let options: SmokeOptions
    private let stream = LockedLineStream()
    private var engine: ArasanEngine?

    init(options: SmokeOptions) {
        self.options = options
    }

    func run() throws {
        do {
            let engine = ArasanEngine(configuration: options.configuration) { [stream] line in
                print(line)
                stream.append(line)
            }
            self.engine = engine
            try engine.start()
            _ = try stream.waitForLine(timeout: 5) { $0 == "uciok" }
            _ = try stream.waitForLine(timeout: 5) { $0 == "readyok" }

            if options.fen == "startpos" {
                engine.sendCommand("position startpos")
            } else {
                engine.sendCommand("position fen \(options.fen)")
            }

            if let movetime = options.movetime {
                engine.sendCommand("go movetime \(movetime)")
            } else {
                engine.sendCommand("go depth \(options.depth)")
            }

            let bestmove = try stream.waitForLine(timeout: 20) {
                $0 == "bestmove" || $0.hasPrefix("bestmove ")
            }
            guard parseBestmove(bestmove) != nil else {
                throw SmokeError.malformedBestmove(bestmove)
            }
            engine.stop()
        } catch {
            engine?.stop()
            throw error
        }
    }

    static let usage = """
    Usage:
      arasan-smoke [--fen FEN] [--depth N]
      arasan-smoke [--fen FEN] --movetime MS
      arasan-smoke --book /path/to/book.bin --depth N
      arasan-smoke --tablebases /path/to/syzygy --probe-depth N --fen FEN

    Options:
      --nnue PATH                 Override the bundled NNUE file.
      --use-book                  Enable Arasan opening book with its default path.
      --book PATH                 Enable Arasan opening book and set BookPath.
      --tablebases PATH           Enable Syzygy tablebases from a directory.
      --probe-depth N             Set SyzygyProbeDepth.
      --ignore-50-move-rule       Set SyzygyUse50MoveRule to false.
    """
}

private final class LockedLineStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [String] = []

    func append(_ line: String) {
        condition.lock()
        defer { condition.unlock() }
        lines.append(line)
        condition.broadcast()
    }

    func waitForLine(
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) throws -> String {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let line = lines.first(where: predicate) {
                return line
            }
            if Date() >= deadline {
                if let line = lines.first(where: predicate) {
                    return line
                }
                throw SmokeError.timeout
            }
            condition.wait(until: deadline)
        }
    }
}

private enum SmokeError: Error, LocalizedError {
    case help
    case missingValue(String)
    case unknownOption(String)
    case invalidInteger(String)
    case invalidValue(String)
    case timeout
    case malformedBestmove(String)

    var errorDescription: String? {
        switch self {
        case .help:
            nil
        case .missingValue(let option):
            "Missing value after \(option)."
        case .unknownOption(let option):
            "Unknown option: \(option)."
        case .invalidInteger(let option):
            "Expected an integer value for \(option)."
        case .invalidValue(let message):
            "Invalid option: \(message)."
        case .timeout:
            "Timed out waiting for Arasan output."
        case .malformedBestmove(let line):
            "Arasan returned a malformed bestmove line: \(line)"
        }
    }
}

private func parseBestmove(_ line: String) -> String? {
    let parts = line.split(separator: " ")
    guard (parts.count == 2 || parts.count == 4), parts[0] == "bestmove" else { return nil }
    let move = String(parts[1])
    guard isValidMoveToken(move) else {
        return nil
    }
    if parts.count == 4 {
        guard parts[2] == "ponder",
              isCoordinateMoveToken(move),
              isCoordinateMoveToken(String(parts[3])) else {
            return nil
        }
    }
    return move
}

private func isValidMoveToken(_ move: String) -> Bool {
    move.range(
        of: #"^(?:[a-h][1-8][a-h][1-8][nbrq]?|0000|\(none\))$"#,
        options: .regularExpression
    ) != nil
}

private func isCoordinateMoveToken(_ move: String) -> Bool {
    move.range(
        of: #"^[a-h][1-8][a-h][1-8][nbrq]?$"#,
        options: .regularExpression
    ) != nil
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

private extension Optional where Wrapped == Int {
    func requiredInteger(_ option: String) throws -> Int {
        guard let value = self else {
            throw SmokeError.invalidInteger(option)
        }
        return value
    }
}
