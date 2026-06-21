import Foundation

typealias ObjectiveCRangeKey = SyntaxOverlayRangeKey
typealias ObjectiveCTokenKey = SyntaxOverlayTokenKey
typealias ObjectiveCSyntaxIDMask = SyntaxOverlaySyntaxIDMask

struct ObjectiveCSemanticOverlayState: SyntaxOverlayState {
    var index: ObjectiveCSemanticIndex?
}

typealias ObjectiveCSemanticOverlayResult = SyntaxOverlayResult

struct ObjectiveCSemanticIndexSignature {
    let fingerprint: Int
    let structuralEditRanges: [NSRange]
}

struct ObjectiveCSemanticLineSignature {
    let range: NSRange
    let contributesToSignature: Bool
    let fingerprint: Int
    let structuralEditRanges: [NSRange]
}

struct ObjectiveCSemanticLineSignatureIndex {
    let lines: [ObjectiveCSemanticLineSignature]
    let fingerprint: Int
    let structuralEditRanges: [NSRange]

    init(source: NSString) {
        var lines: [ObjectiveCSemanticLineSignature] = []
        lines.reserveCapacity(max(1, source.length / 48))

        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            lines.append(Self.signature(for: lineRange, in: source))
            let nextLocation = lineRange.upperBound
            guard nextLocation > location else { break }
            location = nextLocation
        }

        self.init(lines: lines)
    }

    private init(lines: [ObjectiveCSemanticLineSignature]) {
        self.lines = lines
        self.fingerprint = Self.fingerprint(for: lines)
        self.structuralEditRanges = lines.flatMap(\.structuralEditRanges)
    }

    func applying(
        _ mutation: SyntaxEditorTextChange.Replacement,
        to source: NSString
    ) -> ObjectiveCSemanticLineSignatureIndex? {
        guard !lines.isEmpty else {
            return nil
        }

        let replacementLength = mutation.replacement.utf16.count
        let previousSourceLength = source.length - (replacementLength - mutation.length)
        guard previousSourceLength >= 0,
              mutation.location >= 0,
              mutation.location <= previousSourceLength,
              mutation.location + mutation.length <= previousSourceLength else {
            return nil
        }

        let oldEnd = mutation.location + mutation.length
        let insertsAfterLastSignature = insertsAtEOFAfterTrailingLineBreak(
            mutation,
            source: source,
            previousSourceLength: previousSourceLength
        )
        let startIndex = insertsAfterLastSignature
            ? lines.count
            : lineIndex(containing: mutation.location, previousSourceLength: previousSourceLength)
        let endIndex = insertsAfterLastSignature
            ? lines.count - 1
            : replacementEndLineIndex(
                mutation: mutation,
                oldEnd: oldEnd,
                previousSourceLength: previousSourceLength
            )
        let changedLineSignatures = Self.signaturesForChangedLines(mutation, in: source)
        guard !changedLineSignatures.isEmpty else { return nil }
        let delta = replacementLength - mutation.length

        var nextLines: [ObjectiveCSemanticLineSignature] = []
        nextLines.reserveCapacity(lines.count - (endIndex - startIndex + 1) + changedLineSignatures.count)
        var insertedChangedLines = false
        for index in lines.indices {
            if index < startIndex {
                nextLines.append(lines[index])
            } else if index == startIndex {
                nextLines.append(contentsOf: changedLineSignatures)
                insertedChangedLines = true
            } else if index <= endIndex {
                continue
            } else {
                let line = lines[index]
                nextLines.append(
                    ObjectiveCSemanticLineSignature(
                        range: NSRange(location: line.range.location + delta, length: line.range.length),
                        contributesToSignature: line.contributesToSignature,
                        fingerprint: line.fingerprint,
                        structuralEditRanges: line.structuralEditRanges.map {
                            NSRange(location: $0.location + delta, length: $0.length)
                        }
                    )
                )
            }
        }
        if !insertedChangedLines {
            nextLines.append(contentsOf: changedLineSignatures)
        }
        return ObjectiveCSemanticLineSignatureIndex(lines: nextLines)
    }

    private func insertsAtEOFAfterTrailingLineBreak(
        _ mutation: SyntaxEditorTextChange.Replacement,
        source: NSString,
        previousSourceLength: Int
    ) -> Bool {
        guard mutation.length == 0,
              mutation.location == previousSourceLength,
              previousSourceLength > 0 else {
            return false
        }
        return LineOffsetTable.containsLineBreak(
            source.substring(with: NSRange(location: previousSourceLength - 1, length: 1))
        )
    }

    private func lineIndex(containing location: Int, previousSourceLength: Int) -> Int {
        let clampedLocation = min(max(0, location), max(0, previousSourceLength - 1))
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if lines[midpoint].range.upperBound <= clampedLocation {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return min(lower, max(0, lines.count - 1))
    }

    private func replacementEndLineIndex(
        mutation: SyntaxEditorTextChange.Replacement,
        oldEnd: Int,
        previousSourceLength: Int
    ) -> Int {
        let endLookup = mutation.length == 0 ? mutation.location : max(mutation.location, oldEnd - 1)
        let endIndex = lineIndex(containing: endLookup, previousSourceLength: previousSourceLength)
        guard mutation.length > 0,
              oldEnd < previousSourceLength,
              endIndex + 1 < lines.count,
              oldEnd == lines[endIndex].range.upperBound else {
            return endIndex
        }
        return endIndex + 1
    }

    static func signaturesForChangedLines(
        _ mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString
    ) -> [ObjectiveCSemanticLineSignature] {
        guard source.length > 0 else { return [] }
        let changedLineRange = SyntaxHighlightMutationLineRange.changedLineRange(for: mutation, in: source)
        var signatures: [ObjectiveCSemanticLineSignature] = []
        var cursor = changedLineRange.location
        while cursor < changedLineRange.upperBound {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            signatures.append(signature(for: lineRange, in: source))
            let next = lineRange.upperBound
            guard next > cursor else { break }
            cursor = next
        }
        return signatures
    }

    fileprivate static func signature(
        for lineRange: NSRange,
        in source: NSString
    ) -> ObjectiveCSemanticLineSignature {
        let line = source.substring(with: lineRange) as NSString
        var hasher = Hasher()
        let contributes = ObjectiveCSyntaxOverlayTokenProvider.appendObjectiveCSemanticIndexSignature(
            from: line,
            lineOffset: lineRange.location,
            into: &hasher
        )
        let structuralEditRanges = contributes
            ? ObjectiveCSyntaxOverlayTokenProvider.objectiveCSemanticStructuralEditRanges(
                in: line,
                lineOffset: lineRange.location
            )
            : []
        return ObjectiveCSemanticLineSignature(
            range: lineRange,
            contributesToSignature: contributes,
            fingerprint: hasher.finalize(),
            structuralEditRanges: structuralEditRanges
        )
    }

    private static func fingerprint(for lines: [ObjectiveCSemanticLineSignature]) -> Int {
        var hasher = Hasher()
        for line in lines where line.contributesToSignature {
            hasher.combine(line.fingerprint)
        }
        return hasher.finalize()
    }
}

struct ObjectiveCSemanticIndex {
    let fileSymbols: ObjectiveCFileSymbolIndex
    let sourceUTF16Length: Int
    let structuralFingerprint: Int
    let structuralEditRanges: [NSRange]
    let lineSignatureIndex: ObjectiveCSemanticLineSignatureIndex

    func shifted(
        by mutation: SyntaxEditorTextChange.Replacement,
        source nextSource: NSString
    ) -> ObjectiveCSemanticIndex? {
        guard let shiftedSymbols = fileSymbols.shifted(
            by: mutation,
            sourceUTF16Length: nextSource.length
        ),
              Self.shiftedRanges(
                structuralEditRanges,
                by: mutation,
                sourceUTF16Length: nextSource.length
              ) != nil,
              let shiftedLineSignatureIndex = lineSignatureIndex.applying(
                mutation,
                to: nextSource
              ) else {
            return nil
        }
        return ObjectiveCSemanticIndex(
            fileSymbols: shiftedSymbols,
            sourceUTF16Length: nextSource.length,
            structuralFingerprint: shiftedLineSignatureIndex.fingerprint,
            structuralEditRanges: shiftedLineSignatureIndex.structuralEditRanges,
            lineSignatureIndex: shiftedLineSignatureIndex
        )
    }

    private static func shiftedRanges(
        _ ranges: [NSRange],
        by mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length nextSourceUTF16Length: Int
    ) -> [NSRange]? {
        var shiftedRanges: [NSRange] = []
        shiftedRanges.reserveCapacity(ranges.count)
        for range in ranges {
            guard let shiftedRange = shiftedRange(
                range,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
            ) else {
                return nil
            }
            shiftedRanges.append(shiftedRange)
        }
        return shiftedRanges
    }

    private static func shiftedRange(
        _ range: NSRange,
        by mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length nextSourceUTF16Length: Int
    ) -> NSRange? {
        let replacementLength = mutation.replacement.utf16.count
        let replacedRange = NSRange(location: mutation.location, length: mutation.length)
        let oldUpperBound = mutation.location + mutation.length
        let delta = replacementLength - mutation.length

        if range.upperBound <= mutation.location {
            return range
        }
        if mutation.length == 0,
           replacementLength > 0,
           range.location < mutation.location,
           mutation.location < range.upperBound {
            return nil
        }
        if range.location >= oldUpperBound {
            let shiftedLocation = range.location + delta
            guard shiftedLocation >= 0,
                  shiftedLocation + range.length <= nextSourceUTF16Length else {
                return nil
            }
            return NSRange(location: shiftedLocation, length: range.length)
        }
        if SyntaxEditorRangeUtilities.intersection(of: range, and: replacedRange).length > 0 {
            return nil
        }
        return range
    }
}
