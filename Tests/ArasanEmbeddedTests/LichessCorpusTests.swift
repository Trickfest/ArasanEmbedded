import Foundation
import Testing
@testable import ArasanEmbedded

@Suite("Lichess Corpus")
struct LichessCorpusTests {
    @Test
    func lichessPuzzleCorpusHasRequiredCoverage() throws {
        let puzzles = try LichessPuzzleCorpus.load()

        #expect(puzzles.count == 36)
        #expect(Set(puzzles.map(\.id)).count == puzzles.count)
        #expect(puzzles.count(where: { $0.themes.contains("mateIn1") }) >= 5)
        #expect(puzzles.count(where: { $0.themes.contains("mateIn2") }) >= 8)
        #expect(puzzles.count(where: { $0.themes.contains("fork") }) >= 5)
        #expect(puzzles.count(where: { $0.themes.contains("hangingPiece") }) >= 5)
        #expect(puzzles.count(where: { $0.themes.contains("endgame") }) >= 10)
        #expect(puzzles.count(where: { $0.themes.contains("promotion") }) >= 10)

        for puzzle in puzzles {
            #expect(!puzzle.id.isEmpty)
            #expect(!puzzle.sourceFEN.isEmpty)
            #expect(!puzzle.firstMove.isEmpty)
            #expect(!puzzle.fen.isEmpty)
            #expect(!puzzle.expectedMove.isEmpty)
            #expect(!puzzle.allowedMoves.isEmpty)
            #expect(puzzle.allowedMoves.contains(puzzle.expectedMove))
            #expect(puzzle.sourceURL.absoluteString.hasPrefix("https://lichess.org/"))
            #expect(isValidArasanPosition(puzzle.sourceFEN))
            #expect(isValidArasanPosition(puzzle.fen))
            #expect(parseArasanBestmove("bestmove \(puzzle.firstMove)") != nil)
            #expect(parseArasanBestmove("bestmove \(puzzle.expectedMove)") != nil)
            #expect(puzzle.allowedMoves.allSatisfy {
                parseArasanBestmove("bestmove \($0)") != nil
            })
        }
    }

    @Test
    func bestmoveParserAcceptsOnlyUCIPrincipalAndPonderForms() {
        #expect(parseArasanBestmove("bestmove e2e4") == "e2e4")
        #expect(parseArasanBestmove("bestmove e2e4 ponder e7e5") == "e2e4")
        #expect(parseArasanBestmove("bestmove e2e4 garbage") == nil)
        #expect(parseArasanBestmove("bestmove e2e4 ponder") == nil)
        #expect(parseArasanBestmove("bestmove e2e4 ponder invalid") == nil)
        #expect(parseArasanBestmove("bestmove e2e4 ponder 0000") == nil)
        #expect(parseArasanBestmove("bestmove e2e4 ponder (none)") == nil)
        #expect(parseArasanBestmove("bestmove (none) ponder e7e5") == nil)
    }
}

enum LichessPuzzleCorpus {
    static func load() throws -> [LichessPuzzle] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Soak/lichess_puzzles.tsv")

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard let headerLine = lines.first else {
            return []
        }

        let headers = headerLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return try lines.dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return try LichessPuzzle(headers: headers, fields: fields)
        }
    }
}

struct LichessPuzzle {
    var id: String
    var sourceFEN: String
    var firstMove: String
    var fen: String
    var expectedMove: String
    var allowedMoves: Set<String>
    var themes: Set<String>
    var sourceURL: URL

    init(headers: [String], fields: [String]) throws {
        func value(_ name: String) throws -> String {
            guard let index = headers.firstIndex(of: name), index < fields.count else {
                throw CorpusError.missingColumn(name)
            }
            return fields[index]
        }

        id = try value("id")
        sourceFEN = try value("source_fen")
        firstMove = try value("first_move")
        fen = try value("fen")
        expectedMove = try value("expected_move")
        allowedMoves = Set(try value("allowed_moves").split(separator: ",").map(String.init))
        themes = Set(try value("themes").split(separator: " ").map(String.init))

        guard let url = URL(string: try value("source_url")) else {
            throw CorpusError.invalidURL(try value("source_url"))
        }
        sourceURL = url
    }
}

private enum CorpusError: Error {
    case missingColumn(String)
    case invalidURL(String)
}
