import Foundation

/// Synchronous ordered capture for a native serial callback. Using one
/// unstructured Task per line can reorder protocol output before tests inspect
/// their line-count boundaries.
final class EngineLineStream: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var lineCount: Int {
        lock.withLock { lines.count }
    }

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
        }
    }

    func allLines() -> [String] {
        lock.withLock { lines }
    }

    func count(matching predicate: (String) -> Bool) -> Int {
        lock.withLock { lines.count(where: predicate) }
    }

    func waitForCount(
        _ expectedCount: Int,
        after startIndex: Int = 0,
        timeout: Duration,
        matching predicate: @escaping @Sendable (String) -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if matchingCount(after: startIndex, predicate: predicate) >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if matchingCount(after: startIndex, predicate: predicate) >= expectedCount {
            return
        }
        throw EngineLineStreamTimeoutError()
    }

    func waitForLine(
        containing needle: String,
        after startIndex: Int = 0,
        timeout: Duration
    ) async throws -> String {
        try await waitForLine(after: startIndex, timeout: timeout) {
            $0.contains(needle)
        }
    }

    func waitForLine(
        prefix: String,
        after startIndex: Int = 0,
        timeout: Duration
    ) async throws -> String {
        try await waitForLine(after: startIndex, timeout: timeout) {
            $0.hasPrefix(prefix)
        }
    }

    func waitForLine(
        after startIndex: Int = 0,
        timeout: Duration,
        matching predicate: @escaping @Sendable (String) -> Bool
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if let line = matchingLine(after: startIndex, predicate: predicate) {
                return line
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Do one final observation at the boundary so a line appended exactly
        // as the deadline expires is not reported as a timeout.
        if let line = matchingLine(after: startIndex, predicate: predicate) {
            return line
        }
        throw EngineLineStreamTimeoutError()
    }

    private func matchingLine(
        after startIndex: Int,
        predicate: (String) -> Bool
    ) -> String? {
        lock.withLock {
            guard startIndex <= lines.count else { return nil }
            return lines[startIndex...].first(where: predicate)
        }
    }

    private func matchingCount(
        after startIndex: Int,
        predicate: (String) -> Bool
    ) -> Int {
        lock.withLock {
            guard startIndex <= lines.count else { return 0 }
            return lines[startIndex...].count(where: predicate)
        }
    }
}

private struct EngineLineStreamTimeoutError: Error {}
