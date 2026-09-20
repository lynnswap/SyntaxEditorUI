import Foundation

package enum EditorComparisonEngine {
    package struct InlineChange: Equatable, Sendable {
        package let originalRange: NSRange
        package let modifiedRange: NSRange
    }

    package struct Change: Equatable, Sendable {
        package let originalRange: NSRange
        package let modifiedRange: NSRange
        package let originalLines: Range<Int>
        package let modifiedLines: Range<Int>
        package let inlineChanges: [InlineChange]
    }

    private static let differenceBudget = 1_000_000
    private static let inlineLineLengthLimit = 16_384

    @concurrent
    package static func compare(original: String, modified: String) async throws -> [Change] {
        try Task.checkCancellation()
        let originalTokens = try Tokens.lines(in: original)
        let modifiedTokens = try Tokens.lines(in: modified)
        let identifiers = try intern(originalTokens, modifiedTokens)
        let lineChanges = try changes(
            original: identifiers.original,
            modified: identifiers.modified,
            useAnchors: true,
            budget: differenceBudget
        )

        var result: [Change] = []
        var inlineBudget = differenceBudget
        for change in lineChanges {
            try Task.checkCancellation()
            let inlineChanges = try inlineChanges(
                in: change,
                original: originalTokens,
                modified: modifiedTokens,
                budget: &inlineBudget
            )
            result.append(Change(
                originalRange: originalTokens.utf16Range(change.original),
                modifiedRange: modifiedTokens.utf16Range(change.modified),
                originalLines: change.original,
                modifiedLines: change.modified,
                inlineChanges: inlineChanges
            ))
        }
        try Task.checkCancellation()
        return result
    }

    private struct Tokens {
        let units: [UInt16]
        let boundaries: [Int]
        let fingerprints: [Int]

        var count: Int { fingerprints.count }

        func utf16Range(_ range: Range<Int>) -> NSRange {
            NSRange(
                location: boundaries[range.lowerBound],
                length: boundaries[range.upperBound] - boundaries[range.lowerBound]
            )
        }

        static func lines(in text: String) throws -> Tokens {
            var units: [UInt16] = []
            for unit in text.utf16 {
                try checkCancellation(at: units.count)
                units.append(unit)
            }

            var boundaries = [0]
            var fingerprints: [Int] = []
            var hasher = Hasher()
            var index = 0
            while index < units.count {
                try checkCancellation(at: index)
                let unit = units[index]
                hasher.combine(unit)
                index += 1
                if unit == 13, index < units.count, units[index] == 10 {
                    hasher.combine(units[index])
                    index += 1
                }
                if unit == 10 || unit == 13 {
                    try Task.checkCancellation()
                    boundaries.append(index)
                    fingerprints.append(hasher.finalize())
                    hasher = Hasher()
                }
            }
            // A terminator belongs to its preceding line; it creates no EOF token.
            if boundaries.last != units.count {
                boundaries.append(units.count)
                fingerprints.append(hasher.finalize())
            }
            return Tokens(units: units, boundaries: boundaries, fingerprints: fingerprints)
        }

        func graphemes(in line: Int) throws -> Tokens {
            let range = boundaries[line]..<boundaries[line + 1]
            let text = String(decoding: units[range], as: UTF16.self)
            var boundaries = [range.lowerBound]
            var fingerprints: [Int] = []
            var offset = range.lowerBound
            for character in text {
                try Task.checkCancellation()
                var hasher = Hasher()
                for unit in character.utf16 {
                    try checkCancellation(at: offset)
                    hasher.combine(unit)
                    offset += 1
                }
                boundaries.append(offset)
                fingerprints.append(hasher.finalize())
            }
            return Tokens(units: units, boundaries: boundaries, fingerprints: fingerprints)
        }
    }

    private struct InternedToken {
        let source: Int
        let range: Range<Int>
        let identifier: Int
    }

    private static func intern(
        _ original: Tokens,
        _ modified: Tokens
    ) throws -> (original: [Int], modified: [Int]) {
        let sources = [original, modified]
        var buckets: [Int: [InternedToken]] = [:]
        var identifiers = [[Int](), [Int]()]
        var nextIdentifier = 0
        for sourceIndex in sources.indices {
            let source = sources[sourceIndex]
            for index in 0..<source.count {
                try checkCancellation(at: index)
                let range = source.boundaries[index]..<source.boundaries[index + 1]
                let fingerprint = source.fingerprints[index]
                var identifier: Int?
                for token in buckets[fingerprint, default: []] {
                    try Task.checkCancellation()
                    if try equal(
                        source.units, range,
                        sources[token.source].units, token.range
                    ) {
                        identifier = token.identifier
                        break
                    }
                }
                if let identifier {
                    identifiers[sourceIndex].append(identifier)
                } else {
                    buckets[fingerprint, default: []].append(InternedToken(
                        source: sourceIndex,
                        range: range,
                        identifier: nextIdentifier
                    ))
                    identifiers[sourceIndex].append(nextIdentifier)
                    nextIdentifier += 1
                }
            }
        }
        return (identifiers[0], identifiers[1])
    }

    private static func equal(
        _ original: [UInt16], _ originalRange: Range<Int>,
        _ modified: [UInt16], _ modifiedRange: Range<Int>
    ) throws -> Bool {
        guard originalRange.count == modifiedRange.count else { return false }
        for offset in 0..<originalRange.count {
            try checkCancellation(at: offset)
            if original[originalRange.lowerBound + offset] != modified[modifiedRange.lowerBound + offset] {
                return false
            }
        }
        return true
    }

    private struct TokenChange {
        var original: Range<Int>
        var modified: Range<Int>
    }

    private struct Anchor {
        let original: Int
        let modified: Int
    }

    private static func changes(
        original: [Int],
        modified: [Int],
        useAnchors: Bool,
        budget: Int
    ) throws -> [TokenChange] {
        var originalRange = original.indices
        var modifiedRange = modified.indices
        try trimCommonTokens(original, modified, originalRange: &originalRange, modifiedRange: &modifiedRange)
        let anchors = useAnchors
            ? try anchors(original, modified, originalRange: originalRange, modifiedRange: modifiedRange)
            : []
        var result: [TokenChange] = []
        var originalStart = originalRange.lowerBound
        var modifiedStart = modifiedRange.lowerBound
        for anchor in anchors {
            try Task.checkCancellation()
            try appendGap(
                original, modified,
                originalRange: originalStart..<anchor.original,
                modifiedRange: modifiedStart..<anchor.modified,
                budget: budget,
                to: &result
            )
            originalStart = anchor.original + 1
            modifiedStart = anchor.modified + 1
        }
        try appendGap(
            original, modified,
            originalRange: originalStart..<originalRange.upperBound,
            modifiedRange: modifiedStart..<modifiedRange.upperBound,
            budget: budget,
            to: &result
        )
        return result
    }

    private static func trimCommonTokens(
        _ original: [Int], _ modified: [Int],
        originalRange: inout Range<Int>, modifiedRange: inout Range<Int>
    ) throws {
        while !originalRange.isEmpty, !modifiedRange.isEmpty,
              original[originalRange.lowerBound] == modified[modifiedRange.lowerBound] {
            try checkCancellation(at: originalRange.lowerBound)
            originalRange = (originalRange.lowerBound + 1)..<originalRange.upperBound
            modifiedRange = (modifiedRange.lowerBound + 1)..<modifiedRange.upperBound
        }
        while !originalRange.isEmpty, !modifiedRange.isEmpty,
              original[originalRange.upperBound - 1] == modified[modifiedRange.upperBound - 1] {
            try checkCancellation(at: originalRange.upperBound)
            originalRange = originalRange.lowerBound..<(originalRange.upperBound - 1)
            modifiedRange = modifiedRange.lowerBound..<(modifiedRange.upperBound - 1)
        }
    }

    private static func anchors(
        _ original: [Int], _ modified: [Int],
        originalRange: Range<Int>, modifiedRange: Range<Int>
    ) throws -> [Anchor] {
        var originalOccurrences: [Int: Int] = [:]
        var modifiedOccurrences: [Int: Int] = [:]
        for index in originalRange {
            try checkCancellation(at: index)
            let token = original[index]
            originalOccurrences[token] = originalOccurrences[token] == nil ? index : -1
        }
        for index in modifiedRange {
            try checkCancellation(at: index)
            let token = modified[index]
            modifiedOccurrences[token] = modifiedOccurrences[token] == nil ? index : -1
        }

        var candidates: [Anchor] = []
        var predecessors: [Int] = []
        var tails: [Int] = []
        for index in originalRange {
            try checkCancellation(at: index)
            let token = original[index]
            guard originalOccurrences[token] == index,
                  let modifiedIndex = modifiedOccurrences[token], modifiedIndex >= 0 else { continue }
            var lower = 0
            var upper = tails.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if candidates[tails[middle]].modified < modifiedIndex {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            predecessors.append(lower == 0 ? -1 : tails[lower - 1])
            candidates.append(Anchor(original: index, modified: modifiedIndex))
            if lower == tails.count {
                tails.append(candidates.count - 1)
            } else {
                tails[lower] = candidates.count - 1
            }
        }

        var result: [Anchor] = []
        var index = tails.last ?? -1
        while index >= 0 {
            try checkCancellation(at: result.count)
            result.append(candidates[index])
            index = predecessors[index]
        }
        return result.reversed()
    }

    private static func appendGap(
        _ original: [Int], _ modified: [Int],
        originalRange: Range<Int>, modifiedRange: Range<Int>,
        budget: Int, to result: inout [TokenChange]
    ) throws {
        try Task.checkCancellation()
        var originalRange = originalRange
        var modifiedRange = modifiedRange
        try trimCommonTokens(original, modified, originalRange: &originalRange, modifiedRange: &modifiedRange)
        guard !originalRange.isEmpty || !modifiedRange.isEmpty else { return }
        guard !originalRange.isEmpty, !modifiedRange.isEmpty,
              originalRange.count <= budget / modifiedRange.count else {
            append(TokenChange(original: originalRange, modified: modifiedRange), to: &result)
            return
        }

        // The standard diff is not cancellable. Bound each call, and keep coarse
        // replacements for larger ambiguous gaps without rejecting their text.
        let difference = modified[modifiedRange].difference(from: original[originalRange])
        try Task.checkCancellation()
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            try checkCancellation(at: removals.count + insertions.count)
            switch change {
            case let .remove(offset, _, _): removals.insert(originalRange.lowerBound + offset)
            case let .insert(offset, _, _): insertions.insert(modifiedRange.lowerBound + offset)
            }
        }

        var originalIndex = originalRange.lowerBound
        var modifiedIndex = modifiedRange.lowerBound
        while originalIndex < originalRange.upperBound || modifiedIndex < modifiedRange.upperBound {
            try Task.checkCancellation()
            let originalStart = originalIndex
            let modifiedStart = modifiedIndex
            while removals.contains(originalIndex) {
                try checkCancellation(at: originalIndex)
                originalIndex += 1
            }
            while insertions.contains(modifiedIndex) {
                try checkCancellation(at: modifiedIndex)
                modifiedIndex += 1
            }
            if originalStart != originalIndex || modifiedStart != modifiedIndex {
                append(TokenChange(
                    original: originalStart..<originalIndex,
                    modified: modifiedStart..<modifiedIndex
                ), to: &result)
            } else {
                originalIndex += 1
                modifiedIndex += 1
            }
        }
    }

    private static func append(_ change: TokenChange, to changes: inout [TokenChange]) {
        if let last = changes.last,
           last.original.upperBound == change.original.lowerBound,
           last.modified.upperBound == change.modified.lowerBound {
            changes[changes.count - 1] = TokenChange(
                original: last.original.lowerBound..<change.original.upperBound,
                modified: last.modified.lowerBound..<change.modified.upperBound
            )
        } else {
            changes.append(change)
        }
    }

    private static func inlineChanges(
        in change: TokenChange, original: Tokens, modified: Tokens,
        budget: inout Int
    ) throws -> [InlineChange] {
        guard change.original.count == change.modified.count else { return [] }
        var result: [InlineChange] = []
        for offset in 0..<change.original.count {
            try Task.checkCancellation()
            let originalLine = change.original.lowerBound + offset
            let modifiedLine = change.modified.lowerBound + offset
            guard original.utf16Range(originalLine..<(originalLine + 1)).length <= inlineLineLengthLimit,
                  modified.utf16Range(modifiedLine..<(modifiedLine + 1)).length <= inlineLineLengthLimit else { continue }
            let originalTokens = try original.graphemes(in: originalLine)
            let modifiedTokens = try modified.graphemes(in: modifiedLine)
            guard originalTokens.count <= budget / modifiedTokens.count else { continue }
            budget -= originalTokens.count * modifiedTokens.count
            let identifiers = try intern(originalTokens, modifiedTokens)
            let changes = try changes(
                original: identifiers.original,
                modified: identifiers.modified,
                useAnchors: false,
                budget: differenceBudget
            )
            for change in changes {
                result.append(InlineChange(
                    originalRange: originalTokens.utf16Range(change.original),
                    modifiedRange: modifiedTokens.utf16Range(change.modified)
                ))
            }
        }
        return result
    }

    private static func checkCancellation(at offset: Int) throws {
        if offset & 511 == 0 {
            try Task.checkCancellation()
        }
    }
}
