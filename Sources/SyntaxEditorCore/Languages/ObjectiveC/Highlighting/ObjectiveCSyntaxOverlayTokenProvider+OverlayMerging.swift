import Foundation

extension ObjectiveCSyntaxOverlayTokenProvider {
    static func preparedOverlayInput(
        from tokens: [SyntaxEditorHighlighting.Token],
        source: NSString,
        targetRange: NSRange?,
        tokenPrefixMaxUpperBounds: [Int]? = nil,
        preparesFullIndex: Bool = true
    ) -> ObjectiveCOverlayPreparation {
        if let targetRange, !preparesFullIndex {
            return preparedPartialTaggedOverlayInput(
                from: tokens,
                source: source,
                targetRange: targetRange,
                tokenPrefixMaxUpperBounds: tokenPrefixMaxUpperBounds
            )
        }

        if targetRange != nil, tokens.contains(where: \.isSemanticOverlay) {
            return preparedTaggedOverlayInput(
                from: tokens,
                source: source,
                targetRange: targetRange,
                tokenPrefixMaxUpperBounds: tokenPrefixMaxUpperBounds,
                preparesFullIndex: preparesFullIndex
            )
        }

        let indexRange = preparesFullIndex ? nil : targetRange
        var syntaxIDsByRange: [ObjectiveCRangeKey: ObjectiveCSyntaxIDMask] = [:]
        for token in tokens where token.language == .objectiveC || token.language == nil {
            syntaxIDsByRange[ObjectiveCRangeKey(token.range), default: []]
                .formUnion(ObjectiveCSyntaxIDMask(syntaxID: token.syntaxID))
        }
        let preprocessorRanges = tokens.compactMap { token -> NSRange? in
            guard (token.language == .objectiveC || token.language == nil),
                  token.syntaxID == .preprocessor else {
                return nil
            }
            return token.range
        }

        var baseTokensForIndex: [SyntaxEditorHighlighting.Token] = []
        var outputBaseTokens: [SyntaxEditorHighlighting.Token] = []
        var preservedOverlayTokens: [SyntaxEditorHighlighting.Token] = []
        baseTokensForIndex.reserveCapacity(preparesFullIndex ? tokens.count : 256)
        outputBaseTokens.reserveCapacity(tokens.count)
        preservedOverlayTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            let syntaxIDs = syntaxIDsByRange[ObjectiveCRangeKey(token.range)] ?? []
            let preparesTokenForIndex = indexRange.map {
                rangesIntersect(token.range, $0)
            } ?? true
            let isOverlayToken = isObjectiveCSemanticOverlayToken(
                token,
                syntaxIDsAtSameRange: syntaxIDs,
                source: source,
                preprocessorRanges: preprocessorRanges,
                strippingSemanticOverlaysIn: nil
            )
            if preparesTokenForIndex && !isOverlayToken {
                baseTokensForIndex.append(token)
            }

            let stripsFromOutput = targetRange.map { stripRange in
                isObjectiveCSemanticOverlayToken(
                    token,
                    syntaxIDsAtSameRange: syntaxIDs,
                    source: source,
                    preprocessorRanges: preprocessorRanges,
                    strippingSemanticOverlaysIn: stripRange
                )
            } ?? isOverlayToken
            if !stripsFromOutput {
                if isOverlayToken {
                    preservedOverlayTokens.append(token)
                } else {
                    outputBaseTokens.append(token)
                }
            }
        }

        return ObjectiveCOverlayPreparation(
            baseTokensForIndex: baseTokensForIndex,
            outputBaseTokens: outputBaseTokens,
            preservedOverlayTokens: preservedOverlayTokens,
            nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex(
                tokens: baseTokensForIndex,
                sourceLength: source.length
            ),
            tokenIndex: ObjectiveCTokenIndex(tokens: baseTokensForIndex, source: source),
            partialMergeTargetRange: nil,
            partialMergeTokenRange: nil
        )
    }

    private static func preparedTaggedOverlayInput(
        from tokens: [SyntaxEditorHighlighting.Token],
        source: NSString,
        targetRange: NSRange?,
        tokenPrefixMaxUpperBounds: [Int]?,
        preparesFullIndex: Bool
    ) -> ObjectiveCOverlayPreparation {
        if let targetRange, !preparesFullIndex {
            return preparedPartialTaggedOverlayInput(
                from: tokens,
                source: source,
                targetRange: targetRange,
                tokenPrefixMaxUpperBounds: tokenPrefixMaxUpperBounds
            )
        }

        let indexRange = preparesFullIndex ? nil : targetRange
        var baseTokensForIndex: [SyntaxEditorHighlighting.Token] = []
        var outputBaseTokens: [SyntaxEditorHighlighting.Token] = []
        var preservedOverlayTokens: [SyntaxEditorHighlighting.Token] = []
        baseTokensForIndex.reserveCapacity(preparesFullIndex ? tokens.count : 256)
        outputBaseTokens.reserveCapacity(tokens.count)
        preservedOverlayTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            let preparesTokenForIndex = indexRange.map {
                rangesIntersect(token.range, $0)
            } ?? true
            if preparesTokenForIndex && !token.isSemanticOverlay {
                baseTokensForIndex.append(token)
            }

            let stripsFromOutput = targetRange.map {
                token.isSemanticOverlay && rangesIntersect(token.range, $0)
            } ?? token.isSemanticOverlay
            guard !stripsFromOutput else {
                continue
            }
            if token.isSemanticOverlay {
                preservedOverlayTokens.append(token)
            } else {
                outputBaseTokens.append(token)
            }
        }

        return ObjectiveCOverlayPreparation(
            baseTokensForIndex: baseTokensForIndex,
            outputBaseTokens: outputBaseTokens,
            preservedOverlayTokens: preservedOverlayTokens,
            nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex(
                tokens: baseTokensForIndex,
                sourceLength: source.length
            ),
            tokenIndex: ObjectiveCTokenIndex(tokens: baseTokensForIndex, source: source),
            partialMergeTargetRange: nil,
            partialMergeTokenRange: nil
        )
    }

    private static func preparedPartialTaggedOverlayInput(
        from tokens: [SyntaxEditorHighlighting.Token],
        source: NSString,
        targetRange: NSRange,
        tokenPrefixMaxUpperBounds: [Int]?
    ) -> ObjectiveCOverlayPreparation {
        let clampedTargetRange = SyntaxEditorRangeUtilities.clampedRange(
            targetRange,
            utf16Length: source.length
        )
        let tokenRange = tokenIndexRangeForPartialMerge(
            in: tokens,
            targetRange: clampedTargetRange,
            tokenPrefixMaxUpperBounds: tokenPrefixMaxUpperBounds
        )
        var baseTokensForIndex: [SyntaxEditorHighlighting.Token] = []
        baseTokensForIndex.reserveCapacity(tokenRange.count)

        for token in tokens[tokenRange] where !token.isSemanticOverlay {
            guard rangesIntersect(token.range, clampedTargetRange) else { continue }
            baseTokensForIndex.append(token)
        }

        return ObjectiveCOverlayPreparation(
            baseTokensForIndex: baseTokensForIndex,
            outputBaseTokens: [],
            preservedOverlayTokens: [],
            nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex(
                tokens: baseTokensForIndex,
                sourceLength: source.length
            ),
            tokenIndex: ObjectiveCTokenIndex(tokens: baseTokensForIndex, source: source),
            partialMergeTargetRange: clampedTargetRange,
            partialMergeTokenRange: tokenRange
        )
    }

    static func mergedTokens(
        baseTokens: [SyntaxEditorHighlighting.Token],
        overlayTokens: [SyntaxEditorHighlighting.Token]
    ) -> [SyntaxEditorHighlighting.Token] {
        let annotatedTokens = baseTokens.map { (token: $0, isOverlay: false) }
            + overlayTokens.map { (token: $0, isOverlay: true) }

        return annotatedTokens.sorted { lhs, rhs in
            if lhs.token.range.location != rhs.token.range.location {
                return lhs.token.range.location < rhs.token.range.location
            }
            if lhs.token.range.length != rhs.token.range.length {
                return lhs.token.range.length > rhs.token.range.length
            }
            if lhs.isOverlay != rhs.isOverlay {
                return !lhs.isOverlay && rhs.isOverlay
            }
            return SyntaxHighlightTokenOrdering.displayOrder(lhs.token, rhs.token)
        }.map(\.token)
    }

    static func partialMergedTokens(
        existingTokens: [SyntaxEditorHighlighting.Token],
        replacementOverlayTokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        tokenRange: Range<Int>
    ) -> [SyntaxEditorHighlighting.Token] {
        var baseSegment: [SyntaxEditorHighlighting.Token] = []
        var overlaySegment: [SyntaxEditorHighlighting.Token] = []
        baseSegment.reserveCapacity(tokenRange.count)
        overlaySegment.reserveCapacity(tokenRange.count + replacementOverlayTokens.count)
        for token in existingTokens[tokenRange] {
            if token.isSemanticOverlay {
                guard !rangesIntersect(token.range, targetRange) else {
                    continue
                }
                overlaySegment.append(token)
            } else {
                baseSegment.append(token)
            }
        }
        overlaySegment.append(contentsOf: replacementOverlayTokens)
        let segment = deduplicated(mergedTokens(baseTokens: baseSegment, overlayTokens: overlaySegment))

        var merged = existingTokens
        merged.replaceSubrange(tokenRange, with: segment)
        return merged
    }

    private static func tokenIndexRangeForPartialMerge(
        in tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        tokenPrefixMaxUpperBounds: [Int]?
    ) -> Range<Int> {
        guard targetRange.length > 0 else { return 0..<0 }

        let prefixMaxUpperBounds = if let tokenPrefixMaxUpperBounds,
                                      tokenPrefixMaxUpperBounds.count == tokens.count {
            tokenPrefixMaxUpperBounds
        } else {
            prefixMaxUpperBounds(for: tokens)
        }
        let startIndex = firstTokenIndex(
            intersecting: targetRange,
            prefixMaxUpperBounds: prefixMaxUpperBounds
        )
        var upperBound = lowerBoundForTokenLocation(targetRange.upperBound, in: tokens)
        while upperBound < tokens.count,
              tokens[upperBound].range.location < targetRange.upperBound {
            upperBound += 1
        }
        return startIndex..<upperBound
    }

    private static func prefixMaxUpperBounds(for tokens: [SyntaxEditorHighlighting.Token]) -> [Int] {
        var prefixMaxUpperBounds: [Int] = []
        prefixMaxUpperBounds.reserveCapacity(tokens.count)
        var maxUpperBound = 0
        for token in tokens {
            maxUpperBound = max(maxUpperBound, token.range.upperBound)
            prefixMaxUpperBounds.append(maxUpperBound)
        }
        return prefixMaxUpperBounds
    }

    private static func firstTokenIndex(
        intersecting range: NSRange,
        prefixMaxUpperBounds: [Int]
    ) -> Int {
        var lowerBound = 0
        var upperBound = prefixMaxUpperBounds.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if prefixMaxUpperBounds[middle] <= range.location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func lowerBoundForTokenLocation(
        _ location: Int,
        in tokens: [SyntaxEditorHighlighting.Token]
    ) -> Int {
        var lowerBound = 0
        var upperBound = tokens.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if tokens[middle].range.location < location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    static func deduplicated(_ tokens: [SyntaxEditorHighlighting.Token]) -> [SyntaxEditorHighlighting.Token] {
        var seen = Set<ObjectiveCTokenKey>()
        var unique: [SyntaxEditorHighlighting.Token] = []
        unique.reserveCapacity(tokens.count)

        for token in tokens {
            let key = ObjectiveCTokenKey(token)
            guard seen.insert(key).inserted else { continue }
            unique.append(token)
        }
        return unique
    }
}
