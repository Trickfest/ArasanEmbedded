import Foundation

actor EngineLineStream {
    private var lines: [String] = []

    var lineCount: Int {
        lines.count
    }

    func append(_ line: String) {
        lines.append(line)
    }

    func allLines() -> [String] {
        lines
    }

    func waitForLine(
        containing needle: String,
        after startIndex: Int = 0,
        timeout: Duration
    ) async throws -> String {
        try await waitForLine(containing: needle, prefix: nil, after: startIndex, timeout: timeout)
    }

    func waitForLine(
        prefix: String,
        after startIndex: Int = 0,
        timeout: Duration
    ) async throws -> String {
        try await waitForLine(containing: nil, prefix: prefix, after: startIndex, timeout: timeout)
    }

    private func waitForLine(
        containing needle: String?,
        prefix: String?,
        after startIndex: Int,
        timeout: Duration
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if let line = matchingLine(containing: needle, prefix: prefix, after: startIndex) {
                return line
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw EngineLineStreamTimeoutError()
    }

    private func matchingLine(containing needle: String?, prefix: String?, after startIndex: Int) -> String? {
        guard startIndex <= lines.count else {
            return nil
        }

        return lines[startIndex...].first { line in
            if let needle {
                return line.contains(needle)
            }
            if let prefix {
                return line.hasPrefix(prefix)
            }
            return false
        }
    }

}

private struct EngineLineStreamTimeoutError: Error {}
