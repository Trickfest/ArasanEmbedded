import Foundation

actor AssetTestLineStream {
    private var lines: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var lineCount: Int {
        lines.count
    }

    func append(_ line: String) {
        lines.append(line)
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
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
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                while true {
                    if let line = await self.matchingLine(containing: needle, prefix: prefix, after: startIndex) {
                        return line
                    }
                    await self.waitForNewLine()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AssetTestTimeoutError()
            }
            let line = try await group.next()!
            group.cancelAll()
            return line
        }
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

    private func waitForNewLine() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct AssetTestTimeoutError: Error {}
