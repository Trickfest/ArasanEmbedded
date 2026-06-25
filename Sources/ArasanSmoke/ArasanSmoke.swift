import ArasanEmbedded
import Foundation

@main
struct ArasanSmoke {
    static func main() throws {
        do {
            let arguments = CommandLine.arguments.dropFirst()
            let options = try SmokeOptions(arguments: Array(arguments))
            let runner = SmokeRunner(options: options)
            try runner.run()
        } catch SmokeError.help {
            print(SmokeRunner.usage)
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
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--fen":
                fen = try Self.value(after: option, in: arguments, index: &index)
            case "--depth":
                depth = try Int(Self.value(after: option, in: arguments, index: &index))
                    .requiredInteger(option)
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
            _ = try stream.waitForLine(containing: "uciok", timeout: 5)
            _ = try stream.waitForLine(containing: "readyok", timeout: 5)

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

            _ = try stream.waitForLine(prefix: "bestmove", timeout: 20)
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
        containing needle: String? = nil,
        prefix: String? = nil,
        timeout: TimeInterval
    ) throws -> String {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let line = matchingLine(containing: needle, prefix: prefix) {
                return line
            }
            if Date() >= deadline {
                throw SmokeError.timeout
            }
            condition.wait(until: deadline)
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
}

private enum SmokeError: Error, LocalizedError {
    case help
    case missingValue(String)
    case unknownOption(String)
    case invalidInteger(String)
    case timeout

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
        case .timeout:
            "Timed out waiting for Arasan output."
        }
    }
}

private extension Optional where Wrapped == Int {
    func requiredInteger(_ option: String) throws -> Int {
        guard let value = self else {
            throw SmokeError.invalidInteger(option)
        }
        return value
    }
}
