import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport

package enum CSSSyntaxOverlayTokenProvider {
    package static func mergingOverlayTokens(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        scanningRanges requestedScanningRanges: [NSRange]? = nil
    ) -> [SyntaxEditorHighlighting.Token] {
        let nsSource = source as NSString
        let scanningRanges = normalizedScanningRanges(
            requestedScanningRanges,
            sourceUTF16Length: nsSource.length
        )
        let sourceLocalOverlayContexts = scanningRanges.map {
            sourceLocalOverlayContext(in: nsSource, scanningRange: $0)
        }
        let nestedSelectorRanges = sourceLocalOverlayContexts.flatMap(\.nestedSelectorRanges)
        let pseudoFunctionArgumentRanges = sourceLocalOverlayContexts.flatMap(\.pseudoFunctionArgumentRanges)
        let keywordTokenRanges = tokens
            .filter { $0.language == .css && $0.syntaxID == .keyword }
            .map(\.range)
        let sourceLocalOverlayTokens = sourceLocalOverlayContexts
            .flatMap(\.tokens)
            .filter {
                !isSourceLocalOverlayTokenSuppressedByKeyword(
                    $0,
                    keywordTokenRanges: keywordTokenRanges
                )
            }
        let baseTokens = tokens.filter { token in
            !isCSSSourceLocalOverlayToken(token)
                && !isBasePlainTokenCoveredBySourceLocalOverlay(
                    token,
                    overlayTokens: sourceLocalOverlayTokens
                )
                && !isPseudoClassArgumentDeclarationToken(
                    token,
                    argumentRanges: pseudoFunctionArgumentRanges
                )
                && !isConditionalAtRuleSelectorDeclarationToken(
                    token,
                    nestedSelectorRanges: nestedSelectorRanges,
                    sourceUTF16Length: nsSource.length
                )
        }
        guard sourceLocalOverlayTokens.isEmpty == false else {
            return baseTokens
        }
        let overlayTokens = sourceLocalOverlayTokens.map {
            canonicalToken(range: $0.range, syntaxID: $0.syntaxID)
        }

        return deduplicated(
            SyntaxHighlightTokenOrdering.mergedSorted(base: baseTokens, overlays: overlayTokens) { lhs, _, rhs, _ in
                SyntaxHighlightTokenOrdering.displayOrder(lhs, rhs)
            }
        )
    }

    private static func sourceLocalOverlayContext(
        in source: NSString,
        scanningRange: NSRange
    ) -> SourceLocalOverlayContext {
        let scanSource = sourceForScanning(in: source, scanningRanges: [scanningRange])
        let nestedSelectorRanges = conditionalAtRuleNestedSelectorRanges(in: scanSource)
            .filter { rangesIntersect($0, scanningRange) }
        let supportsPreludeRanges = atRulePreludeRanges(keyword: "@supports", in: scanSource)
            .filter { rangesIntersect($0, scanningRange) }
        let pseudoFunctionArgumentRanges = pseudoClassArgumentRanges(in: scanSource)
            .filter { rangesIntersect($0, scanningRange) }
        let tokens = (
            nestedSelectorRanges.map {
                SourceLocalOverlayToken(range: $0, syntaxID: .plain)
            } +
            supportsAtRulePreludeTokens(
                in: scanSource,
                preludeRanges: supportsPreludeRanges
            ) +
            atRuleDeclarationTokens(in: scanSource) +
            namedAtRulePreludeDeclarationTokens(in: scanSource) +
            keyframesNameDeclarationTokens(in: scanSource) +
            containerAtRulePreludeTokens(
                in: scanSource,
                excluding: nestedSelectorRanges
            ) +
            pseudoClassDeclarationTokens(
                in: scanSource,
                excluding: supportsPreludeRanges + nestedSelectorRanges
            )
        )
        .filter { rangesIntersect($0.range, scanningRange) }

        return SourceLocalOverlayContext(
            tokens: tokens,
            nestedSelectorRanges: nestedSelectorRanges,
            pseudoFunctionArgumentRanges: pseudoFunctionArgumentRanges
        )
    }

    private static func normalizedScanningRanges(
        _ requestedScanningRanges: [NSRange]?,
        sourceUTF16Length: Int
    ) -> [NSRange] {
        let ranges = requestedScanningRanges ?? [NSRange(location: 0, length: sourceUTF16Length)]
        return ranges.compactMap {
            let range = SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: sourceUTF16Length)
            return range.length > 0 ? range : nil
        }
    }

    private static func sourceForScanning(in source: NSString, scanningRanges: [NSRange]) -> NSString {
        guard scanningRanges.count != 1 ||
            scanningRanges[0].location != 0 ||
            scanningRanges[0].length != source.length
        else {
            return source
        }

        let maskedSource = NSMutableString(string: String(repeating: " ", count: source.length))
        for range in scanningRanges {
            maskedSource.replaceCharacters(in: range, with: source.substring(with: range))
        }
        return maskedSource
    }

    private static func atRuleDeclarationTokens(in source: NSString) -> [SourceLocalOverlayToken] {
        var tokens: [SourceLocalOverlayToken] = []
        var location = 0
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard isAtRuleStart(at: location, in: source) else {
                location += 1
                continue
            }

            var nameEnd = location + 2
            while nameEnd < source.length, isIdentifierUnitCharacter(source.character(at: nameEnd)) {
                nameEnd += 1
            }
            tokens.append(SourceLocalOverlayToken(
                range: NSRange(location: location, length: nameEnd - location),
                syntaxID: .declarationOther,
                suppressWhenKeywordTokenExists: true
            ))
            location = nameEnd
        }
        return tokens
    }

    private static func namedAtRulePreludeDeclarationTokens(in source: NSString) -> [SourceLocalOverlayToken] {
        var tokens: [SourceLocalOverlayToken] = []
        var location = 0
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard let keyword = namedAtRule(at: location, in: source) else {
                location += 1
                continue
            }

            let keywordEnd = min(location + (keyword as NSString).length, source.length)
            let statementEnd = locationAfterStatement(at: location, in: source)
            let blockOpen = findBlockOpen(after: location, in: source)
            let preludeEnd = blockOpen.map { min($0, statementEnd) } ?? statementEnd
            if keywordEnd < preludeEnd {
                tokens.append(contentsOf: declarationIdentifierTokens(
                    in: NSRange(location: keywordEnd, length: preludeEnd - keywordEnd),
                    source: source,
                    suppressWhenKeywordTokenExists: true
                ))
            }

            if let blockOpen,
               blockOpen < statementEnd,
               let blockEnd = locationAfterBlock(openedAt: blockOpen, in: source) {
                location = blockEnd
            } else {
                location = max(keywordEnd, statementEnd)
            }
        }
        return tokens
    }

    private static func conditionalAtRuleNestedSelectorRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard matchesConditionalAtRule(at: location, in: source)
                    || matchesSelectorGroupingAtRule(at: location, in: source),
                  let blockOpen = findBlockOpen(after: location, in: source),
                  let scan = collectNestedSelectorRanges(inBlockOpenedAt: blockOpen, source: source)
            else {
                location += 1
                continue
            }

            if matchesScopeAtRule(at: location, in: source),
               let preludeRange = trimmedRange(
                   location: min(location + ("@scope" as NSString).length, source.length),
                   upperBound: blockOpen,
                   in: source
               ) {
                ranges.append(preludeRange)
            }
            ranges.append(contentsOf: scan.ranges)
            location = scan.endLocation
        }
        return ranges
    }

    private static func containerAtRulePreludeTokens(
        in source: NSString,
        excluding excludedRanges: [NSRange]
    ) -> [SourceLocalOverlayToken] {
        var tokens: [SourceLocalOverlayToken] = []
        var location = 0
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard matches("@container", at: location, in: source) else {
                location += 1
                continue
            }

            let blockOpen = findBlockOpen(after: location, in: source)
            let preludeStart = min(location + ("@container" as NSString).length, source.length)
            let preludeEnd = blockOpen ?? locationAfterStatement(at: location, in: source)
            tokens.append(SourceLocalOverlayToken(
                range: NSRange(location: location, length: preludeStart - location),
                syntaxID: .declarationOther
            ))
            if preludeStart < preludeEnd {
                let preludeRange = NSRange(location: preludeStart, length: preludeEnd - preludeStart)
                tokens.append(contentsOf: containerPreludeDeclarationTokens(
                    in: preludeRange,
                    source: source
                ))
                tokens.append(contentsOf: dimensionTokens(in: preludeRange, source: source))
                tokens.append(contentsOf: keywordIdentifierTokens(in: preludeRange, source: source))
            }
            if let blockOpen,
               let blockEnd = locationAfterBlock(openedAt: blockOpen, in: source),
               blockOpen + 1 < blockEnd - 1 {
                tokens.append(contentsOf: keywordIdentifierTokens(
                    in: NSRange(location: blockOpen + 1, length: blockEnd - blockOpen - 2),
                    source: source,
                    excluding: excludedRanges
                ))
            }
            location = blockOpen.map { $0 + 1 } ?? max(location + ("@container" as NSString).length, preludeEnd)
        }
        return tokens
    }

    private static func keyframesNameDeclarationTokens(in source: NSString) -> [SourceLocalOverlayToken] {
        var tokens: [SourceLocalOverlayToken] = []
        var location = 0
        var blockDepth = 0

        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            let character = source.character(at: location)
            if character == ascii("{") {
                blockDepth += 1
                location += 1
                continue
            }
            if character == ascii("}") {
                blockDepth = max(0, blockDepth - 1)
                location += 1
                continue
            }

            guard blockDepth == 0,
                  matches("@keyframes", at: location, in: source)
            else {
                location += 1
                continue
            }

            let keywordEnd = min(location + ("@keyframes" as NSString).length, source.length)
            let nameStart = locationAfterSkippingWhitespaceAndComments(at: keywordEnd, in: source)
            guard nameStart < source.length,
                  isCSSIdentifierStart(at: nameStart, upperBound: source.length, source: source)
            else {
                location = keywordEnd
                continue
            }

            var nameEnd = nameStart + 1
            while nameEnd < source.length, isIdentifierUnitCharacter(source.character(at: nameEnd)) {
                nameEnd += 1
            }
            tokens.append(SourceLocalOverlayToken(
                range: NSRange(location: nameStart, length: nameEnd - nameStart),
                syntaxID: .declarationOther,
                suppressWhenKeywordTokenExists: true
            ))
            location = nameEnd
        }

        return tokens
    }

    private static func supportsAtRulePreludeTokens(
        in source: NSString,
        preludeRanges: [NSRange]
    ) -> [SourceLocalOverlayToken] {
        preludeRanges.flatMap {
            functionIdentifierTokens(
                in: $0,
                source: source,
                names: xcodeDeclarationSupportFunctions,
                syntaxID: .declarationOther,
                skippingWhenAfterTopLevelNot: true
            )
            + keywordIdentifierTokens(in: $0, source: source)
        }
    }

    private static func containerPreludeDeclarationTokens(
        in range: NSRange,
        source: NSString
    ) -> [SourceLocalOverlayToken] {
        let upperBound = min(range.upperBound, source.length)
        var tokens: [SourceLocalOverlayToken] = []
        var location = max(0, range.location)
        var parenthesisDepth = 0
        var hasSeenBooleanOperator = false

        while location < upperBound {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = min(skipLocation, upperBound)
                continue
            }

            let character = source.character(at: location)
            if character == ascii("(") {
                parenthesisDepth += 1
                location += 1
                continue
            }
            if character == ascii(")") {
                parenthesisDepth = max(0, parenthesisDepth - 1)
                location += 1
                continue
            }
            guard parenthesisDepth == 0,
                  isCSSIdentifierStart(at: location, upperBound: upperBound, source: source)
            else {
                location += 1
                continue
            }

            let identifierStart = location
            location += 1
            while location < upperBound, isIdentifierUnitCharacter(source.character(at: location)) {
                location += 1
            }
            let identifierRange = NSRange(location: identifierStart, length: location - identifierStart)
            let identifier = source.substring(with: identifierRange).lowercased()
            guard !containerPreludeBooleanOperators.contains(identifier) else {
                hasSeenBooleanOperator = true
                continue
            }
            guard !hasSeenBooleanOperator else {
                continue
            }
            tokens.append(SourceLocalOverlayToken(
                range: identifierRange,
                syntaxID: .declarationOther
            ))
        }

        return tokens
    }

    private static func declarationIdentifierTokens(
        in range: NSRange,
        source: NSString,
        suppressWhenKeywordTokenExists: Bool = false
    ) -> [SourceLocalOverlayToken] {
        let upperBound = min(range.upperBound, source.length)
        var tokens: [SourceLocalOverlayToken] = []
        var location = max(0, range.location)

        while location < upperBound {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = min(skipLocation, upperBound)
                continue
            }
            guard isCSSIdentifierStart(at: location, upperBound: upperBound, source: source) else {
                location += 1
                continue
            }

            let identifierStart = location
            location += 1
            while location < upperBound, isIdentifierUnitCharacter(source.character(at: location)) {
                location += 1
            }
            tokens.append(SourceLocalOverlayToken(
                range: NSRange(location: identifierStart, length: location - identifierStart),
                syntaxID: .declarationOther,
                suppressWhenKeywordTokenExists: suppressWhenKeywordTokenExists
            ))
        }

        return tokens
    }

    private static func pseudoClassDeclarationTokens(
        in source: NSString,
        excluding excludedRanges: [NSRange]
    ) -> [SourceLocalOverlayToken] {
        var tokens: [SourceLocalOverlayToken] = []
        var location = 0
        let selectorRanges = ruleSelectorRanges(in: source)
        var selectorRangeIndex = 0
        let sortedExcludedRanges = excludedRanges.sorted { $0.location < $1.location }
        var excludedRangeIndex = 0

        while location < source.length {
            while selectorRangeIndex < selectorRanges.count,
                  selectorRanges[selectorRangeIndex].upperBound <= location {
                selectorRangeIndex += 1
            }
            guard selectorRangeIndex < selectorRanges.count else {
                break
            }
            let selectorRange = selectorRanges[selectorRangeIndex]
            if location < selectorRange.location {
                location = selectorRange.location
                continue
            }

            while excludedRangeIndex < sortedExcludedRanges.count,
                  sortedExcludedRanges[excludedRangeIndex].upperBound <= location {
                excludedRangeIndex += 1
            }
            if excludedRangeIndex < sortedExcludedRanges.count,
               sortedExcludedRanges[excludedRangeIndex].location <= location {
                location = sortedExcludedRanges[excludedRangeIndex].upperBound
                continue
            }

            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard source.character(at: location) == ascii(":") else {
                location += 1
                continue
            }

            var nameStart = location + 1
            if nameStart < source.length, source.character(at: nameStart) == ascii(":") {
                nameStart += 1
            }
            guard nameStart < source.length,
                  isIdentifierStartCharacter(source.character(at: nameStart))
            else {
                location += 1
                continue
            }

            var nameEnd = nameStart + 1
            while nameEnd < source.length, isIdentifierUnitCharacter(source.character(at: nameEnd)) {
                nameEnd += 1
            }
            guard nameEnd <= selectorRange.upperBound else {
                location = selectorRange.upperBound
                continue
            }
            let nameRange = NSRange(location: nameStart, length: nameEnd - nameStart)
            let name = source.substring(with: nameRange).lowercased()
            if xcodeKeywordPseudoClasses.contains(name) {
                tokens.append(SourceLocalOverlayToken(range: nameRange, syntaxID: .keyword))
            } else if xcodeDeclarationPseudoClasses.contains(name) {
                tokens.append(SourceLocalOverlayToken(range: nameRange, syntaxID: .declarationOther))
            }
            location = nameEnd
        }

        return tokens
    }

    private static func pseudoClassArgumentRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0

        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard source.character(at: location) == ascii(":") else {
                location += 1
                continue
            }

            var nameStart = location + 1
            if nameStart < source.length, source.character(at: nameStart) == ascii(":") {
                nameStart += 1
            }
            guard nameStart < source.length,
                  isIdentifierStartCharacter(source.character(at: nameStart))
            else {
                location += 1
                continue
            }

            var nameEnd = nameStart + 1
            while nameEnd < source.length, isIdentifierUnitCharacter(source.character(at: nameEnd)) {
                nameEnd += 1
            }
            let name = source.substring(with: NSRange(location: nameStart, length: nameEnd - nameStart))
            guard xcodeDeclarationPseudoClasses.contains(name.lowercased()),
                  nameEnd < source.length,
                  source.character(at: nameEnd) == ascii("("),
                  let argumentEnd = matchingCloseParenthesis(openedAt: nameEnd, in: source),
                  nameEnd + 1 < argumentEnd
            else {
                location = nameEnd
                continue
            }

            ranges.append(NSRange(location: nameEnd + 1, length: argumentEnd - nameEnd - 1))
            location = argumentEnd + 1
        }

        return ranges
    }

    private static func atRulePreludeRanges(keyword: String, in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            guard matches(keyword, at: location, in: source) else {
                location += 1
                continue
            }

            let keywordLength = (keyword as NSString).length
            if let blockOpen = findBlockOpen(after: location, in: source) {
                ranges.append(NSRange(location: location, length: blockOpen - location))
                location = blockOpen + 1
            } else {
                let end = locationAfterStatement(at: location, in: source)
                ranges.append(NSRange(location: location, length: max(0, end - location)))
                location = max(location + keywordLength, end)
            }
        }
        return ranges
    }

    private static func functionIdentifierTokens(
        in range: NSRange,
        source: NSString,
        names: Set<String>,
        syntaxID: EditorSourceSyntax.ID,
        skippingWhenAfterTopLevelNot: Bool = false
    ) -> [SourceLocalOverlayToken] {
        let upperBound = min(range.upperBound, source.length)
        var tokens: [SourceLocalOverlayToken] = []
        var location = max(0, range.location)
        var parenthesisDepth = 0
        var lastTopLevelIdentifier: String?

        while location < upperBound {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = min(skipLocation, upperBound)
                continue
            }

            let character = source.character(at: location)
            if character == ascii("(") {
                parenthesisDepth += 1
                location += 1
                continue
            }
            if character == ascii(")") {
                parenthesisDepth = max(0, parenthesisDepth - 1)
                location += 1
                continue
            }

            guard isIdentifierStartCharacter(source.character(at: location)) else {
                location += 1
                continue
            }

            let identifierStart = location
            location += 1
            while location < upperBound, isIdentifierUnitCharacter(source.character(at: location)) {
                location += 1
            }

            let identifierRange = NSRange(location: identifierStart, length: location - identifierStart)
            let identifier = source.substring(with: identifierRange).lowercased()
            let nextLocation = locationAfterSkippingWhitespace(at: location, upperBound: upperBound, in: source)
            if names.contains(identifier),
               nextLocation < upperBound,
               source.character(at: nextLocation) == ascii("("),
               !(skippingWhenAfterTopLevelNot && lastTopLevelIdentifier == "not") {
                tokens.append(SourceLocalOverlayToken(range: identifierRange, syntaxID: syntaxID))
            }
            if parenthesisDepth == 0 {
                lastTopLevelIdentifier = identifier
            }
        }

        return tokens
    }

    private static func dimensionTokens(
        in range: NSRange,
        source: NSString
    ) -> [SourceLocalOverlayToken] {
        let upperBound = min(range.upperBound, source.length)
        var tokens: [SourceLocalOverlayToken] = []
        var location = max(0, range.location)

        while location < upperBound {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = min(skipLocation, upperBound)
                continue
            }

            let numberStart = location
            let character = source.character(at: location)
            if isCSSNumberStart(at: location, upperBound: upperBound, source: source) {
                if character == ascii("+") || character == ascii("-") {
                    location += 1
                }
                location = locationAfterNumberStarting(at: location, upperBound: upperBound, source: source)
            } else if isIdentifierUnitCharacter(character) {
                location = locationAfterIdentifierUnitRunStarting(at: location, upperBound: upperBound, source: source)
                continue
            } else {
                location += 1
                continue
            }

            if location < upperBound, source.character(at: location) == ascii("%") {
                location += 1
                tokens.append(SourceLocalOverlayToken(
                    range: NSRange(location: numberStart, length: location - numberStart),
                    syntaxID: .number
                ))
                continue
            }

            tokens.append(SourceLocalOverlayToken(
                range: NSRange(location: numberStart, length: location - numberStart),
                syntaxID: .number
            ))

            let unitStart = location
            while location < upperBound, isIdentifierUnitCharacter(source.character(at: location)) {
                location += 1
            }
            if location > unitStart {
                let unit = source.substring(with: NSRange(location: unitStart, length: location - unitStart))
                tokens.append(SourceLocalOverlayToken(
                    range: NSRange(location: unitStart, length: location - unitStart),
                    syntaxID: xcodeKeywordUnits.contains(unit) ? .keyword : .plain
                ))
            }
        }

        return tokens
    }

    private static func keywordIdentifierTokens(
        in range: NSRange,
        source: NSString,
        excluding excludedRanges: [NSRange] = []
    ) -> [SourceLocalOverlayToken] {
        let upperBound = min(range.upperBound, source.length)
        let sortedExcludedRanges = excludedRanges
            .filter { $0.location != NSNotFound && rangesIntersect($0, range) }
            .sorted { $0.location < $1.location }
        var excludedRangeIndex = 0
        var tokens: [SourceLocalOverlayToken] = []
        var location = max(0, range.location)

        while location < upperBound {
            while excludedRangeIndex < sortedExcludedRanges.count,
                  sortedExcludedRanges[excludedRangeIndex].upperBound <= location {
                excludedRangeIndex += 1
            }
            if excludedRangeIndex < sortedExcludedRanges.count,
               sortedExcludedRanges[excludedRangeIndex].location <= location {
                location = min(sortedExcludedRanges[excludedRangeIndex].upperBound, upperBound)
                continue
            }

            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = min(skipLocation, upperBound)
                continue
            }

            guard isIdentifierStartCharacter(source.character(at: location)) else {
                if isIdentifierUnitCharacter(source.character(at: location)) {
                    location = locationAfterIdentifierUnitRunStarting(at: location, upperBound: upperBound, source: source)
                } else {
                    location += 1
                }
                continue
            }
            guard location == range.location || !isIdentifierUnitCharacter(source.character(at: location - 1)) else {
                location = locationAfterIdentifierUnitRunStarting(at: location, upperBound: upperBound, source: source)
                continue
            }

            let identifierStart = location
            location += 1
            while location < upperBound, isIdentifierUnitCharacter(source.character(at: location)) {
                location += 1
            }

            let range = NSRange(location: identifierStart, length: location - identifierStart)
            if xcodeKeywordIdentifiers.contains(source.substring(with: range)) {
                tokens.append(SourceLocalOverlayToken(range: range, syntaxID: .keyword))
            }
        }

        return tokens
    }

    private static func isCSSNumberStart(
        at location: Int,
        upperBound: Int,
        source: NSString
    ) -> Bool {
        let character = source.character(at: location)
        if isDigit(character) {
            return true
        }
        if character == ascii(".") {
            return location + 1 < upperBound && isDigit(source.character(at: location + 1))
        }
        if character == ascii("+") || character == ascii("-") {
            return location + 1 < upperBound
                && isUnsignedCSSNumberStart(at: location + 1, upperBound: upperBound, source: source)
        }
        return false
    }

    private static func isUnsignedCSSNumberStart(
        at location: Int,
        upperBound: Int,
        source: NSString
    ) -> Bool {
        let character = source.character(at: location)
        if isDigit(character) {
            return true
        }
        return character == ascii(".")
            && location + 1 < upperBound
            && isDigit(source.character(at: location + 1))
    }

    private static func locationAfterNumberStarting(
        at location: Int,
        upperBound: Int,
        source: NSString
    ) -> Int {
        var scan = location
        var consumedDecimalSeparator = false
        while scan < upperBound {
            let character = source.character(at: scan)
            if isDigit(character) {
                scan += 1
            } else if character == ascii("."), !consumedDecimalSeparator {
                consumedDecimalSeparator = true
                scan += 1
            } else {
                break
            }
        }
        return scan
    }

    private static func locationAfterIdentifierUnitRunStarting(
        at location: Int,
        upperBound: Int,
        source: NSString
    ) -> Int {
        var scan = location
        while scan < upperBound, isIdentifierUnitCharacter(source.character(at: scan)) {
            scan += 1
        }
        return scan
    }

    private static func ruleSelectorRanges(in source: NSString) -> [NSRange] {
        collectRuleSelectorRanges(
            location: 0,
            upperBound: source.length,
            source: source
        )
    }

    private static func collectRuleSelectorRanges(
        location initialLocation: Int,
        upperBound: Int,
        source: NSString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = initialLocation

        while location < upperBound {
            location = locationAfterSkippingWhitespaceAndComments(at: location, in: source)
            guard location < upperBound else {
                break
            }
            if source.character(at: location) == ascii("}") {
                return ranges
            }

            if source.character(at: location) == ascii("@") {
                guard let nestedOpen = findBlockOpen(after: location, in: source),
                      nestedOpen < upperBound
                else {
                    location = min(locationAfterStatement(at: location, in: source), upperBound)
                    continue
                }
                if matchesConditionalAtRule(at: location, in: source)
                    || matchesSelectorGroupingAtRule(at: location, in: source),
                   let blockEnd = locationAfterBlock(openedAt: nestedOpen, in: source) {
                    ranges.append(contentsOf: collectRuleSelectorRanges(
                        location: nestedOpen + 1,
                        upperBound: min(blockEnd - 1, upperBound),
                        source: source
                    ))
                    location = min(blockEnd, upperBound)
                } else {
                    location = min(locationAfterBlock(openedAt: nestedOpen, in: source) ?? (nestedOpen + 1), upperBound)
                }
                continue
            }

            let selectorStart = location
            guard let blockOpen = findBlockOpen(after: selectorStart, in: source),
                  blockOpen < upperBound
            else {
                return ranges
            }
            if let range = trimmedRange(location: selectorStart, upperBound: blockOpen, in: source) {
                ranges.append(range)
            }
            ranges.append(contentsOf: collectNestedStyleRuleSelectorRanges(
                inBlockOpenedAt: blockOpen,
                source: source
            ))
            location = min(locationAfterBlock(openedAt: blockOpen, in: source) ?? (blockOpen + 1), upperBound)
        }

        return ranges
    }

    private static func collectNestedStyleRuleSelectorRanges(
        inBlockOpenedAt blockOpen: Int,
        source: NSString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = blockOpen + 1

        while location < source.length {
            location = locationAfterSkippingWhitespaceAndComments(at: location, in: source)
            guard location < source.length else {
                return ranges
            }
            if source.character(at: location) == ascii("}") {
                return ranges
            }

            if source.character(at: location) == ascii("@") {
                guard let nestedOpen = findBlockOpen(after: location, in: source) else {
                    location = locationAfterStatement(at: location, in: source)
                    continue
                }
                if matchesConditionalAtRule(at: location, in: source)
                    || matchesSelectorGroupingAtRule(at: location, in: source),
                   let nestedScan = collectNestedSelectorRanges(inBlockOpenedAt: nestedOpen, source: source) {
                    if matchesScopeAtRule(at: location, in: source),
                       let preludeRange = trimmedRange(
                           location: min(location + ("@scope" as NSString).length, source.length),
                           upperBound: nestedOpen,
                           in: source
                       ) {
                        ranges.append(preludeRange)
                    }
                    ranges.append(contentsOf: nestedScan.ranges)
                    location = nestedScan.endLocation
                } else {
                    location = locationAfterBlock(openedAt: nestedOpen, in: source) ?? (nestedOpen + 1)
                }
                continue
            }

            guard let nestedBlockOpen = findBlockOpen(after: location, in: source) else {
                let nextStatement = locationAfterStatement(at: location, in: source)
                location = nextStatement > location ? nextStatement : location + 1
                continue
            }
            if let range = trimmedRange(location: location, upperBound: nestedBlockOpen, in: source) {
                ranges.append(range)
            }
            ranges.append(contentsOf: collectNestedStyleRuleSelectorRanges(
                inBlockOpenedAt: nestedBlockOpen,
                source: source
            ))
            location = locationAfterBlock(openedAt: nestedBlockOpen, in: source) ?? (nestedBlockOpen + 1)
        }

        return ranges
    }

    private static func collectNestedSelectorRanges(
        inBlockOpenedAt blockOpen: Int,
        source: NSString
    ) -> (ranges: [NSRange], endLocation: Int)? {
        var ranges: [NSRange] = []
        var location = blockOpen + 1

        while location < source.length {
            location = locationAfterSkippingWhitespaceAndComments(at: location, in: source)
            guard location < source.length else {
                return nil
            }

            if source.character(at: location) == ascii("}") {
                return (ranges, location + 1)
            }

            if source.character(at: location) == ascii("@") {
                guard let nestedOpen = findBlockOpen(after: location, in: source) else {
                    location = locationAfterStatement(at: location, in: source)
                    continue
                }
                if matchesConditionalAtRule(at: location, in: source),
                   let nestedScan = collectNestedSelectorRanges(inBlockOpenedAt: nestedOpen, source: source) {
                    ranges.append(contentsOf: nestedScan.ranges)
                    location = nestedScan.endLocation
                } else if matchesSelectorGroupingAtRule(at: location, in: source),
                          let nestedScan = collectNestedSelectorRanges(inBlockOpenedAt: nestedOpen, source: source) {
                    if matchesScopeAtRule(at: location, in: source),
                       let preludeRange = trimmedRange(
                           location: min(location + ("@scope" as NSString).length, source.length),
                           upperBound: nestedOpen,
                           in: source
                       ) {
                        ranges.append(preludeRange)
                    }
                    ranges.append(contentsOf: nestedScan.ranges)
                    location = nestedScan.endLocation
                } else {
                    location = locationAfterBlock(openedAt: nestedOpen, in: source) ?? (nestedOpen + 1)
                }
                continue
            }

            let selectorStart = location
            guard let nestedBlockOpen = findBlockOpen(after: selectorStart, in: source) else {
                return nil
            }
            if let range = trimmedRange(location: selectorStart, upperBound: nestedBlockOpen, in: source) {
                ranges.append(range)
            }
            ranges.append(contentsOf: collectNestedStyleRuleSelectorRanges(
                inBlockOpenedAt: nestedBlockOpen,
                source: source
            ))
            location = locationAfterBlock(openedAt: nestedBlockOpen, in: source) ?? (nestedBlockOpen + 1)
        }

        return nil
    }

    private static func isConditionalAtRuleSelectorDeclarationToken(
        _ token: SyntaxEditorHighlighting.Token,
        nestedSelectorRanges: [NSRange],
        sourceUTF16Length: Int
    ) -> Bool {
        guard token.language == .css || token.language == nil,
              token.range.location != NSNotFound,
              token.range.upperBound <= sourceUTF16Length,
              token.syntaxID == .declarationOther
        else {
            return false
        }
        return nestedSelectorRanges.contains {
            rangesIntersect(token.range, $0)
        }
    }

    private static func isCSSSourceLocalOverlayToken(
        _ token: SyntaxEditorHighlighting.Token
    ) -> Bool {
        token.language == .css
            && sourceLocalOverlaySyntaxIDs.contains(token.syntaxID)
            && token.rawCaptureName == sourceLocalOverlayRawCaptureName(syntaxID: token.syntaxID)
    }

    private static func isSourceLocalOverlayTokenSuppressedByKeyword(
        _ token: SourceLocalOverlayToken,
        keywordTokenRanges: [NSRange]
    ) -> Bool {
        guard token.suppressWhenKeywordTokenExists else {
            return false
        }
        return keywordTokenRanges.contains { $0 == token.range }
    }

    private static func isBasePlainTokenCoveredBySourceLocalOverlay(
        _ token: SyntaxEditorHighlighting.Token,
        overlayTokens: [SourceLocalOverlayToken]
    ) -> Bool {
        guard token.syntaxID == .plain,
              token.range.location != NSNotFound
        else {
            return false
        }
        return overlayTokens.contains {
            $0.syntaxID != .plain && rangesIntersect(token.range, $0.range)
        }
    }

    private static func isPseudoClassArgumentDeclarationToken(
        _ token: SyntaxEditorHighlighting.Token,
        argumentRanges: [NSRange]
    ) -> Bool {
        guard token.syntaxID == .declarationOther,
              token.range.location != NSNotFound
        else {
            return false
        }
        return argumentRanges.contains {
            rangesIntersect(token.range, $0)
        }
    }

    private static func matchesConditionalAtRule(at location: Int, in source: NSString) -> Bool {
        matches("@media", at: location, in: source)
            || matches("@supports", at: location, in: source)
            || matches("@container", at: location, in: source)
    }

    private static func matchesSelectorGroupingAtRule(at location: Int, in source: NSString) -> Bool {
        matches("@document", at: location, in: source)
            || matches("@layer", at: location, in: source)
            || matches("@scope", at: location, in: source)
            || matches("@starting-style", at: location, in: source)
    }

    private static func matchesScopeAtRule(at location: Int, in source: NSString) -> Bool {
        matches("@scope", at: location, in: source)
    }

    private static func namedAtRule(at location: Int, in source: NSString) -> String? {
        for keyword in namedAtRules {
            if matches(keyword, at: location, in: source) {
                return keyword
            }
        }
        return nil
    }

    private static func isAtRuleStart(at location: Int, in source: NSString) -> Bool {
        guard location >= 0,
              location + 1 < source.length,
              source.character(at: location) == ascii("@")
        else {
            return false
        }
        if location > 0 {
            let previous = source.character(at: location - 1)
            guard isWhitespace(previous)
                || previous == ascii("{")
                || previous == ascii("}")
                || previous == ascii(";")
            else {
                return false
            }
        }
        return isCSSIdentifierStart(at: location + 1, upperBound: source.length, source: source)
    }

    private static func matches(_ keyword: String, at location: Int, in source: NSString) -> Bool {
        let length = (keyword as NSString).length
        guard location >= 0,
              location + length <= source.length,
              source.substring(with: NSRange(location: location, length: length)).lowercased() == keyword
        else {
            return false
        }
        guard location + length < source.length else {
            return true
        }
        let nextLocation = location + length
        if locationAfterSkippingComment(at: nextLocation, in: source) != nil {
            return true
        }
        let next = source.character(at: nextLocation)
        return isWhitespace(next) || next == ascii("(") || next == ascii("{")
    }

    private static func findBlockOpen(after location: Int, in source: NSString) -> Int? {
        var scan = location
        while scan < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: scan, in: source) {
                scan = skipLocation
                continue
            }

            let character = source.character(at: scan)
            if character == ascii("{") {
                return scan
            }
            if character == ascii("}") || character == ascii(";") {
                return nil
            }
            scan += 1
        }
        return nil
    }

    private static func locationAfterBlock(openedAt blockOpen: Int, in source: NSString) -> Int? {
        var depth = 1
        var location = blockOpen + 1
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            let character = source.character(at: location)
            if character == ascii("{") {
                depth += 1
            } else if character == ascii("}") {
                depth -= 1
                if depth == 0 {
                    return location + 1
                }
            }
            location += 1
        }
        return nil
    }

    private static func locationAfterStatement(at location: Int, in source: NSString) -> Int {
        var scan = location
        while scan < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: scan, in: source) {
                scan = skipLocation
                continue
            }
            if source.character(at: scan) == ascii(";") {
                return scan + 1
            }
            if source.character(at: scan) == ascii("}") {
                return scan
            }
            scan += 1
        }
        return source.length
    }

    private static func locationAfterSkippingWhitespaceAndComments(at location: Int, in source: NSString) -> Int {
        var scan = location
        while scan < source.length {
            if isWhitespace(source.character(at: scan)) {
                scan += 1
                continue
            }
            if let skipLocation = locationAfterSkippingComment(at: scan, in: source) {
                scan = skipLocation
                continue
            }
            break
        }
        return scan
    }

    private static func locationAfterSkippingWhitespace(
        at location: Int,
        upperBound: Int,
        in source: NSString
    ) -> Int {
        var scan = location
        while scan < upperBound, isWhitespace(source.character(at: scan)) {
            scan += 1
        }
        return scan
    }

    private static func locationAfterSkippingCommentOrString(at location: Int, in source: NSString) -> Int? {
        locationAfterSkippingComment(at: location, in: source)
            ?? locationAfterSkippingString(at: location, in: source)
    }

    private static func locationAfterSkippingComment(at location: Int, in source: NSString) -> Int? {
        guard location + 1 < source.length,
              source.character(at: location) == ascii("/"),
              source.character(at: location + 1) == ascii("*")
        else {
            return nil
        }

        var scan = location + 2
        while scan + 1 < source.length {
            if source.character(at: scan) == ascii("*"),
               source.character(at: scan + 1) == ascii("/") {
                return scan + 2
            }
            scan += 1
        }
        return source.length
    }

    private static func matchingCloseParenthesis(openedAt open: Int, in source: NSString) -> Int? {
        var depth = 1
        var location = open + 1
        while location < source.length {
            if let skipLocation = locationAfterSkippingCommentOrString(at: location, in: source) {
                location = skipLocation
                continue
            }

            let character = source.character(at: location)
            if character == ascii("(") {
                depth += 1
            } else if character == ascii(")") {
                depth -= 1
                if depth == 0 {
                    return location
                }
            }
            location += 1
        }
        return nil
    }

    private static func locationAfterSkippingString(at location: Int, in source: NSString) -> Int? {
        let quote = source.character(at: location)
        guard quote == ascii("\"") || quote == ascii("'") else {
            return nil
        }

        var scan = location + 1
        while scan < source.length {
            let character = source.character(at: scan)
            if character == ascii("\\") {
                scan += 2
                continue
            }
            if character == quote {
                return scan + 1
            }
            scan += 1
        }
        return source.length
    }

    private static func trimmedRange(location: Int, upperBound: Int, in source: NSString) -> NSRange? {
        var lower = location
        var upper = upperBound
        while lower < upper, isWhitespace(source.character(at: lower)) {
            lower += 1
        }
        while upper > lower, isWhitespace(source.character(at: upper - 1)) {
            upper -= 1
        }
        guard lower < upper else {
            return nil
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == ascii(" ")
            || character == ascii("\n")
            || character == ascii("\r")
            || character == ascii("\t")
            || character == ascii("\u{0C}")
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= ascii("0") && character <= ascii("9")
    }

    private static func isIdentifierStartCharacter(_ character: unichar) -> Bool {
        (character >= ascii("A") && character <= ascii("Z"))
            || (character >= ascii("a") && character <= ascii("z"))
            || character == ascii("_")
    }

    private static func isCSSIdentifierStart(
        at location: Int,
        upperBound: Int,
        source: NSString
    ) -> Bool {
        let character = source.character(at: location)
        if isIdentifierStartCharacter(character) {
            return true
        }
        guard character == ascii("-"),
              location + 1 < upperBound
        else {
            return false
        }
        let next = source.character(at: location + 1)
        return isIdentifierStartCharacter(next) || next == ascii("-")
    }

    private static func isIdentifierUnitCharacter(_ character: unichar) -> Bool {
        (character >= ascii("A") && character <= ascii("Z"))
            || (character >= ascii("a") && character <= ascii("z"))
            || (character >= ascii("0") && character <= ascii("9"))
            || character == ascii("_")
            || character == ascii("-")
    }

    private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        max(lhs.location, rhs.location) < min(lhs.upperBound, rhs.upperBound)
    }

    private static func canonicalToken(
        range: NSRange,
        syntaxID: EditorSourceSyntax.ID
    ) -> SyntaxEditorHighlighting.Token {
        SyntaxEditorHighlighting.Token(
            range: range,
            syntaxID: syntaxID,
            language: .css,
            rawCaptureName: sourceLocalOverlayRawCaptureName(syntaxID: syntaxID),
            isSemanticOverlay: true
        )
    }

    private static func sourceLocalOverlayRawCaptureName(syntaxID: EditorSourceSyntax.ID) -> String {
        "\(EditorSourceSyntax.Capture.rawCaptureName(syntaxID: syntaxID, language: .css)).source-local"
    }

    private static func deduplicated(_ tokens: [SyntaxEditorHighlighting.Token]) -> [SyntaxEditorHighlighting.Token] {
        var seen = Set<TokenKey>()
        return tokens.filter {
            seen.insert(TokenKey($0)).inserted
        }
    }

    private static func ascii(_ character: Character) -> unichar {
        unichar(String(character).utf16.first ?? 0)
    }

    private static let sourceLocalOverlaySyntaxIDs: Set<EditorSourceSyntax.ID> = [
        .declarationOther,
        .keyword,
        .number,
        .plain,
    ]

    private static let xcodeKeywordUnits: Set<String> = [
        "cm",
        "deg",
        "em",
        "ex",
        "grad",
        "in",
        "mm",
        "ms",
        "pc",
        "pt",
        "px",
        "rad",
        "s",
    ]

    private static let xcodeKeywordIdentifiers: Set<String> = [
        "after",
        "auto",
        "background",
        "border-color",
        "button",
        "color",
        "content",
        "display",
        "from",
        "grid",
        "height",
        "hover",
        "margin",
        "max-width",
        "min-height",
        "min-width",
        "not",
        "opacity",
        "padding",
        "repeat",
        "rgba",
        "red",
        "to",
        "width",
    ]

    private static let xcodeDeclarationSupportFunctions: Set<String> = [
        "selector",
    ]

    private static let xcodeKeywordPseudoClasses: Set<String> = [
        "not",
    ]

    private static let containerPreludeBooleanOperators: Set<String> = [
        "and",
        "not",
        "or",
    ]

    private static let xcodeDeclarationPseudoClasses: Set<String> = [
        "has",
        "host",
        "host-context",
        "is",
        "where",
    ]

    private static let namedAtRules = [
        "@layer",
        "@property",
    ]

    private struct SourceLocalOverlayToken {
        let range: NSRange
        let syntaxID: EditorSourceSyntax.ID
        let suppressWhenKeywordTokenExists: Bool

        init(
            range: NSRange,
            syntaxID: EditorSourceSyntax.ID,
            suppressWhenKeywordTokenExists: Bool = false
        ) {
            self.range = range
            self.syntaxID = syntaxID
            self.suppressWhenKeywordTokenExists = suppressWhenKeywordTokenExists
        }
    }

    private struct SourceLocalOverlayContext {
        let tokens: [SourceLocalOverlayToken]
        let nestedSelectorRanges: [NSRange]
        let pseudoFunctionArgumentRanges: [NSRange]
    }

    private struct TokenKey: Hashable {
        let location: Int
        let length: Int
        let syntaxID: EditorSourceSyntax.ID
        let language: SyntaxLanguage?
        let rawCaptureName: String

        init(_ token: SyntaxEditorHighlighting.Token) {
            location = token.range.location
            length = token.range.length
            syntaxID = token.syntaxID
            language = token.language
            rawCaptureName = token.rawCaptureName
        }
    }
}
