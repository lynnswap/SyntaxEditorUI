import Foundation
import Testing
import SyntaxEditorModel

struct EditorComparisonEngineTests {
    @Test("Identical text has no changes", arguments: ["", "a", "a\n", "\r\n", "e\u{301}👩🏽‍💻\r"])
    func identicalText(_ text: String) async throws {
        let changes = try await EditorComparisonEngine.compare(original: text, modified: text)
        #expect(changes.isEmpty)
    }

    @Test("Empty documents have zero tokens on the empty side")
    func emptyDocuments() async throws {
        let inserted = try await verifiedChanges(original: "", modified: "a\n")
        let insertion = try #require(inserted.only)
        #expect(insertion.originalRange == NSRange(location: 0, length: 0))
        #expect(insertion.modifiedRange == NSRange(location: 0, length: 2))
        #expect(insertion.originalLines == 0..<0)
        #expect(insertion.modifiedLines == 0..<1)
        #expect(insertion.inlineChanges.isEmpty)

        let deleted = try await verifiedChanges(original: "a\n", modified: "")
        let deletion = try #require(deleted.only)
        #expect(deletion.originalRange == NSRange(location: 0, length: 2))
        #expect(deletion.modifiedRange == NSRange(location: 0, length: 0))
        #expect(deletion.originalLines == 0..<1)
        #expect(deletion.modifiedLines == 0..<0)
    }

    @Test("EOF deletions and insertions use document-end boundaries")
    func endOfFileBoundaries() async throws {
        let deleted = try await verifiedChanges(original: "a\nb\n", modified: "a\n")
        let deletion = try #require(deleted.only)
        #expect(deletion.originalRange == NSRange(location: 2, length: 2))
        #expect(deletion.modifiedRange == NSRange(location: 2, length: 0))
        #expect(deletion.originalLines == 1..<2)
        #expect(deletion.modifiedLines == 1..<1)

        let inserted = try await verifiedChanges(original: "a\n", modified: "a\nb\n")
        let insertion = try #require(inserted.only)
        #expect(insertion.originalRange == NSRange(location: 2, length: 0))
        #expect(insertion.modifiedRange == NSRange(location: 2, length: 2))
        #expect(insertion.originalLines == 1..<1)
        #expect(insertion.modifiedLines == 1..<2)
    }

    @Test("LF, CRLF, and CR terminators remain part of their preceding line", arguments: ["\n", "\r\n", "\r"])
    func lineTerminators(_ terminator: String) async throws {
        let original = "before" + terminator + "old" + terminator + "after" + terminator
        let modified = "before" + terminator + "new" + terminator + "after" + terminator
        let changes = try await verifiedChanges(original: original, modified: modified)
        let change = try #require(changes.only)
        #expect(change.originalLines == 1..<2)
        #expect(change.modifiedLines == 1..<2)
        #expect(change.originalRange == NSRange(location: 6 + terminator.utf16.count, length: 3 + terminator.utf16.count))
        #expect(change.modifiedRange == change.originalRange)
    }

    @Test("Newline-only edits retain one changed line and exact UTF-16 ranges")
    func newlineOnlyChanges() async throws {
        for (original, modified) in [("a\r\n", "a\n"), ("a\r", "a\n"), ("a", "a\n"), ("\r\n", "\n")] {
            let changes = try await verifiedChanges(original: original, modified: modified)
            let change = try #require(changes.only)
            #expect(change.originalLines == 0..<1)
            #expect(change.modifiedLines == 0..<1)
            #expect(change.originalRange == NSRange(location: 0, length: original.utf16.count))
            #expect(change.modifiedRange == NSRange(location: 0, length: modified.utf16.count))
            #expect(!change.inlineChanges.isEmpty)
        }
    }

    @Test("Canonical Unicode equivalence does not erase code-unit changes")
    func canonicalUnicode() async throws {
        let original = "e\u{301}\n"
        let modified = "é\n"
        #expect(original == modified)
        let changes = try await verifiedChanges(original: original, modified: modified)
        let change = try #require(changes.only)
        let inlineChange = try #require(change.inlineChanges.only)
        #expect(inlineChange.originalRange == NSRange(location: 0, length: 2))
        #expect(inlineChange.modifiedRange == NSRange(location: 0, length: 1))
    }

    @Test("Inline changes encompass whole emoji and combining graphemes")
    func inlineGraphemes() async throws {
        let original = "a👨‍👩‍👧‍👦 e\u{301}z\n"
        let modified = "a👩🏽‍💻 éz\n"
        let changes = try await verifiedChanges(original: original, modified: modified)
        let change = try #require(changes.only)
        try #require(change.inlineChanges.count == 2)
        #expect(change.inlineChanges[0].originalRange == NSRange(location: 1, length: "👨‍👩‍👧‍👦".utf16.count))
        #expect(change.inlineChanges[0].modifiedRange == NSRange(location: 1, length: "👩🏽‍💻".utf16.count))
        #expect(change.inlineChanges[1].originalRange.length == 2)
        #expect(change.inlineChanges[1].modifiedRange.length == 1)
    }

    @Test("Repeated and moved lines reconstruct without overlapping hunks")
    func repeatedLines() async throws {
        for (original, modified) in [
            ("a\na\na\nb\na\n", "a\nb\na\na\na\n"),
            ("first\nrepeat\nrepeat\nlast\n", "first\nrepeat\nnew\nrepeat\nlast\n"),
            ("a\nb\nc\nd\n", "c\nd\na\nb\n"),
            ("a\nb\nc\n", "a\nnew one\nnew two\nc\n"),
        ] {
            _ = try await verifiedChanges(original: original, modified: modified)
        }
    }

    @Test("Sparse edits retain separate hunks in a large document")
    func sparseChanges() async throws {
        let originalLines = (0..<10_000).map { "line \($0)\n" }
        var modifiedLines = originalLines
        let editedLines = [100, 4_000, 9_900]
        for line in editedLines {
            modifiedLines[line] = "changed \(line)\n"
        }
        let changes = try await verifiedChanges(original: originalLines.joined(), modified: modifiedLines.joined())
        #expect(changes.map(\.originalLines) == editedLines.map { $0..<($0 + 1) })
        #expect(changes.map(\.modifiedLines) == editedLines.map { $0..<($0 + 1) })
    }

    @Test("Oversized ambiguous gaps fall back to a replacement inside shared boundaries")
    func largeAmbiguousReplacement() async throws {
        let original = "head\n" + String(repeating: "old\n", count: 1_200) + "tail\n"
        let modified = "head\n" + String(repeating: "new\n", count: 1_200) + "tail\n"
        let changes = try await verifiedChanges(original: original, modified: modified)
        let change = try #require(changes.only)
        #expect(change.originalLines == 1..<1_201)
        #expect(change.modifiedLines == 1..<1_201)
        #expect(change.originalRange == NSRange(location: 5, length: 4_800))
        #expect(change.modifiedRange == change.originalRange)
    }

    @Test("Many ambiguous gaps share one detail budget while preserving their anchors")
    func sharedGapBudget() async throws {
        func source(changedLine: String) -> String {
            (0..<3).map { block in
                "anchor \(block)\n"
                    + String(repeating: changedLine + "\n", count: 300)
                    + "shared\nshared\n"
                    + String(repeating: changedLine + "\n", count: 300)
            }.joined() + "end\n"
        }
        let changes = try await verifiedChanges(original: source(changedLine: "old"), modified: source(changedLine: "new"))
        #expect(changes.count == 5)
        #expect(changes.last?.originalLines == 1_207..<1_809)
        #expect(changes.last?.modifiedLines == 1_207..<1_809)
    }

    @Test("Very long changed lines remain comparable without detailed spans")
    func longLines() async throws {
        let original = String(repeating: "a", count: 50_000)
        let modified = String(repeating: "b", count: 50_000)
        let changes = try await verifiedChanges(original: original, modified: modified)
        let change = try #require(changes.only)
        #expect(change.originalRange == NSRange(location: 0, length: 50_000))
        #expect(change.modifiedRange == change.originalRange)
        #expect(change.inlineChanges.isEmpty)
    }

    @Test("Seeded mixed Unicode inputs reconstruct both small and repeated-line changes")
    func randomizedReconstruction() async throws {
        let vocabulary = ["", "a", "b", "repeat", "é", "e\u{301}", "👨‍👩‍👧‍👦", "😀", "\t", "変数"]
        let terminators = ["\n", "\r\n", "\r", ""]
        var random = Random(seed: 42)
        for _ in 0..<500 {
            var original = ""
            var modified = ""
            for _ in 0..<random.next(25) {
                original += vocabulary[random.next(vocabulary.count)] + terminators[random.next(terminators.count)]
            }
            for _ in 0..<random.next(25) {
                modified += vocabulary[random.next(vocabulary.count)] + terminators[random.next(terminators.count)]
            }
            _ = try await verifiedChanges(original: original, modified: modified)
        }
    }

    @MainActor
    @Test("Comparison propagates cancellation without returning a partial result")
    func cancellation() async {
        let task = Task {
            try await EditorComparisonEngine.compare(original: "before\n", modified: "after\n")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func verifiedChanges(original: String, modified: String) async throws -> [EditorComparisonEngine.Change] {
        let changes = try await EditorComparisonEngine.compare(original: original, modified: modified)
        let originalUnits = Array(original.utf16)
        let modifiedUnits = Array(modified.utf16)
        let originalGraphemeBoundaries = graphemeBoundaries(original)
        let modifiedGraphemeBoundaries = graphemeBoundaries(modified)
        var reconstruction: [UInt16] = []
        var originalCursor = 0
        var modifiedCursor = 0
        var originalLineCursor = 0
        var modifiedLineCursor = 0
        for change in changes {
            try #require(change.originalRange.location >= originalCursor)
            try #require(change.modifiedRange.location >= modifiedCursor)
            try #require(change.originalRange.upperBound <= originalUnits.count)
            try #require(change.modifiedRange.upperBound <= modifiedUnits.count)
            #expect(change.originalLines.lowerBound >= originalLineCursor)
            #expect(change.modifiedLines.lowerBound >= modifiedLineCursor)
            #expect(change.originalRange.length > 0 || change.modifiedRange.length > 0)
            reconstruction.append(contentsOf: originalUnits[originalCursor..<change.originalRange.location])
            reconstruction.append(contentsOf: modifiedUnits[change.modifiedRange.location..<change.modifiedRange.upperBound])
            #expect(originalUnits[originalCursor..<change.originalRange.location].elementsEqual(modifiedUnits[modifiedCursor..<change.modifiedRange.location]))
            originalCursor = change.originalRange.upperBound
            modifiedCursor = change.modifiedRange.upperBound
            originalLineCursor = change.originalLines.upperBound
            modifiedLineCursor = change.modifiedLines.upperBound

            var inlineOriginalCursor = change.originalRange.location
            var inlineModifiedCursor = change.modifiedRange.location
            for inlineChange in change.inlineChanges {
                try #require(inlineChange.originalRange.location >= inlineOriginalCursor)
                try #require(inlineChange.modifiedRange.location >= inlineModifiedCursor)
                try #require(inlineChange.originalRange.upperBound <= change.originalRange.upperBound)
                try #require(inlineChange.modifiedRange.upperBound <= change.modifiedRange.upperBound)
                #expect(originalGraphemeBoundaries.contains(inlineChange.originalRange.location))
                #expect(originalGraphemeBoundaries.contains(inlineChange.originalRange.upperBound))
                #expect(modifiedGraphemeBoundaries.contains(inlineChange.modifiedRange.location))
                #expect(modifiedGraphemeBoundaries.contains(inlineChange.modifiedRange.upperBound))
                inlineOriginalCursor = inlineChange.originalRange.upperBound
                inlineModifiedCursor = inlineChange.modifiedRange.upperBound
            }
        }
        reconstruction.append(contentsOf: originalUnits[originalCursor...])
        #expect(reconstruction == modifiedUnits)
        #expect(originalUnits[originalCursor...].elementsEqual(modifiedUnits[modifiedCursor...]))
        #expect(changes.isEmpty == (originalUnits == modifiedUnits))
        return changes
    }

    private func graphemeBoundaries(_ text: String) -> Set<Int> {
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            offset += character.utf16.count
            boundaries.insert(offset)
        }
        return boundaries
    }

    private struct Random {
        var seed: UInt64

        mutating func next(_ upperBound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 32) % upperBound
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
