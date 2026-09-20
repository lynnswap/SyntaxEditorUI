import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguages

package final class LineMetricsIndex {
    package let lineOffsets = LineOffsetTable()
    private var lineColumns: [Int] = [0]
    private var columnCounts: [Int: Int] = [:]
    private var maxColumnHeap: [Int] = []
    private var maxColumnHeapIndices: [Int: Int] = [:]
    private let tabWidth: Int

    package private(set) var fullRebuildCount = 0
    package var lineCount: Int { lineOffsets.lineCount }
    package var cachedMaxColumnEntryCountForTesting: Int { maxColumnHeap.count }
    package var lineCountForTesting: Int { lineOffsets.lineCount }

    package init(source: String = "", tabWidth: Int) {
        self.tabWidth = max(1, tabWidth)
        reset(source: source)
    }

    package func reset(source: String) {
        fullRebuildCount += 1
        let metrics = Self.metrics(in: source, baseOffset: 0, tabWidth: tabWidth)
        lineOffsets.reset(source: source)
        lineColumns = metrics.columns
        rebuildColumnCountsAndHeap()
    }

    package func apply(edits: [SyntaxEditorTextChange.Replacement], previousSource: String) {
        guard !edits.isEmpty else { return }
        guard let affected = affectedRange(for: edits, in: previousSource) else {
            reset(source: SyntaxEditorTextChange.applying(edits, to: previousSource))
            return
        }

        let nsSource = previousSource as NSString
        let oldSegment = nsSource.substring(with: affected.range)
        let localEdits = edits.map {
            SyntaxEditorTextChange.Replacement(
                range: NSRange(location: $0.range.location - affected.range.location, length: $0.range.length),
                replacement: $0.replacement
            )
        }
        let newSegment = SyntaxEditorTextChange.applying(localEdits, to: oldSegment)
        var metrics = Self.metrics(in: newSegment, baseOffset: affected.range.location, tabWidth: tabWidth)
        if affected.range.upperBound < nsSource.length,
           Self.endsWithLineBreak(newSegment),
           metrics.starts.count > 1 {
            metrics.starts.removeLast()
            metrics.columns.removeLast()
        }

        let startIndex = lineIndex(containingUTF16Offset: affected.range.location)
        let endIndex = oldLineEndIndex(for: affected.range, sourceUTF16Length: nsSource.length)
        removeColumnCounts(lineColumns[startIndex..<endIndex])
        let replacementLineLengths = Self.lineLengths(
            in: newSegment,
            dropsTrailingEmptyLine: affected.range.upperBound < nsSource.length
        )
        lineOffsets.replaceLines(in: startIndex..<endIndex, with: replacementLineLengths)
        lineColumns.replaceSubrange(startIndex..<endIndex, with: metrics.columns)
        addColumnCounts(metrics.columns)
    }

    package func horizontalDocumentWidth(
        columnWidth: CGFloat,
        textContainerInset: CGFloat,
        lineFragmentPadding: CGFloat
    ) -> CGFloat {
        let maxColumns = currentMaxColumns()
        return ceil(CGFloat(maxColumns) * columnWidth + lineFragmentPadding * 2 + textContainerInset)
    }

    package func estimatedWrappedLineCount(maxColumnsPerLine: Int) -> Int {
        let maxColumnsPerLine = max(1, maxColumnsPerLine)
        return lineColumns.reduce(0) { total, columns in
            total + max(1, Int(ceil(Double(columns) / Double(maxColumnsPerLine))))
        }
    }
}

private extension LineMetricsIndex {
    func affectedRange(for edits: [SyntaxEditorTextChange.Replacement], in source: String) -> (range: NSRange, includesLineBreakMutation: Bool)? {
        let nsSource = source as NSString
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        let lower = max(0, min(first.range.location, nsSource.length))
        let upper = min(nsSource.length, max(last.range.location + last.range.length, lower))
        var range = nsSource.lineRange(for: NSRange(location: lower, length: max(0, upper - lower)))

        let touchesLineBreak = sorted.contains { edit in
            edit.replacement.contains(where: Self.isLineBreak)
                || nsSource.substring(with: edit.range).contains(where: Self.isLineBreak)
        }
        if touchesLineBreak, range.upperBound < nsSource.length {
            let nextLineRange = nsSource.lineRange(for: NSRange(location: range.upperBound, length: 0))
            range.length = nextLineRange.upperBound - range.location
        }
        return (range, touchesLineBreak)
    }

    func lineIndex(containingUTF16Offset offset: Int) -> Int {
        lineOffsets.lineIndex(containingUTF16Offset: offset)
    }

    func oldLineEndIndex(for range: NSRange, sourceUTF16Length: Int) -> Int {
        guard lineOffsets.lineCount > 0 else { return 0 }
        let upperBound = min(sourceUTF16Length, range.upperBound)
        let lookup = range.length == 0
            ? range.location
            : upperBound == sourceUTF16Length
                ? upperBound
                : max(range.location, upperBound - 1)
        return min(lineOffsets.lineCount, lineIndex(containingUTF16Offset: lookup) + 1)
    }

    static func lineLengths(
        in source: String,
        dropsTrailingEmptyLine: Bool
    ) -> [Int] {
        var lengths = LineOffsetTable.lineLengths(in: source)
        if dropsTrailingEmptyLine,
           endsWithLineBreak(source),
           lengths.count > 1 {
            lengths.removeLast()
        }
        return lengths
    }

    static func metrics(in source: String, baseOffset: Int, tabWidth: Int) -> (starts: [Int], columns: [Int]) {
        var starts = [baseOffset]
        var columns: [Int] = []
        var currentColumns = 0
        var utf16Offset = baseOffset

        for character in source {
            let utf16Length = character.utf16.count
            if isLineBreak(character) {
                columns.append(currentColumns)
                currentColumns = 0
                starts.append(utf16Offset + utf16Length)
            } else {
                currentColumns += SyntaxEditorDisplayColumnUtilities.columnWidth(
                    for: character,
                    currentColumn: currentColumns,
                    tabWidth: tabWidth
                )
            }
            utf16Offset += utf16Length
        }

        columns.append(currentColumns)
        return (starts, columns)
    }

    static func endsWithLineBreak(_ source: String) -> Bool {
        LineOffsetTable.endsWithLineBreak(source)
    }

    static func isLineBreak(_ character: Character) -> Bool {
        LineOffsetTable.isLineBreak(character)
    }

    func rebuildColumnCountsAndHeap() {
        columnCounts = [:]
        maxColumnHeap = []
        maxColumnHeapIndices = [:]
        addColumnCounts(lineColumns)
    }

    func addColumnCounts<S: Sequence>(_ columns: S) where S.Element == Int {
        for column in columns {
            let needsHeapEntry = columnCounts[column] == nil
            columnCounts[column, default: 0] += 1
            if needsHeapEntry {
                pushMaxColumn(column)
            }
        }
    }

    func removeColumnCounts<S: Sequence>(_ columns: S) where S.Element == Int {
        for column in columns {
            guard let count = columnCounts[column] else { continue }
            if count <= 1 {
                columnCounts[column] = nil
                removeMaxColumn(column)
            } else {
                columnCounts[column] = count - 1
            }
        }
    }

    func currentMaxColumns() -> Int {
        return maxColumnHeap.first ?? 0
    }

    func pushMaxColumn(_ column: Int) {
        guard maxColumnHeapIndices[column] == nil else { return }
        maxColumnHeap.append(column)
        maxColumnHeapIndices[column] = maxColumnHeap.count - 1
        siftUpMaxColumn(from: maxColumnHeap.count - 1)
    }

    func removeMaxColumn(_ column: Int) {
        guard let index = maxColumnHeapIndices.removeValue(forKey: column) else { return }
        let last = maxColumnHeap.removeLast()
        guard index < maxColumnHeap.count else { return }

        maxColumnHeap[index] = last
        maxColumnHeapIndices[last] = index
        let movedIndex = siftUpMaxColumn(from: index)
        siftDownMaxColumn(from: movedIndex)
    }

    @discardableResult
    func siftUpMaxColumn(from index: Int) -> Int {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard maxColumnHeap[parent] < maxColumnHeap[child] else { break }
            maxColumnHeap.swapAt(parent, child)
            maxColumnHeapIndices[maxColumnHeap[parent]] = parent
            maxColumnHeapIndices[maxColumnHeap[child]] = child
            child = parent
        }
        return child
    }

    func siftDownMaxColumn(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var largest = parent
            if left < maxColumnHeap.count, maxColumnHeap[largest] < maxColumnHeap[left] {
                largest = left
            }
            if right < maxColumnHeap.count, maxColumnHeap[largest] < maxColumnHeap[right] {
                largest = right
            }
            guard largest != parent else { break }
            maxColumnHeap.swapAt(parent, largest)
            maxColumnHeapIndices[maxColumnHeap[parent]] = parent
            maxColumnHeapIndices[maxColumnHeap[largest]] = largest
            parent = largest
        }
    }
}

private extension NSRange {
    var upperBound: Int {
        location + length
    }
}
