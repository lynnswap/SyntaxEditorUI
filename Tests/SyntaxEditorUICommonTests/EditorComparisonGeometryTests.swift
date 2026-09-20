import Foundation
import Testing
import SyntaxEditorCore
import SyntaxEditorUICommon

struct EditorComparisonGeometryTests {
    @Test("Common line coordinates preserve their fractional positions")
    func unchangedLines() {
        for line: CGFloat in [0, 0.25, 1, 4.75, 10] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .original, changes: []) == line)
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .modified, changes: []) == line)
        }
    }

    @Test("Insertions map the empty original span to its following common boundary")
    func insertion() async throws {
        let changes = try await EditorComparisonEngine.compare(original: "a\nb\n", modified: "a\nx\ny\nb\n")
        for (line, counterpart): (CGFloat, CGFloat) in [(0.5, 0.5), (1, 3), (1.25, 3.25), (2, 4)] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .original, changes: changes) == counterpart)
        }
        for (line, counterpart): (CGFloat, CGFloat) in [(0.5, 0.5), (1, 1), (1.5, 1), (2.75, 1), (3, 1), (3.25, 1.25), (4, 2)] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .modified, changes: changes) == counterpart)
        }
    }

    @Test("Deletions map to the empty modified boundary in both directions")
    func deletion() async throws {
        let changes = try await EditorComparisonEngine.compare(original: "a\nx\ny\nb\n", modified: "a\nb\n")
        for (line, counterpart): (CGFloat, CGFloat) in [(0.5, 0.5), (1, 1), (1.5, 1), (2.75, 1), (3, 1), (3.25, 1.25), (4, 2)] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .original, changes: changes) == counterpart)
        }
        for (line, counterpart): (CGFloat, CGFloat) in [(0.5, 0.5), (1, 3), (1.25, 3.25), (2, 4)] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .modified, changes: changes) == counterpart)
        }
    }

    @Test("Different-sized replacements interpolate logical line spans")
    func replacement() async throws {
        let changes = try await EditorComparisonEngine.compare(
            original: "a\nold one\nold two\nb\n",
            modified: "a\nnew one\nnew two\nnew three\nb\n"
        )
        for (line, counterpart): (CGFloat, CGFloat) in [(0.5, 0.5), (1, 1), (1.5, 1.75), (2, 2.5), (2.75, 3.625), (3, 4), (3.25, 4.25), (4, 5)] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .original, changes: changes) == counterpart)
            #expect(EditorComparisonGeometry.counterpartLine(counterpart, from: .modified, changes: changes) == line)
        }
    }

    @Test("Common spans round-trip through accumulated insertion and deletion deltas")
    func commonSpanRoundTrip() async throws {
        let changes = try await EditorComparisonEngine.compare(
            original: "a\nb\nc\nd\ne\nf\ng\n",
            modified: "a\ninsert one\ninsert two\nb\nc\nf\nnew\n"
        )
        for (line, counterpart): (CGFloat, CGFloat) in [(0.25, 0.25), (1, 3), (1.25, 3.25), (2.875, 4.875), (5, 5), (5.5, 5.5), (7, 7)] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .original, changes: changes) == counterpart)
            #expect(EditorComparisonGeometry.counterpartLine(counterpart, from: .modified, changes: changes) == line)
        }
    }

    @Test("An insertion at the first line has downstream affinity")
    func firstLineInsertion() async throws {
        let changes = try await EditorComparisonEngine.compare(original: "tail\n", modified: "first\nsecond\ntail\n")
        #expect(EditorComparisonGeometry.counterpartLine(0, from: .original, changes: changes) == 2)
        #expect(EditorComparisonGeometry.counterpartLine(0.5, from: .original, changes: changes) == 2.5)
        for line: CGFloat in [0, 0.5, 1.5, 2] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .modified, changes: changes) == 0)
        }
    }

    @Test("An empty document maps to the opposite EOF boundary")
    func emptyDocument() async throws {
        let inserted = try await EditorComparisonEngine.compare(original: "", modified: "a\nb\n")
        #expect(EditorComparisonGeometry.counterpartLine(0, from: .original, changes: inserted) == 2)
        for line: CGFloat in [0, 0.5, 1.75, 2] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .modified, changes: inserted) == 0)
        }

        let deleted = try await EditorComparisonEngine.compare(original: "a\nb\n", modified: "")
        #expect(EditorComparisonGeometry.counterpartLine(0, from: .modified, changes: deleted) == 2)
        for line: CGFloat in [0, 0.5, 1.75, 2] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .original, changes: deleted) == 0)
        }
    }

    @Test("EOF insertions map both endpoint boundaries without a phantom line")
    func endOfFileInsertion() async throws {
        let changes = try await EditorComparisonEngine.compare(original: "a\n", modified: "a\nlast\n")
        #expect(EditorComparisonGeometry.counterpartLine(0.75, from: .original, changes: changes) == 0.75)
        #expect(EditorComparisonGeometry.counterpartLine(1, from: .original, changes: changes) == 2)
        for line: CGFloat in [1, 1.25, 1.75, 2] {
            #expect(EditorComparisonGeometry.counterpartLine(line, from: .modified, changes: changes) == 1)
        }
    }
}
