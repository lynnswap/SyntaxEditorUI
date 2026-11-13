import Foundation

package final class LineOffsetTable {
    private var lineLengths: [Int] = [0]
    private var prefixTree = PrefixSumTree(values: [0])

    package init(source: String = "") {
        reset(source: source)
    }

    package var lineCount: Int {
        lineLengths.count
    }

    package var totalUTF16Length: Int {
        prefixTree.total
    }

    package func reset(source: String) {
        lineLengths = Self.lineLengths(in: source)
        prefixTree = PrefixSumTree(values: lineLengths)
    }

    package func lineStartOffset(at index: Int) -> Int {
        guard !lineLengths.isEmpty else { return 0 }
        let clampedIndex = min(max(0, index), lineLengths.count)
        return prefixTree.prefixSum(upTo: clampedIndex)
    }

    package func lineEndOffset(at index: Int) -> Int {
        guard !lineLengths.isEmpty else { return 0 }
        let clampedIndex = min(max(0, index), lineLengths.count - 1)
        return prefixTree.prefixSum(upTo: clampedIndex + 1)
    }

    package func lineLength(at index: Int) -> Int {
        guard lineLengths.indices.contains(index) else { return 0 }
        return lineLengths[index]
    }

    package func lineIndex(containingUTF16Offset offset: Int) -> Int {
        guard !lineLengths.isEmpty else { return 0 }
        let clampedOffset = min(max(0, offset), totalUTF16Length)
        let consumedLineCount = prefixTree.countOfPrefixes(lessThanOrEqualTo: clampedOffset)
        return min(max(0, consumedLineCount), lineLengths.count - 1)
    }

    package func lineRange(containingUTF16Range range: NSRange) -> Range<Int> {
        guard !lineLengths.isEmpty else { return 0..<0 }
        let textLength = totalUTF16Length
        let lower = min(max(0, range.location), textLength)
        let upper = min(max(lower, range.upperBound), textLength)
        let startIndex = lineIndex(containingUTF16Offset: lower)
        let endLookup: Int
        if range.length == 0 {
            endLookup = lower
        } else if upper == textLength {
            endLookup = upper
        } else {
            endLookup = max(lower, upper - 1)
        }
        let endIndex = lineIndex(containingUTF16Offset: endLookup)
        return startIndex..<(min(lineLengths.count, endIndex + 1))
    }

    package func replaceLines(in range: Range<Int>, with replacementLengths: [Int]) {
        let lower = min(max(0, range.lowerBound), lineLengths.count)
        let upper = min(max(lower, range.upperBound), lineLengths.count)
        let replacements = replacementLengths.isEmpty ? [0] : replacementLengths
        if upper - lower == 1,
           replacements.count == 1,
           lineLengths.indices.contains(lower) {
            let delta = replacements[0] - lineLengths[lower]
            lineLengths[lower] = replacements[0]
            prefixTree.add(delta, at: lower)
            return
        }

        lineLengths.replaceSubrange(lower..<upper, with: replacements)
        if lineLengths.isEmpty {
            lineLengths = [0]
        }
        prefixTree = PrefixSumTree(values: lineLengths)
    }

    package static func lineLengths(in source: String) -> [Int] {
        var lengths: [Int] = []
        var currentLength = 0
        var sawCharacter = false

        for character in source {
            sawCharacter = true
            let utf16Length = character.utf16.count
            currentLength += utf16Length
            if isLineBreak(character) {
                lengths.append(currentLength)
                currentLength = 0
            }
        }

        if sawCharacter || lengths.isEmpty {
            lengths.append(currentLength)
        }
        return lengths
    }

    package static func containsLineBreak(_ text: String) -> Bool {
        text.contains(where: isLineBreak)
    }

    package static func endsWithLineBreak(_ text: String) -> Bool {
        text.last.map(isLineBreak) ?? false
    }

    package static func isLineBreak(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.value == 10 || scalar.value == 13
        }
    }
}

private struct PrefixSumTree {
    private var tree: [Int]
    private(set) var count: Int

    init(values: [Int]) {
        count = values.count
        tree = Array(repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() {
            add(value, at: index)
        }
    }

    var total: Int {
        prefixSum(upTo: count)
    }

    mutating func add(_ delta: Int, at index: Int) {
        guard index >= 0, index < count, delta != 0 else { return }
        var treeIndex = index + 1
        while treeIndex < tree.count {
            tree[treeIndex] += delta
            treeIndex += treeIndex & -treeIndex
        }
    }

    func prefixSum(upTo count: Int) -> Int {
        var treeIndex = min(max(0, count), self.count)
        var result = 0
        while treeIndex > 0 {
            result += tree[treeIndex]
            treeIndex -= treeIndex & -treeIndex
        }
        return result
    }

    func countOfPrefixes(lessThanOrEqualTo target: Int) -> Int {
        var index = 0
        var bitMask = 1
        while bitMask << 1 <= count {
            bitMask <<= 1
        }

        var sum = 0
        var step = bitMask
        while step > 0 {
            let nextIndex = index + step
            if nextIndex <= count, sum + tree[nextIndex] <= target {
                index = nextIndex
                sum += tree[nextIndex]
            }
            step >>= 1
        }
        return index
    }
}
