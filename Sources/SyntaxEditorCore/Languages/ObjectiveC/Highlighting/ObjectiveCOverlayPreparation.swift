import Foundation

struct ObjectiveCOverlayPreparation {
    let baseTokensForIndex: [SyntaxEditorHighlighting.Token]
    let outputBaseTokens: [SyntaxEditorHighlighting.Token]
    let preservedOverlayTokens: [SyntaxEditorHighlighting.Token]
    let nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex
    let tokenIndex: ObjectiveCTokenIndex
    let partialMergeTargetRange: NSRange?
    let partialMergeTokenRange: Range<Int>?
}


struct ObjectiveCNonCodeRangeIndex {
    let ranges: [NSRange]

    init(ranges: [NSRange]) {
        self.ranges = Self.normalized(ranges)
    }

    init(tokens: [SyntaxEditorHighlighting.Token], sourceLength: Int) {
        self.init(ranges: tokens.compactMap { token -> NSRange? in
            guard token.language == .objectiveC || token.language == nil else {
                return nil
            }
            switch token.syntaxID {
            case .comment, .string, .character:
                return SyntaxEditorRangeUtilities.clampedRange(token.range, utf16Length: sourceLength)
            default:
                return nil
            }
        })
    }

    func intersects(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        let index = lowerBoundForRangeEnding(after: range.location)
        guard index < ranges.count else { return false }
        return SyntaxEditorRangeUtilities.intersection(of: range, and: ranges[index]).length > 0
    }

    func contains(_ location: Int) -> Bool {
        guard location >= 0 else { return false }
        let index = lowerBoundForRangeEnding(after: location)
        guard index < ranges.count else { return false }
        let range = ranges[index]
        return range.location <= location && location < range.upperBound
    }

    func upperBoundOfRange(containing location: Int) -> Int? {
        guard location >= 0 else { return nil }
        let index = lowerBoundForRangeEnding(after: location)
        guard index < ranges.count else { return nil }
        let range = ranges[index]
        guard range.location <= location && location < range.upperBound else { return nil }
        return range.upperBound
    }

    private func lowerBoundForRangeEnding(after location: Int) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if ranges[midpoint].upperBound <= location {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    private static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        let sortedRanges = ranges
            .filter { $0.length > 0 }
            .sorted {
                if $0.location != $1.location {
                    return $0.location < $1.location
                }
                return $0.length < $1.length
            }
        guard var current = sortedRanges.first else { return [] }
        var result: [NSRange] = []
        for range in sortedRanges.dropFirst() {
            if range.location <= current.upperBound {
                let upperBound = max(current.upperBound, range.upperBound)
                current = NSRange(location: current.location, length: upperBound - current.location)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}

struct ObjectiveCIndexedToken {
    let range: NSRange
    let syntaxID: EditorSourceSyntax.ID
}

struct ObjectiveCTokenIndex {
    let identifierTokens: [ObjectiveCIndexedToken]
    private let declarationOtherIdentifierRanges: [NSRange]
    private let propertyKeywordRangeKeys: Set<ObjectiveCRangeKey>
    private let identifierRangeKeys: Set<ObjectiveCRangeKey>

    init(tokens: [SyntaxEditorHighlighting.Token], source: NSString) {
        var identifierTokens: [ObjectiveCIndexedToken] = []
        var declarationOtherIdentifierRanges: [NSRange] = []
        var propertyKeywordRangeKeys = Set<ObjectiveCRangeKey>()
        var identifierRangeKeys = Set<ObjectiveCRangeKey>()
        identifierTokens.reserveCapacity(tokens.count)
        declarationOtherIdentifierRanges.reserveCapacity(tokens.count / 12)

        for token in tokens where token.language == .objectiveC || token.language == nil {
            guard token.range.location >= 0,
                  token.range.length > 0,
                  token.range.upperBound <= source.length else {
                continue
            }
            if token.range.length == "@property".utf16.count,
               source.substring(with: token.range) == "@property" {
                propertyKeywordRangeKeys.insert(ObjectiveCRangeKey(token.range))
            }
            guard ObjectiveCFileSymbolIndex.isIdentifierRange(token.range, in: source) else {
                continue
            }
            identifierRangeKeys.insert(ObjectiveCRangeKey(token.range))
            let indexedToken = ObjectiveCIndexedToken(range: token.range, syntaxID: token.syntaxID)
            identifierTokens.append(indexedToken)
            if token.syntaxID == .declarationOther {
                declarationOtherIdentifierRanges.append(token.range)
            }
        }

        self.identifierTokens = identifierTokens
        self.declarationOtherIdentifierRanges = declarationOtherIdentifierRanges.sorted {
            if $0.location != $1.location {
                return $0.location < $1.location
            }
            return $0.length < $1.length
        }
        self.propertyKeywordRangeKeys = propertyKeywordRangeKeys
        self.identifierRangeKeys = identifierRangeKeys
    }

    func declarationOtherIdentifierRanges(in range: NSRange) -> [NSRange] {
        var index = lowerBoundForDeclarationOtherIdentifier(location: range.location)
        var ranges: [NSRange] = []
        while index < declarationOtherIdentifierRanges.count {
            let candidate = declarationOtherIdentifierRanges[index]
            guard candidate.location < range.upperBound else {
                break
            }
            if candidate.location >= range.location,
               candidate.upperBound <= range.upperBound {
                ranges.append(candidate)
            }
            index += 1
        }
        return ranges
    }

    func containsPropertyKeywordRange(_ range: NSRange) -> Bool {
        propertyKeywordRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsIdentifierRange(_ range: NSRange) -> Bool {
        identifierRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    private func lowerBoundForDeclarationOtherIdentifier(location: Int) -> Int {
        var lower = 0
        var upper = declarationOtherIdentifierRanges.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if declarationOtherIdentifierRanges[midpoint].location < location {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }
}
