import Foundation

extension ObjectiveCSyntaxOverlayTokenProvider {
    private static let objectiveCSemanticStructuralCharacters = CharacterSet(charactersIn: "#@{}();")

    /// Returns nil when cancellation was observed mid-scan (the caller reports
    /// an isCancelled result; partial output is never committed).
    static func semanticTokens(
        from tokens: [SyntaxEditorHighlighting.Token],
        source: NSString,
        index: ObjectiveCFileSymbolIndex,
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token]? {
        var overlayTokens: [SyntaxEditorHighlighting.Token] = []
        overlayTokens.reserveCapacity(tokens.count / 4)

        var cancellationBudget = 0
        for token in tokens {
            cancellationBudget += 1
            if cancellationBudget & 0x3FF == 0, Task.isCancelled {
                return nil
            }
            guard token.language == .objectiveC || token.language == nil,
                  token.range.location >= 0,
                  token.range.length > 0,
                  token.range.upperBound <= source.length,
                  targetRange.map({ rangesIntersect(token.range, $0) }) ?? true,
                  isObjectiveCIdentifierRange(token.range, in: source)
            else {
                continue
            }

            let text = source.nativeSubstring(with: token.range)

            if token.syntaxID == .keyword, text == "Class" {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .plain))
                continue
            }

            if preprocessorObjectiveCMacroIdentifiers.contains(text) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .preprocessor))
                continue
            }

            if index.containsPropertyDeclarationNameRange(token.range) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .declarationOther))
                continue
            }

            if index.containsTypeDeclarationNameRange(token.range) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .declarationType))
                continue
            }

            if index.containsSelfMemberNameRange(token.range) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierVariable))
                continue
            }

            if index.containsSelfChainMemberNameRange(token.range) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierVariableSystem))
                continue
            }

            if isSelfMemberName(token.range, in: source) {
                if index.shouldTrackSelfMemberName(text) {
                    overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierVariable))
                }
                continue
            }

            if index.containsIvarName(text),
               !index.containsIvarDeclarationNameRange(token.range),
               !index.containsShadowedVariableRange(token.range) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierVariable))
                continue
            }

            if index.containsFileScopeVariableName(text),
               !index.containsFileScopeVariableDeclarationNameRange(token.range),
               !index.containsShadowedVariableRange(token.range) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierVariableSystem))
                continue
            }

            if knownObjectiveCFunctionPointerCastCallees.contains(text),
               isObjectiveCFunctionPointerCastCalleeName(token.range, in: source) {
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierFunctionSystem))
                continue
            }

            if token.syntaxID == .plain,
               isObjectiveCCallName(token.range, in: source) {
                if index.containsLocalMacroName(text) {
                    overlayTokens.append(canonicalToken(range: token.range, syntaxID: .preprocessor))
                    continue
                }
                if index.localFunctions.contains(text) {
                    overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierFunction))
                    continue
                }
                if knownObjectiveCSystemFunctionNames.contains(text) {
                    overlayTokens.append(canonicalToken(range: token.range, syntaxID: .identifierFunctionSystem))
                    continue
                }
            }

            switch token.syntaxID {
            case .identifier:
                continue

            case .identifierType, .identifierTypeSystem:
                guard !keywordLikeTypeNames.contains(text) else {
                    continue
                }
                if isTypeDeclarationName(token.range, text: text, in: source) {
                    overlayTokens.append(canonicalToken(range: token.range, syntaxID: .declarationType))
                }

            case .identifierFunction:
                guard !appleMacroFunctionNames.contains(text) else {
                    continue
                }
                guard isObjectiveCFunctionOrMethodDeclarationName(token.range, in: source) else {
                    continue
                }
                overlayTokens.append(canonicalToken(range: token.range, syntaxID: .declarationOther))

            case .identifierFunctionSystem:
                continue

            default:
                continue
            }
        }

        return overlayTokens
    }

    static func preprocessorStringTokens(
        in source: NSString,
        tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        let string = source as String
        var overlayTokens: [SyntaxEditorHighlighting.Token] = []
        for token in tokens where (token.language == .objectiveC || token.language == nil)
            && token.syntaxID == .preprocessor
            && token.range.location >= 0
            && token.range.length > 0
            && token.range.upperBound <= source.length {
            let scanRange = SyntaxEditorRangeUtilities.clampedRange(token.range, utf16Length: source.length)
            guard targetRange.map({ rangesIntersect(scanRange, $0) }) ?? true else {
                continue
            }

            for match in preprocessorQuotedStringRegex.matches(in: string, range: scanRange) {
                var range = match.range
                guard range.location != NSNotFound,
                      range.length > 0,
                      range.upperBound <= source.length else {
                    continue
                }
                if source.substring(with: NSRange(location: range.location, length: 1)) == "@" {
                    range = NSRange(location: range.location + 1, length: range.length - 1)
                }
                guard range.length > 0,
                      targetRange.map({ rangesIntersect(range, $0) }) ?? true else {
                    continue
                }
                overlayTokens.append(canonicalToken(range: range, syntaxID: .string))
            }
        }
        return overlayTokens
    }

    static func objectiveCMacroTokens(
        in source: NSString,
        nonCodeRanges: [NSRange],
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        let string = source as String
        let searchRange = targetRange ?? NSRange(location: 0, length: source.length)
        var tokens: [SyntaxEditorHighlighting.Token] = []

        for match in preprocessorObjectiveCMacroRegex.matches(in: string, range: searchRange) {
            let range = match.range
            guard range.location != NSNotFound,
                  range.length > 0,
                  !rangeIntersectsSortedRanges(range, nonCodeRanges) else {
                continue
            }
            tokens.append(canonicalToken(range: range, syntaxID: .preprocessor))
        }

        for match in macroLikeObjectiveCIdentifierRegex.matches(in: string, range: searchRange) {
            let range = match.range
            guard range.location != NSNotFound,
                  range.length > 0,
                  !rangeIntersectsSortedRanges(range, nonCodeRanges) else {
                continue
            }
            let text = source.substring(with: range)
            guard !preprocessorObjectiveCMacroIdentifiers.contains(text) else {
                continue
            }
            guard objectiveCTypeIdentifierShouldStayPlain(range, text: text, in: source) else {
                continue
            }
            tokens.append(canonicalToken(range: range, syntaxID: .plain))
        }

        return tokens
    }

    static func boxedExpressionDelimiterTokens(
        in source: NSString,
        nonCodeRanges: [NSRange],
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        var tokens: [SyntaxEditorHighlighting.Token] = []
        var searchLocation = 0
        while searchLocation < source.length {
            let searchRange = NSRange(location: searchLocation, length: source.length - searchLocation)
            let matchRange = source.range(of: "@(", options: [], range: searchRange)
            guard matchRange.location != NSNotFound else {
                break
            }
            let atRange = NSRange(location: matchRange.location, length: 1)
            let openParenRange = NSRange(location: matchRange.location + 1, length: 1)
            let closeParenRange = matchingCloseParenRange(
                openingAt: openParenRange.location,
                in: source
            )
            let fullRange = closeParenRange.map {
                NSRange(location: atRange.location, length: $0.upperBound - atRange.location)
            } ?? NSRange(location: atRange.location, length: 2)

            var delimiterRanges = [atRange, openParenRange]
            if let closeParenRange {
                delimiterRanges.append(closeParenRange)
            }

            if delimiterRanges.allSatisfy({ !rangeIntersectsSortedRanges($0, nonCodeRanges) }),
               targetRange.map({ rangesIntersect(fullRange, $0) }) ?? true {
                tokens.append(canonicalToken(range: atRange, syntaxID: .number))
                tokens.append(canonicalToken(range: openParenRange, syntaxID: .number))
                if let closeParenRange {
                    tokens.append(canonicalToken(range: closeParenRange, syntaxID: .number))
                }
            }

            searchLocation = max(matchRange.upperBound, searchLocation + 1)
        }
        return tokens
    }

    static func boxedBooleanLiteralTokens(
        in source: NSString,
        nonCodeRanges: [NSRange],
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        let string = source as String
        let searchRange = targetRange ?? NSRange(location: 0, length: source.length)
        return boxedBooleanLiteralRegex.matches(in: string, range: searchRange).flatMap { match -> [SyntaxEditorHighlighting.Token] in
            let range = match.range
            guard range.location != NSNotFound,
                  range.length > 0,
                  !rangeIntersectsSortedRanges(range, nonCodeRanges)
            else {
                return []
            }
            let valueRange = NSRange(location: range.location + 1, length: range.length - 1)
            return [
                canonicalToken(range: range, syntaxID: .number),
                canonicalToken(range: valueRange, syntaxID: .number)
            ]
        }
    }

    private static func nonCodeRanges(
        from tokens: [SyntaxEditorHighlighting.Token],
        sourceLength: Int
    ) -> [NSRange] {
        tokens.compactMap { token -> NSRange? in
            guard token.language == .objectiveC || token.language == nil else {
                return nil
            }
            switch token.syntaxID {
            case .comment, .string, .character:
                return SyntaxEditorRangeUtilities.clampedRange(token.range, utf16Length: sourceLength)
            default:
                return nil
            }
        }.sorted { lhs, rhs in
            if lhs.location != rhs.location {
                return lhs.location < rhs.location
            }
            return lhs.length < rhs.length
        }
    }

    private static func rangeIntersectsSortedRanges(_ range: NSRange, _ sortedRanges: [NSRange]) -> Bool {
        var lower = 0
        var upper = sortedRanges.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if sortedRanges[midpoint].upperBound <= range.location {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard lower < sortedRanges.count else {
            return false
        }
        return SyntaxEditorRangeUtilities.intersection(of: range, and: sortedRanges[lower]).length > 0
    }

    static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        SyntaxEditorRangeUtilities.intersection(of: lhs, and: rhs).length > 0
    }

    static func objectiveCMutationChangedRange(
        _ mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString
    ) -> NSRange {
        let replacementLength = mutation.replacement.utf16.count
        let changedLocation = min(max(0, mutation.location), source.length)
        let changedStart = max(0, changedLocation - (mutation.length > 0 ? 1 : 0))
        let changedEnd = min(source.length, max(changedLocation + max(1, replacementLength), changedStart + 1))
        return NSRange(location: changedStart, length: changedEnd - changedStart)
    }

    static func objectiveCLocalEditCanKeepSemanticTarget(
        _ mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString
    ) -> Bool {
        guard source.length > 0,
              mutation.location >= 0,
              mutation.location <= source.length else {
            return false
        }

        let changedRange = objectiveCMutationChangedRange(mutation, in: source)
        let lineRange = source.lineRange(for: changedRange)
        let line = source.substring(with: lineRange) as NSString
        let lineString = line as String
        let fullRange = NSRange(location: 0, length: line.length)
        let relativeChangedRange = NSRange(
            location: max(0, changedRange.location - lineRange.location),
            length: changedRange.length
        )

        if objectiveCVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            let statementEnd = line.range(of: ";").location
            guard statementEnd != NSNotFound else { return false }
            return objectiveCDeclarationSignatureRanges(in: line, statementEnd: statementEnd)
                .contains { rangesIntersect($0, relativeChangedRange) } == false
        }

        return ObjectiveCSemanticLineSignatureIndex.signaturesForChangedLines(mutation, in: source)
            .allSatisfy { !$0.contributesToSignature }
    }

    static func objectiveCInsertedTextCanKeepSemanticTarget(
        _ mutation: SyntaxEditorTextChange.Replacement
    ) -> Bool {
        guard mutation.length == 0,
              !mutation.replacement.isEmpty else {
            return false
        }

        return !objectiveCRefreshLooksStructural(mutation.replacement)
    }

    static func boxedExpressionRefreshRange(around targetRange: NSRange, in source: NSString) -> NSRange? {
        var cursor = targetRange.location
        let upperBound = min(source.length, targetRange.upperBound)
        while cursor < upperBound {
            if let nextCursor = locationAfterSkippedCommentOrLiteral(startingAt: cursor, in: source) {
                cursor = min(nextCursor, upperBound)
                continue
            }
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            guard character == "(" else {
                cursor += 1
                continue
            }
            guard let closeParenRange = matchingCloseParenRange(openingAt: cursor, in: source) else {
                cursor += 1
                continue
            }
            let fullRange = NSRange(location: cursor, length: closeParenRange.upperBound - cursor)
            if !rangesIntersect(fullRange, targetRange) {
                cursor += 1
                continue
            }
            return unionRange(targetRange, fullRange)
        }
        return deletedBoxedExpressionRefreshRange(around: targetRange, in: source)
    }

    private static func deletedBoxedExpressionRefreshRange(around targetRange: NSRange, in source: NSString) -> NSRange? {
        var cursor = targetRange.location
        let upperBound = min(source.length, targetRange.upperBound)
        while cursor < upperBound {
            if let nextCursor = locationAfterSkippedCommentOrLiteral(startingAt: cursor, in: source) {
                cursor = min(nextCursor, upperBound)
                continue
            }
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character == "@",
               let closeParenRange = unmatchedClosingParenRange(after: cursor + 1, in: source) {
                return unionRange(targetRange, closeParenRange)
            }
            cursor += 1
        }
        return nil
    }

    private static func unmatchedClosingParenRange(after location: Int, in source: NSString) -> NSRange? {
        var cursor = min(max(0, location), source.length)
        var depth = 0
        while cursor < source.length {
            if let nextCursor = locationAfterSkippedCommentOrLiteral(startingAt: cursor, in: source) {
                cursor = nextCursor
                continue
            }

            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character == ";" || character == "{" || character == "}" {
                return nil
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth == 0 {
                    return NSRange(location: cursor, length: 1)
                }
                depth -= 1
            }
            cursor += 1
        }
        return nil
    }

    private static func unionRange(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        let lowerBound = min(lhs.location, rhs.location)
        let upperBound = max(lhs.upperBound, rhs.upperBound)
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    static func objectiveCUnsafeEditContextRange(around range: NSRange, in source: NSString) -> NSRange {
        var lower = range.location
        var upper = range.upperBound

        if lower > 0 {
            let previousLocation = max(0, lower - 1)
            let previousLine = source.lineRange(for: NSRange(location: previousLocation, length: 0))
            lower = previousLine.location
        }
        if upper < source.length {
            let nextLine = source.lineRange(for: NSRange(location: upper, length: 0))
            upper = nextLine.upperBound
        }

        return NSRange(location: lower, length: max(0, min(upper, source.length) - lower))
    }

    static func objectiveCRefreshLooksStructural(_ text: String) -> Bool {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return structuralObjectiveCEditRegex.firstMatch(in: text, range: fullRange) != nil
            || objectiveCTextContainsVariableDeclarationLine(nsText)
    }

    private static func objectiveCMutationReplacesPreviousStructuralSignatureText(
        _ mutation: SyntaxEditorTextChange.Replacement,
        previousIndex: ObjectiveCSemanticIndex?
    ) -> Bool {
        guard mutation.length > 0,
              let previousIndex else {
            return false
        }

        return rangeIntersectsSortedRanges(
            NSRange(location: mutation.location, length: mutation.length),
            previousIndex.structuralEditRanges
        )
    }

    static func semanticIndexSignature(in source: NSString) -> ObjectiveCSemanticIndexSignature {
        let lineSignatureIndex = ObjectiveCSemanticLineSignatureIndex(source: source)
        return ObjectiveCSemanticIndexSignature(
            fingerprint: lineSignatureIndex.fingerprint,
            structuralEditRanges: lineSignatureIndex.structuralEditRanges
        )
    }

    static func objectiveCSemanticStructuralEditRanges(
        in line: NSString,
        lineOffset: Int
    ) -> [NSRange] {
        let lineString = line as String
        let fullRange = NSRange(location: 0, length: line.length)
        let structuralCharacterRanges = objectiveCSemanticStructuralCharacterRanges(
            in: line,
            lineOffset: lineOffset
        )

        guard let trimmedRange = objectiveCTrimmedRange(in: line) else {
            return structuralCharacterRanges
        }

        let trimmed = line.substring(with: trimmedRange)
        if trimmed.hasPrefix("#") {
            return [NSRange(location: lineOffset + trimmedRange.location, length: trimmedRange.length)]
        }

        if trimmed.hasPrefix("@property") {
            var ranges = structuralCharacterRanges
            if let keywordRange = objectiveCKeywordRange("@property", in: line) {
                ranges.append(NSRange(location: lineOffset + keywordRange.location, length: keywordRange.length))
            }
            if let nameRange = ObjectiveCFileSymbolIndex.propertyDeclaredNameRange(in: line) {
                ranges.append(NSRange(location: lineOffset + nameRange.location, length: nameRange.length))
            } else {
                return [NSRange(location: lineOffset + trimmedRange.location, length: trimmedRange.length)]
            }
            return sortedObjectiveCSemanticStructuralRanges(ranges)
        }

        if objectiveCForLoopVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            return sortedObjectiveCSemanticStructuralRanges(
                objectiveCDeclarationSignatureRanges(in: line, statementEnd: line.length)
                    .map { NSRange(location: lineOffset + $0.location, length: $0.length) }
            )
        }

        if objectiveCVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            let statementEnd = line.range(of: ";").location
            guard statementEnd != NSNotFound else {
                return [NSRange(location: lineOffset + trimmedRange.location, length: trimmedRange.length)]
            }
            return sortedObjectiveCSemanticStructuralRanges(
                objectiveCDeclarationSignatureRanges(in: line, statementEnd: statementEnd)
                    .map { NSRange(location: lineOffset + $0.location, length: $0.length) }
            )
        }

        guard structuralObjectiveCEditRegex.firstMatch(in: lineString, range: fullRange) != nil
            || objectiveCSemanticIndexFunctionSignatureLineRegex.firstMatch(in: lineString, range: fullRange) != nil
            || objectiveCSemanticIndexSplitFunctionNameLineRegex.firstMatch(in: lineString, range: fullRange) != nil else {
            return structuralCharacterRanges
        }

        var ranges = structuralCharacterRanges
        for match in ObjectiveCFileSymbolIndex.identifierRegex.matches(in: lineString, range: fullRange) {
            ranges.append(NSRange(location: lineOffset + match.range.location, length: match.range.length))
        }
        if ranges.isEmpty {
            ranges.append(NSRange(location: lineOffset + trimmedRange.location, length: trimmedRange.length))
        }
        return sortedObjectiveCSemanticStructuralRanges(ranges)
    }

    private static func objectiveCSemanticStructuralCharacterRanges(
        in line: NSString,
        lineOffset: Int
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < line.length {
            let searchRange = NSRange(location: cursor, length: line.length - cursor)
            let structuralRange = line.rangeOfCharacter(
                from: objectiveCSemanticStructuralCharacters,
                options: [],
                range: searchRange
            )
            guard structuralRange.location != NSNotFound else {
                break
            }
            ranges.append(NSRange(location: lineOffset + structuralRange.location, length: structuralRange.length))
            cursor = structuralRange.upperBound
        }
        return ranges
    }

    private static func sortedObjectiveCSemanticStructuralRanges(_ ranges: [NSRange]) -> [NSRange] {
        ranges
            .filter { $0.length > 0 }
            .sorted {
                if $0.location != $1.location {
                    return $0.location < $1.location
                }
                return $0.length < $1.length
            }
    }

    private static func objectiveCTrimmedRange(in line: NSString) -> NSRange? {
        var lower = 0
        var upper = line.length
        while lower < upper,
              objectiveCLineCharacterIsWhitespace(line.substring(with: NSRange(location: lower, length: 1))) {
            lower += 1
        }
        while upper > lower,
              objectiveCLineCharacterIsWhitespace(line.substring(with: NSRange(location: upper - 1, length: 1))) {
            upper -= 1
        }
        guard lower < upper else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func objectiveCKeywordRange(_ keyword: String, in line: NSString) -> NSRange? {
        let range = line.range(of: keyword)
        guard range.location != NSNotFound else { return nil }
        return range
    }

    private static func objectiveCMutationMovesPreviousStructuralSignatureIntoNonCode(
        _ mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString,
        previousIndex: ObjectiveCSemanticIndex?
    ) -> Bool {
        guard let previousIndex,
              !previousIndex.structuralEditRanges.isEmpty,
              mutation.replacement.rangeOfCharacter(from: .newlines) == nil else {
            return false
        }

        let replacementLength = mutation.replacement.utf16.count
        let oldUpperBound = mutation.location + mutation.length
        let delta = replacementLength - mutation.length
        for range in previousIndex.structuralEditRanges {
            guard range.location >= oldUpperBound else { continue }

            let shiftedLocation = range.location + delta
            guard shiftedLocation >= 0,
                  shiftedLocation <= source.length else {
                continue
            }

            let lineRange = source.lineRange(for: NSRange(location: shiftedLocation, length: 0))
            guard lineRange.location <= mutation.location,
                  mutation.location <= shiftedLocation,
                  shiftedLocation <= lineRange.upperBound else {
                continue
            }

            let prefixRange = NSRange(
                location: lineRange.location,
                length: shiftedLocation - lineRange.location
            )
            if objectiveCTextCanStartCommentOrLiteral(source.substring(with: prefixRange)) {
                return true
            }
            if objectiveCMutationPrefixesLineSignatureWithNonWhitespace(
                mutation,
                lineRange: lineRange,
                shiftedSignatureLocation: shiftedLocation,
                in: source
            ) {
                return true
            }
        }
        return false
    }

    private static func objectiveCTextCanStartCommentOrLiteral(_ text: String) -> Bool {
        text.contains("//") || text.contains("/*") || text.contains("\"")
    }

    private static func objectiveCMutationPrefixesLineSignatureWithNonWhitespace(
        _ mutation: SyntaxEditorTextChange.Replacement,
        lineRange: NSRange,
        shiftedSignatureLocation: Int,
        in source: NSString
    ) -> Bool {
        guard mutation.location < shiftedSignatureLocation,
              mutation.replacement.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil else {
            return false
        }
        let prefixBeforeMutationRange = NSRange(
            location: lineRange.location,
            length: max(0, mutation.location - lineRange.location)
        )
        guard prefixBeforeMutationRange.upperBound <= source.length else {
            return false
        }
        return objectiveCLineCharacterIsWhitespace(source.substring(with: prefixBeforeMutationRange))
    }

    private static func objectiveCLineCharacterIsWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    static func objectiveCMutationRequiresSemanticIndexRebuild(
        _ mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString,
        previousIndex: ObjectiveCSemanticIndex?
    ) -> Bool {
        if previousIndex?.fileSymbols.mutationTouchesSelfMemberAccessOperator(mutation) == true {
            return true
        }

        let replacementLength = mutation.replacement.utf16.count
        let changedLocation = min(max(0, mutation.location), source.length)
        let changedStart = max(0, changedLocation - (mutation.length > 0 ? 1 : 0))
        let changedEnd = min(source.length, max(changedLocation + max(1, replacementLength), changedStart + 1))
        let changedRange = NSRange(location: changedStart, length: changedEnd - changedStart)
        let lineRange = source.lineRange(for: changedRange)
        let line = source.substring(with: lineRange) as NSString
        let relativeChangedRange = NSRange(
            location: max(0, changedRange.location - lineRange.location),
            length: changedRange.length
        )
        return objectiveCMutationCanChangeMemberAccessReceiver(
            line: line,
            relativeChangedRange: relativeChangedRange
        ) || objectiveCMutationCanChangeMemberAccessField(
            line: line,
            relativeChangedRange: relativeChangedRange
        )
    }

    static func objectiveCMutationCanChangeSemanticSignature(
        _ mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString,
        previousIndex: ObjectiveCSemanticIndex?
    ) -> Bool {
        if objectiveCMutationReplacesPreviousStructuralSignatureText(mutation, previousIndex: previousIndex) {
            return true
        }
        if objectiveCMutationMovesPreviousStructuralSignatureIntoNonCode(
            mutation,
            in: source,
            previousIndex: previousIndex
        ) {
            return true
        }
        if let previousIndex,
           let shiftedLineSignatureIndex = previousIndex.lineSignatureIndex.applying(mutation, to: source) {
            return shiftedLineSignatureIndex.fingerprint != previousIndex.structuralFingerprint
        }
        if mutation.replacement.rangeOfCharacter(from: objectiveCSemanticStructuralCharacters) != nil {
            return true
        }

        let replacementLength = mutation.replacement.utf16.count
        let changedLocation = min(max(0, mutation.location), source.length)
        let changedStart = max(0, changedLocation - (mutation.length > 0 ? 1 : 0))
        let changedEnd = min(source.length, max(changedLocation + max(1, replacementLength), changedStart + 1))
        let changedRange = NSRange(location: changedStart, length: changedEnd - changedStart)
        let lineRange = source.lineRange(for: changedRange)
        let line = source.substring(with: lineRange) as NSString
        let lineString = line as String
        let fullRange = NSRange(location: 0, length: line.length)
        let relativeChangedRange = NSRange(
            location: max(0, changedRange.location - lineRange.location),
            length: changedRange.length
        )

        if objectiveCVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            let statementEnd = line.range(of: ";").location
            guard statementEnd != NSNotFound else { return true }
            return objectiveCDeclarationSignatureRanges(in: line, statementEnd: statementEnd)
                .contains { rangesIntersect($0, relativeChangedRange) }
        }

        if objectiveCForLoopVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            return objectiveCDeclarationSignatureRanges(in: line, statementEnd: line.length)
                .contains { rangesIntersect($0, relativeChangedRange) }
        }

        return structuralObjectiveCEditRegex.firstMatch(in: lineString, range: fullRange) != nil
            || objectiveCSemanticIndexFunctionSignatureLineRegex.firstMatch(in: lineString, range: fullRange) != nil
            || objectiveCSemanticIndexSplitFunctionNameLineRegex.firstMatch(in: lineString, range: fullRange) != nil
    }

    static func objectiveCLocalStructuralRefreshRange(
        for mutation: SyntaxEditorTextChange.Replacement,
        in source: NSString,
        previousIndex: ObjectiveCSemanticIndex?
    ) -> NSRange? {
        if objectiveCMutationReplacesPreviousStructuralSignatureText(mutation, previousIndex: previousIndex) {
            return nil
        }

        let replacementLength = mutation.replacement.utf16.count
        let changedLocation = min(max(0, mutation.location), source.length)
        let changedStart = max(0, changedLocation - (mutation.length > 0 ? 1 : 0))
        let changedEnd = min(source.length, max(changedLocation + max(1, replacementLength), changedStart + 1))
        let changedRange = NSRange(location: changedStart, length: changedEnd - changedStart)
        let lineRange = source.lineRange(for: changedRange)
        guard let scopeRange = ObjectiveCFileSymbolIndex.containingFunctionLikeScopeRange(
            containing: changedRange.location,
            in: source
        ) else {
            return nil
        }

        let line = source.substring(with: lineRange) as NSString
        let lineString = line as String
        let fullRange = NSRange(location: 0, length: line.length)
        let relativeChangedRange = NSRange(
            location: max(0, changedRange.location - lineRange.location),
            length: changedRange.length
        )

        if objectiveCVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            let statementEnd = line.range(of: ";").location
            guard statementEnd != NSNotFound else { return nil }
            let changesDeclarationName = objectiveCDeclarationSignatureRanges(in: line, statementEnd: statementEnd)
                .contains { rangesIntersect($0, relativeChangedRange) }
            return changesDeclarationName ? scopeRange : nil
        }

        if objectiveCForLoopVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            let changesDeclarationName = objectiveCDeclarationSignatureRanges(in: line, statementEnd: line.length)
                .contains { rangesIntersect($0, relativeChangedRange) }
            return changesDeclarationName ? scopeRange : nil
        }

        return nil
    }

    private static func objectiveCMutationCanChangeMemberAccessReceiver(
        line: NSString,
        relativeChangedRange: NSRange
    ) -> Bool {
        guard line.range(of: ".").location != NSNotFound
            || line.range(of: "->").location != NSNotFound
        else {
            return false
        }

        var cursor = 0
        while cursor < line.length {
            if let nextCursor = locationAfterSkippedCommentOrLiteral(startingAt: cursor, in: line) {
                cursor = nextCursor
                continue
            }

            let operatorRange: NSRange
            let character = line.substring(with: NSRange(location: cursor, length: 1))
            if character == "." {
                operatorRange = NSRange(location: cursor, length: 1)
            } else if character == "-",
                      cursor + 1 < line.length,
                      line.substring(with: NSRange(location: cursor + 1, length: 1)) == ">" {
                operatorRange = NSRange(location: cursor, length: 2)
            } else {
                cursor += 1
                continue
            }

            let expressionStart = expressionBoundaryBefore(location: operatorRange.location, in: line)
            guard expressionStart < operatorRange.location else {
                let operatorContextRange = NSRange(
                    location: max(0, operatorRange.location - 1),
                    length: min(line.length, operatorRange.upperBound + 1) - max(0, operatorRange.location - 1)
                )
                if rangesIntersect(operatorContextRange, relativeChangedRange),
                   memberFieldIdentifierRange(after: operatorRange.upperBound, in: line) != nil {
                    return true
                }
                cursor = operatorRange.upperBound
                continue
            }
            let expressionRange = NSRange(
                location: expressionStart,
                length: operatorRange.location - expressionStart
            )
            guard (rangesIntersect(expressionRange, relativeChangedRange)
                   || rangesIntersect(operatorRange, relativeChangedRange)),
                  memberFieldIdentifierRange(after: operatorRange.upperBound, in: line) != nil
            else {
                cursor = operatorRange.upperBound
                continue
            }
            return true
        }

        return false
    }

    private static func objectiveCMutationCanChangeMemberAccessField(
        line: NSString,
        relativeChangedRange: NSRange
    ) -> Bool {
        guard line.range(of: ".").location != NSNotFound
            || line.range(of: "->").location != NSNotFound
        else {
            return false
        }

        var cursor = 0
        while cursor < line.length {
            if let nextCursor = locationAfterSkippedCommentOrLiteral(startingAt: cursor, in: line) {
                cursor = nextCursor
                continue
            }

            let operatorRange: NSRange
            let character = line.substring(with: NSRange(location: cursor, length: 1))
            if character == "." {
                operatorRange = NSRange(location: cursor, length: 1)
            } else if character == "-",
                      cursor + 1 < line.length,
                      line.substring(with: NSRange(location: cursor + 1, length: 1)) == ">" {
                operatorRange = NSRange(location: cursor, length: 2)
            } else {
                cursor += 1
                continue
            }

            guard let fieldRange = memberFieldIdentifierRange(after: operatorRange.upperBound, in: line) else {
                cursor = operatorRange.upperBound
                continue
            }
            if rangesIntersect(fieldRange, relativeChangedRange) {
                return true
            }
            cursor = fieldRange.upperBound
        }

        return false
    }

    private static func memberFieldIdentifierRange(after location: Int, in line: NSString) -> NSRange? {
        var cursor = location
        while cursor < line.length {
            let character = line.substring(with: NSRange(location: cursor, length: 1)).first
            guard character?.isWhitespace == true else { break }
            cursor += 1
        }
        guard cursor < line.length,
              let firstCharacter = line.substring(with: NSRange(location: cursor, length: 1)).first,
              firstCharacter == "_" || firstCharacter.isLetter else {
            return nil
        }

        let start = cursor
        cursor += 1
        while cursor < line.length {
            guard let character = line.substring(with: NSRange(location: cursor, length: 1)).first,
                  isObjectiveCIdentifierCharacter(character) else {
                break
            }
            cursor += 1
        }
        return NSRange(location: start, length: cursor - start)
    }

    static func appendObjectiveCSemanticIndexSignature(
        from line: NSString,
        lineOffset _: Int,
        into hasher: inout Hasher
    ) -> Bool {
        let lineString = line as String
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let trimmed = lineString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("#") {
            hasher.combine("preprocessor")
            hasher.combine(trimmed)
            return true
        }

        if trimmed.hasPrefix("@property") {
            hasher.combine("property")
            if let nameRange = ObjectiveCFileSymbolIndex.propertyDeclaredNameRange(in: line) {
                hasher.combine(line.substring(with: nameRange))
                hasher.combine(nameRange.location)
            } else {
                hasher.combine(trimmed)
            }
            return true
        }

        if objectiveCForLoopVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            appendObjectiveCDeclarationNameSignature(
                kind: "for-variable",
                line: line,
                statementEnd: line.length,
                into: &hasher
            )
            return true
        }

        if objectiveCVariableDeclarationLineRegex.firstMatch(in: lineString, range: fullRange) != nil {
            let statementEnd = line.range(of: ";").location
            guard statementEnd != NSNotFound else { return false }
            appendObjectiveCDeclarationNameSignature(
                kind: "variable",
                line: line,
                statementEnd: statementEnd,
                into: &hasher
            )
            return true
        }

        guard structuralObjectiveCEditRegex.firstMatch(in: lineString, range: fullRange) != nil
            || objectiveCSemanticIndexFunctionSignatureLineRegex.firstMatch(in: lineString, range: fullRange) != nil
            || objectiveCSemanticIndexSplitFunctionNameLineRegex.firstMatch(in: lineString, range: fullRange) != nil else {
            return false
        }

        hasher.combine("structural")
        let identifiers = ObjectiveCFileSymbolIndex.identifierRegex.matches(in: lineString, range: fullRange)
        if identifiers.isEmpty {
            hasher.combine(trimmed)
            return true
        }
        for match in identifiers {
            let name = line.substring(with: match.range)
            guard !ObjectiveCFileSymbolIndex.typedefIgnoredIdentifiers.contains(name) else { continue }
            hasher.combine(name)
        }
        return true
    }

    private static func appendObjectiveCDeclarationNameSignature(
        kind: String,
        line: NSString,
        statementEnd: Int,
        into hasher: inout Hasher
    ) {
        let ranges = ObjectiveCFileSymbolIndex.declarationNameRanges(in: line, statementEnd: statementEnd)
        guard !ranges.isEmpty else { return }
        hasher.combine(kind)
        hasher.combine(objectiveCDeclarationShapeSignature(in: line, nameRanges: ranges, statementEnd: statementEnd))
        for range in ranges {
            let name = line.substring(with: range)
            guard !ObjectiveCFileSymbolIndex.typedefIgnoredIdentifiers.contains(name),
                  name != "const",
                  name != "static" else {
                continue
            }
            hasher.combine(name)
        }
    }

    private static func objectiveCDeclarationSignatureRanges(in line: NSString, statementEnd: Int) -> [NSRange] {
        let nameRanges = ObjectiveCFileSymbolIndex.declarationNameRanges(in: line, statementEnd: statementEnd)
        guard let firstNameRange = nameRanges.min(by: { $0.location < $1.location }) else { return [] }
        let shapeRange = NSRange(location: 0, length: max(0, min(firstNameRange.location, statementEnd)))
        if shapeRange.length > 0 {
            return [shapeRange] + nameRanges
        }
        return nameRanges
    }

    private static func objectiveCDeclarationShapeSignature(
        in line: NSString,
        nameRanges: [NSRange],
        statementEnd: Int
    ) -> String {
        guard let firstNameRange = nameRanges.min(by: { $0.location < $1.location }) else { return "" }
        let shapeLength = max(0, min(firstNameRange.location, statementEnd))
        guard shapeLength > 0 else { return "" }
        return line.substring(with: NSRange(location: 0, length: shapeLength))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func objectiveCTextContainsVariableDeclarationLine(_ text: NSString) -> Bool {
        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange)
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            if objectiveCVariableDeclarationLineRegex.firstMatch(in: line, range: fullRange) != nil
                || objectiveCForLoopVariableDeclarationLineRegex.firstMatch(in: line, range: fullRange) != nil {
                return true
            }
            let nextLocation = lineRange.upperBound
            guard nextLocation > location else { break }
            location = nextLocation
        }
        return false
    }

    private static func isTypeDeclarationName(_ range: NSRange, text: String, in source: NSString) -> Bool {
        let prefix = linePrefix(before: range, in: source)
            .trimmingCharacters(in: .whitespaces)
        if prefix.range(
            of: #"@(?:interface|implementation|protocol)\s*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if prefix.range(
            of: #"@class(?:\s+[A-Za-z_][A-Za-z0-9_]*\s*,\s*)*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if prefix.contains("typedef") {
            return typedefDeclarationName(around: range, in: source) == text
        }
        return false
    }

    private static func objectiveCTypeIdentifierShouldStayPlain(
        _ range: NSRange,
        text: String,
        in source: NSString
    ) -> Bool {
        let prefix = linePrefix(before: range, in: source)
        if prefix.contains("@property"), isUppercaseMacroLikeIdentifier(text) {
            return propertyMacroLikeIdentifierHasTrailingAttribute(range, in: source)
        }
        return prefix.range(
            of: #"\bNS_(?:ENUM|OPTIONS)\s*\(\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func propertyMacroLikeIdentifierHasTrailingAttribute(
        _ range: NSRange,
        in source: NSString
    ) -> Bool {
        let lineRange = source.lineRange(for: range)
        guard range.upperBound < lineRange.upperBound else {
            return false
        }
        let suffixRange = NSRange(
            location: range.upperBound,
            length: lineRange.upperBound - range.upperBound
        )
        let suffix = source.substring(with: suffixRange)
        guard let semicolon = suffix.firstIndex(of: ";") else {
            return false
        }
        let beforeSemicolon = suffix[..<semicolon]
        return beforeSemicolon.contains { !$0.isWhitespace }
    }

    private static func isUppercaseMacroLikeIdentifier(_ text: String) -> Bool {
        var hasUppercase = false
        var hasSeparator = false
        for scalar in text.unicodeScalars {
            if scalar == "_" {
                hasSeparator = true
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                continue
            }
            guard CharacterSet.uppercaseLetters.contains(scalar) else {
                return false
            }
            hasUppercase = true
        }
        return hasUppercase && hasSeparator
    }

    private static func isCFunctionCallName(_ range: NSRange, in source: NSString) -> Bool {
        cCallOpeningParenLocation(after: range, in: source) != nil
    }

    private static func isObjectiveCCallName(_ range: NSRange, in source: NSString) -> Bool {
        isCFunctionCallName(range, in: source)
            && !lineStartsWithPreprocessorDirective(containing: range, in: source)
            && !isObjectiveCCFunctionDeclarationName(range, in: source)
    }

    private static func isObjectiveCFunctionPointerCastCalleeName(_ range: NSRange, in source: NSString) -> Bool {
        guard !lineStartsWithPreprocessorDirective(containing: range, in: source),
              !functionPointerNameLooksLikeDeclaration(range, in: source)
        else {
            return false
        }
        var cursor = range.upperBound
        while cursor < source.length {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor += 1
                continue
            }
            guard character == ")" else {
                return false
            }
            cursor += 1
            while cursor < source.length {
                let next = source.substring(with: NSRange(location: cursor, length: 1))
                if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cursor += 1
                    continue
                }
                return next == "("
            }
            return false
        }
        return false
    }

    private static func cCallOpeningParenLocation(after range: NSRange, in source: NSString) -> Int? {
        var cursor = range.upperBound
        while cursor < source.length {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor += 1
                continue
            }
            return character == "(" ? cursor : nil
        }
        return nil
    }

    private static func functionPointerNameLooksLikeDeclaration(_ range: NSRange, in source: NSString) -> Bool {
        let prefix = linePrefix(before: range, in: source)
        if prefix.contains("@property") {
            return true
        }
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        if trimmedPrefix.hasPrefix("typedef") {
            return true
        }
        if trimmedPrefix.range(
            of: #"^(?:[A-Za-z_][A-Za-z0-9_]*\s+)+\*+$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }

    private static func looksLikeCFunctionDeclarationPrefix(before range: NSRange, in source: NSString) -> Bool {
        let prefix = linePrefix(before: range, in: source)
            .trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty == false else {
            return false
        }
        if prefix == "return" || prefix.hasSuffix("=") || prefix.hasSuffix("(") || prefix.hasSuffix(",") {
            return false
        }
        if prefix.hasSuffix(".") || prefix.hasSuffix("->") || prefix.hasSuffix("[") {
            return false
        }
        return true
    }

    private static func isObjectiveCFunctionOrMethodDeclarationName(_ range: NSRange, in source: NSString) -> Bool {
        let prefix = linePrefix(before: range, in: source)
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        if trimmedPrefix.hasPrefix("-") || trimmedPrefix.hasPrefix("+") {
            return true
        }
        if prefix.contains("[") {
            return false
        }
        return looksLikeCFunctionDeclarationPrefix(before: range, in: source)
    }

    static func isObjectiveCCFunctionDeclarationName(_ range: NSRange, in source: NSString) -> Bool {
        let prefix = linePrefix(before: range, in: source)
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmedPrefix.hasPrefix("-"),
              !trimmedPrefix.hasPrefix("+"),
              !prefix.contains("[")
        else {
            return false
        }
        guard looksLikeCFunctionDeclarationPrefix(before: range, in: source),
              let openParen = cCallOpeningParenLocation(after: range, in: source),
              let closeParenRange = matchingCloseParenRange(openingAt: openParen, in: source)
        else {
            return false
        }
        var cursor = closeParenRange.upperBound
        while cursor < source.length {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor += 1
                continue
            }
            return character == "{" || character == ";"
        }
        return false
    }

    private static func isMessageReceiverName(_ range: NSRange, in source: NSString) -> Bool {
        previousNonWhitespaceCharacter(before: range, in: source) == "["
    }

    static func isSelfMemberName(_ range: NSRange, in source: NSString) -> Bool {
        guard let expressionPrefix = memberAccessExpressionPrefix(before: range, in: source) else {
            return false
        }
        return expressionPrefixEndsWithSelf(expressionPrefix)
    }

    static func isMemberNameInKnownSelfChain(
        _ range: NSRange,
        in source: NSString,
        localProperties: Set<String>,
        allowsHeaderBackedMembers: Bool
    ) -> Bool {
        guard let expressionPrefix = memberAccessExpressionPrefix(before: range, in: source) else {
            return false
        }

        let expression = expressionPrefix as NSString
        let matches = selfRootMemberRegex.matches(
            in: expressionPrefix,
            range: NSRange(location: 0, length: expression.length)
        )
        for match in matches.reversed() {
            let selfRange = match.range(at: 2)
            let wrappedSelfClosingRange = match.range(at: 3)
            let firstMemberRange = match.range(at: 4)
            guard selfRange.location != NSNotFound,
                  firstMemberRange.location != NSNotFound else {
                continue
            }
            if isInsideCommentOrLiteral(selfRange, in: expression) {
                continue
            }
            let firstMember = expression.substring(with: firstMemberRange)
            guard shouldTrackSelfMember(
                firstMember,
                localProperties: localProperties,
                allowsHeaderBackedMembers: allowsHeaderBackedMembers
            ) else {
                continue
            }
            let beforeSelf = expression.substring(to: selfRange.location)
            if wrappedSelfClosingRange.location != NSNotFound,
               wrappedSelfClosingRange.length > 0,
               !allowsWrappedSelfChainStart(beforeSelf) {
                continue
            }
            let suffix = expression.substring(from: match.range.upperBound)
            if suffixStartsWithCall(suffix) || suffixContainsNestedMemberAccess(suffix) {
                continue
            }
            let hasUnmatchedClosing = hasUnmatchedClosingDelimiter(suffix)
            let allowsWrappedSelfChainClose = hasUnmatchedClosing
                && !hasUnmatchedClosingSquareBracket(suffix)
                && containsOnlyClosingParenthesesAndWhitespace(suffix)
                && allowsWrappedSelfChainStart(beforeSelf)
            if keepsSelfChainConnected(suffix)
                && !hasUnmatchedOpeningDelimiter(suffix)
                && (!hasUnmatchedClosing || allowsWrappedSelfChainClose) {
                return true
            }
        }
        return false
    }

    static func shouldTrackSelfMember(
        _ name: String,
        localProperties: Set<String>,
        allowsHeaderBackedMembers: Bool
    ) -> Bool {
        if localProperties.contains(name) {
            return true
        }
        guard allowsHeaderBackedMembers else {
            return false
        }

        // Objective-C implementations can rely on properties declared in an imported
        // header that the runtime highlighter cannot load. Keep a lexical fallback
        // for header-backed self members, while avoiding macro-shaped declarations
        // that Xcode leaves plain in the current fixtures.
        return !isUppercaseMacroLikeIdentifier(name)
    }

    private static func suffixStartsWithCall(_ suffix: String) -> Bool {
        var index = suffix.startIndex
        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            if character.isWhitespace {
                index = suffix.index(after: index)
                continue
            }
            return character == "("
        }
        return false
    }

    private static func suffixContainsNestedMemberAccess(_ suffix: String) -> Bool {
        var index = suffix.startIndex
        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            if character == "." {
                return true
            }
            if character == "-" {
                let nextIndex = suffix.index(after: index)
                if nextIndex < suffix.endIndex, suffix[nextIndex] == ">" {
                    return true
                }
            }
            index = suffix.index(after: index)
        }
        return false
    }

    private static func memberAccessExpressionPrefix(before range: NSRange, in source: NSString) -> String? {
        guard let operatorRange = memberAccessOperatorRange(before: range, in: source) else {
            return nil
        }

        let start = expressionBoundaryBefore(location: operatorRange.location, in: source)
        guard start < operatorRange.location else {
            return nil
        }
        return source.substring(with: NSRange(location: start, length: operatorRange.location - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func memberAccessOperatorRange(before range: NSRange, in source: NSString) -> NSRange? {
        guard range.location > 0 else {
            return nil
        }

        var cursor = range.location - 1
        while cursor >= 0 {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                break
            }
            if cursor == 0 {
                return nil
            }
            cursor -= 1
        }

        let operatorStart: Int
        let character = source.substring(with: NSRange(location: cursor, length: 1))
        if character == "." {
            operatorStart = cursor
        } else if character == ">", cursor > 0,
                  source.substring(with: NSRange(location: cursor - 1, length: 1)) == "-" {
            operatorStart = cursor - 1
        } else {
            return nil
        }

        return NSRange(location: operatorStart, length: range.location - operatorStart)
    }

    private static func expressionBoundaryBefore(location: Int, in source: NSString) -> Int {
        guard location > 0 else {
            return 0
        }

        var cursor = location - 1
        while cursor >= 0 {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if let nextCursor = indexBeforeQuotedLiteralEnding(at: cursor, in: source) {
                cursor = nextCursor
                continue
            }
            if character == ";" || character == "{" || character == "}" {
                return cursor + 1
            }
            if cursor == 0 {
                break
            }
            cursor -= 1
        }
        return 0
    }

    private static func indexBeforeQuotedLiteralEnding(at location: Int, in source: NSString) -> Int? {
        let quote = source.substring(with: NSRange(location: location, length: 1))
        guard quote == "\"" || quote == "'",
              !isEscaped(location, in: source) else {
            return nil
        }

        var cursor = location - 1
        while cursor >= 0 {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character == quote, !isEscaped(cursor, in: source) {
                if quote == "\"",
                   cursor > 0,
                   source.substring(with: NSRange(location: cursor - 1, length: 1)) == "@" {
                    return cursor - 2
                }
                return cursor - 1
            }
            cursor -= 1
        }
        return nil
    }

    private static func isEscaped(_ location: Int, in source: NSString) -> Bool {
        var backslashCount = 0
        var cursor = location - 1
        while cursor >= 0,
              source.substring(with: NSRange(location: cursor, length: 1)) == "\\" {
            backslashCount += 1
            cursor -= 1
        }
        return backslashCount % 2 == 1
    }

    private static func expressionPrefixEndsWithSelf(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if expressionPrefixDirectlyEndsWithSelf(trimmed) {
            return true
        }
        return parenthesizedSelfSuffixEndsWithSelf(trimmed)
    }

    private static func expressionPrefixDirectlyEndsWithSelf(_ prefix: String) -> Bool {
        guard prefix.hasSuffix("self") else {
            return false
        }
        let beforeSelf = prefix.dropLast("self".count)
        guard let previous = beforeSelf.last else {
            return true
        }
        return !isObjectiveCIdentifierCharacter(previous)
    }

    private static func parenthesizedSelfSuffixEndsWithSelf(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.last == ")" else {
            return false
        }

        var depth = 0
        var index = trimmed.index(before: trimmed.endIndex)
        while true {
            let character = trimmed[index]
            if character == ")" {
                depth += 1
            } else if character == "(" {
                depth -= 1
                if depth == 0 {
                    let innerStart = trimmed.index(after: index)
                    let innerEnd = trimmed.index(before: trimmed.endIndex)
                    let inner = String(trimmed[innerStart..<innerEnd])
                    let before = String(trimmed[..<index])
                    return allowsWrappedSelfChainStart(before)
                        && expressionPrefixIsBareOrCastWrappedSelf(inner)
                }
                if depth < 0 {
                    return false
                }
            }

            if index == trimmed.startIndex {
                break
            }
            index = trimmed.index(before: index)
        }
        return false
    }

    private static func expressionPrefixIsBareOrCastWrappedSelf(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "self" {
            return true
        }
        if parenthesizedSelfSuffixEndsWithSelf(trimmed) {
            return true
        }
        guard trimmed.hasSuffix("self") else {
            return false
        }
        let beforeSelf = String(trimmed.dropLast("self".count))
        return allowsCastOnlyPrefixBeforeSelf(beforeSelf)
    }

    private static func allowsCastOnlyPrefixBeforeSelf(_ beforeSelf: String) -> Bool {
        var prefix = beforeSelf.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            while let match = trailingCastRegex.firstMatch(
                in: prefix,
                range: NSRange(location: 0, length: (prefix as NSString).length)
            ) {
                prefix = (prefix as NSString).substring(to: match.range.location)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }

            while prefix.hasSuffix("(") {
                prefix = String(prefix.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return prefix.isEmpty
    }

    private static func isInsideCommentOrLiteral(_ range: NSRange, in text: NSString) -> Bool {
        var cursor = 0
        var quote: String?
        var isLineComment = false
        var isBlockComment = false
        var isEscaped = false

        while cursor < min(range.location, text.length) {
            let character = text.substring(with: NSRange(location: cursor, length: 1))
            let next = cursor + 1 < text.length
                ? text.substring(with: NSRange(location: cursor + 1, length: 1))
                : ""

            if isLineComment {
                if character == "\n" || character == "\r" {
                    isLineComment = false
                }
            } else if isBlockComment {
                if character == "*", next == "/" {
                    isBlockComment = false
                    cursor += 1
                }
            } else if let activeQuote = quote {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "/", next == "/" {
                isLineComment = true
                cursor += 1
            } else if character == "/", next == "*" {
                isBlockComment = true
                cursor += 1
            } else if character == "\"" || character == "'" {
                quote = character
            }

            cursor += 1
        }

        return quote != nil || isLineComment || isBlockComment
    }

    private static func keepsSelfChainConnected(_ suffix: String) -> Bool {
        var parenDepth = 0
        var bracketDepth = 0
        var index = suffix.startIndex

        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            switch character {
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth > 0 {
                    parenDepth -= 1
                }
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth > 0 {
                    bracketDepth -= 1
                }
            case ";", "{", "}":
                return false
            case "=", "?", ":":
                if parenDepth == 0 && bracketDepth == 0 {
                    return false
                }
            case ",":
                if parenDepth == 0 && bracketDepth == 0 {
                    return false
                }
            case "-":
                let nextIndex = suffix.index(after: index)
                if nextIndex < suffix.endIndex, suffix[nextIndex] == ">" {
                    index = suffix.index(after: nextIndex)
                    continue
                }
                if parenDepth == 0 && bracketDepth == 0 {
                    return false
                }
            case "+", "*", "/", "%", "&", "|", "^", "!", "~", "<", ">":
                if parenDepth == 0 && bracketDepth == 0 {
                    return false
                }
            default:
                break
            }
            index = suffix.index(after: index)
        }

        return true
    }

    private static func indexAfterSkippableTriviaOrLiteral(
        startingAt index: String.Index,
        in text: String
    ) -> String.Index? {
        if let nextIndex = indexAfterComment(startingAt: index, in: text) {
            return nextIndex
        }
        if let nextIndex = indexAfterLiteral(startingAt: index, in: text) {
            return nextIndex
        }
        return nil
    }

    private static func indexAfterComment(startingAt index: String.Index, in text: String) -> String.Index? {
        guard text[index] == "/" else {
            return nil
        }
        let markerIndex = text.index(after: index)
        guard markerIndex < text.endIndex else {
            return nil
        }

        if text[markerIndex] == "/" {
            var cursor = text.index(after: markerIndex)
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "\n" || character == "\r" {
                    return text.index(after: cursor)
                }
                cursor = text.index(after: cursor)
            }
            return text.endIndex
        }

        if text[markerIndex] == "*" {
            var cursor = text.index(after: markerIndex)
            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                if text[cursor] == "*", next < text.endIndex, text[next] == "/" {
                    return text.index(after: next)
                }
                cursor = next
            }
        }
        return nil
    }

    private static func indexAfterLiteral(startingAt index: String.Index, in text: String) -> String.Index? {
        let character = text[index]
        if character == "@" {
            let nextIndex = text.index(after: index)
            guard nextIndex < text.endIndex, text[nextIndex] == "\"" else {
                return nil
            }
            return indexAfterQuotedLiteral(startingAt: nextIndex, in: text)
        }
        if character == "\"" || character == "'" {
            return indexAfterQuotedLiteral(startingAt: index, in: text)
        }
        return nil
    }

    private static func indexAfterQuotedLiteral(startingAt quoteIndex: String.Index, in text: String) -> String.Index {
        let quote = text[quoteIndex]
        var isEscaped = false
        var cursor = text.index(after: quoteIndex)
        while cursor < text.endIndex {
            let character = text[cursor]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == quote {
                return text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        return text.endIndex
    }

    private static func hasUnmatchedClosingDelimiter(_ suffix: String) -> Bool {
        var parenDepth = 0
        var bracketDepth = 0
        var index = suffix.startIndex

        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            switch character {
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth == 0 {
                    return true
                }
                parenDepth -= 1
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth == 0 {
                    return true
                }
                bracketDepth -= 1
            default:
                break
            }
            index = suffix.index(after: index)
        }

        return false
    }

    private static func hasUnmatchedClosingSquareBracket(_ suffix: String) -> Bool {
        var bracketDepth = 0
        var index = suffix.startIndex

        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            switch character {
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth == 0 {
                    return true
                }
                bracketDepth -= 1
            default:
                break
            }
            index = suffix.index(after: index)
        }

        return false
    }

    private static func containsOnlyClosingParenthesesAndWhitespace(_ suffix: String) -> Bool {
        var index = suffix.startIndex
        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            guard character == ")" || character.isWhitespace else {
                return false
            }
            index = suffix.index(after: index)
        }
        return true
    }

    private static func hasUnmatchedOpeningDelimiter(_ suffix: String) -> Bool {
        var parenDepth = 0
        var bracketDepth = 0
        var index = suffix.startIndex

        while index < suffix.endIndex {
            if let nextIndex = indexAfterSkippableTriviaOrLiteral(startingAt: index, in: suffix) {
                index = nextIndex
                continue
            }
            let character = suffix[index]
            switch character {
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth > 0 {
                    parenDepth -= 1
                }
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth > 0 {
                    bracketDepth -= 1
                }
            default:
                break
            }
            index = suffix.index(after: index)
        }

        return parenDepth > 0 || bracketDepth > 0
    }

    private static func allowsWrappedSelfChainStart(_ beforeSelf: String) -> Bool {
        var prefix = beforeSelf.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            while let match = trailingCastRegex.firstMatch(
                in: prefix,
                range: NSRange(location: 0, length: (prefix as NSString).length)
            ) {
                prefix = (prefix as NSString).substring(to: match.range.location)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }

            while prefix.hasSuffix("(") {
                prefix = String(prefix.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        guard prefix.isEmpty == false else {
            return true
        }
        if parenthesizedSelfPrefixKeywords.contains(prefix) {
            return true
        }
        guard let previous = prefix.last else {
            return true
        }
        return previous == "=" || parenthesizedSelfPrefixOperators.contains(previous)
    }

    private static func previousNonWhitespaceCharacter(before range: NSRange, in source: NSString) -> Character? {
        guard range.location > 0 else {
            return nil
        }
        var cursor = range.location - 1
        while cursor >= 0 {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return character.first
            }
            if cursor == 0 {
                break
            }
            cursor -= 1
        }
        return nil
    }

    private static func linePrefix(before range: NSRange, in source: NSString) -> String {
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let prefixLength = max(0, range.location - lineRange.location)
        return source.substring(with: NSRange(location: lineRange.location, length: prefixLength))
    }

    private static func typedefDeclarationName(around range: NSRange, in source: NSString) -> String? {
        let before = source.substring(to: min(range.location, source.length))
        guard let typedefRange = before.range(of: "typedef", options: .backwards) else {
            return nil
        }

        let start = before.distance(from: before.startIndex, to: typedefRange.lowerBound)
        let remaining = source.substring(from: start)
        guard let semicolon = remaining.firstIndex(of: ";") else {
            return nil
        }

        let length = remaining.distance(from: remaining.startIndex, to: semicolon) + 1
        let declaration = source.substring(with: NSRange(location: start, length: length)) as NSString
        return ObjectiveCFileSymbolIndex.typedefDeclaredName(in: declaration)
    }

    private static func canonicalToken(
        range: NSRange,
        syntaxID: EditorSourceSyntax.ID
    ) -> SyntaxEditorHighlighting.Token {
        SyntaxEditorHighlighting.Token(
            range: range,
            syntaxID: syntaxID,
            language: .objectiveC,
            rawCaptureName: EditorSourceSyntax.Capture.rawCaptureName(syntaxID: syntaxID, language: .objectiveC),
            isSemanticOverlay: true
        )
    }

    static func isObjectiveCSemanticOverlayToken(
        _ token: SyntaxEditorHighlighting.Token,
        syntaxIDsAtSameRange: ObjectiveCSyntaxIDMask,
        source: NSString,
        preprocessorRanges: [NSRange],
        strippingSemanticOverlaysIn stripRange: NSRange?
    ) -> Bool {
        guard token.language == .objectiveC || token.language == nil else {
            return false
        }
        if let stripRange,
           !rangesIntersect(token.range, stripRange) {
            return false
        }
        switch token.syntaxID {
        case .plain:
            guard token.range.upperBound <= source.length else {
                return false
            }
            let text = source.substring(with: token.range)
            return (text == "Class" && syntaxIDsAtSameRange.contains(.keyword))
                || objectiveCTypeIdentifierShouldStayPlain(token.range, text: text, in: source)
        case .declarationType,
             .identifierConstantSystem:
            return true
        case .identifierTypeSystem:
            guard token.range.upperBound <= source.length else {
                return false
            }
            return objectiveCTypeIdentifierShouldStayPlain(
                token.range,
                text: source.substring(with: token.range),
                in: source
            )
        case .string:
            guard token.range.location >= 0,
                  token.range.length > 0,
                  token.range.upperBound <= source.length,
                  source.substring(with: NSRange(location: token.range.location, length: 1)) == "\"" else {
                return false
            }
            return lineStartsWithPreprocessorDirective(containing: token.range, in: source)
                && rangeIsContainedInPreprocessorToken(token.range, preprocessorRanges: preprocessorRanges)
        case .preprocessor:
            guard syntaxIDsAtSameRange.contains(.plain) else {
                return false
            }
            let text = source.substring(with: token.range)
            return !preprocessorObjectiveCMacroIdentifiers.contains(text)
                && !lineStartsWithPreprocessorDirective(containing: token.range, in: source)
        case .number:
            return isBoxedExpressionDelimiterRange(token.range, in: source)
                || isBoxedBooleanLiteralRange(token.range, in: source)
                || isPotentialStaleBoxedLiteralNumberRange(token.range, in: source)
        case .declarationOther:
            return syntaxIDsAtSameRange.contains(.identifierFunction)
                || syntaxIDsAtSameRange.contains(.identifier)
        case .identifierType:
            if syntaxIDsAtSameRange.contains(.identifierTypeSystem) {
                return true
            }
            guard token.range.upperBound <= source.length else {
                return false
            }
            let text = source.substring(with: token.range)
            return syntaxIDsAtSameRange.contains(.identifier)
                && isMessageReceiverName(token.range, in: source)
                && !isTypeDeclarationName(token.range, text: text, in: source)
        case .identifierFunction:
            if syntaxIDsAtSameRange.contains(.identifierFunctionSystem) {
                return true
            }
            guard token.range.upperBound <= source.length else {
                return false
            }
            if appleMacroFunctionNames.contains(source.substring(with: token.range)) {
                return true
            }
            return isCFunctionCallName(token.range, in: source)
                && !looksLikeCFunctionDeclarationPrefix(before: token.range, in: source)
        case .identifierVariable,
             .identifierVariableSystem:
            return true
        default:
            return false
        }
    }

    private static func isObjectiveCIdentifierRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0,
              range.length > 0,
              range.upperBound <= source.length,
              isObjectiveCIdentifierStart(source.character(at: range.location))
        else {
            return false
        }

        var cursor = range.location + 1
        while cursor < range.upperBound {
            guard isObjectiveCIdentifierContinue(source.character(at: cursor)) else {
                return false
            }
            cursor += 1
        }
        return true
    }

    private static func lineStartsWithPreprocessorDirective(containing range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0,
              range.location <= source.length else {
            return false
        }
        let location = min(range.location, max(source.length - 1, 0))
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let line = source.substring(with: lineRange)
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    private static func rangeIsContainedInPreprocessorToken(
        _ range: NSRange,
        preprocessorRanges: [NSRange]
    ) -> Bool {
        preprocessorRanges.contains { preprocessorRange in
            preprocessorRange != range
                && preprocessorRange.location <= range.location
                && preprocessorRange.upperBound >= range.upperBound
        }
    }

    private static func isBoxedExpressionDelimiterRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.length == 1,
              range.location >= 0,
              range.upperBound <= source.length else {
            return false
        }
        let character = source.substring(with: range)
        if character == "@" {
            return range.upperBound < source.length
                && source.substring(with: NSRange(location: range.upperBound, length: 1)) == "("
        }
        if character == "(" {
            return range.location > 0
                && source.substring(with: NSRange(location: range.location - 1, length: 1)) == "@"
        }
        if character == ")" {
            return boxedExpressionOpeningParenLocation(closingAt: range.location, in: source) != nil
        }
        return false
    }

    private static func isPotentialStaleBoxedExpressionDelimiterRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.length == 1,
              range.location >= 0,
              range.upperBound <= source.length else {
            return false
        }
        let character = source.substring(with: range)
        return character == "(" || character == ")"
    }

    private static func isPotentialStaleBoxedLiteralNumberRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0,
              range.length > 0,
              range.upperBound <= source.length else {
            return false
        }
        if isPotentialStaleBoxedExpressionDelimiterRange(range, in: source) {
            return true
        }
        let text = source.substring(with: range)
        if ["@", "{", "}", "[", "]"].contains(text) {
            return false
        }
        return objectiveCNumericLiteralTextRegex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ) == nil
    }

    private static func isBoxedBooleanLiteralRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0,
              range.upperBound <= source.length else {
            return false
        }
        let text = source.substring(with: range)
        if text == "@NO" || text == "@YES" {
            return true
        }
        guard text == "NO" || text == "YES",
              range.location > 0 else {
            return false
        }
        return source.substring(with: NSRange(location: range.location - 1, length: 1)) == "@"
    }

    private static func matchingCloseParenRange(openingAt openParenLocation: Int, in source: NSString) -> NSRange? {
        guard openParenLocation >= 0,
              openParenLocation < source.length,
              source.substring(with: NSRange(location: openParenLocation, length: 1)) == "(" else {
            return nil
        }

        var depth = 0
        var cursor = openParenLocation
        while cursor < source.length {
            if let nextCursor = locationAfterSkippedCommentOrLiteral(startingAt: cursor, in: source) {
                cursor = nextCursor
                continue
            }

            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: cursor, length: 1)
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func boxedExpressionOpeningParenLocation(closingAt closeParenLocation: Int, in source: NSString) -> Int? {
        guard closeParenLocation > 0,
              closeParenLocation < source.length,
              source.substring(with: NSRange(location: closeParenLocation, length: 1)) == ")" else {
            return nil
        }

        var depth = 0
        var cursor = closeParenLocation
        while cursor >= 0 {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character == ")" {
                depth += 1
            } else if character == "(" {
                depth -= 1
                if depth == 0 {
                    guard cursor > 0,
                          source.substring(with: NSRange(location: cursor - 1, length: 1)) == "@" else {
                        return nil
                    }
                    return cursor
                }
            }
            if cursor == 0 {
                break
            }
            cursor -= 1
        }
        return nil
    }

    private static func locationAfterSkippedCommentOrLiteral(startingAt location: Int, in source: NSString) -> Int? {
        guard location >= 0,
              location < source.length else {
            return nil
        }
        let character = source.substring(with: NSRange(location: location, length: 1))
        let next = location + 1 < source.length
            ? source.substring(with: NSRange(location: location + 1, length: 1))
            : ""

        if character == "\"" || character == "'" {
            var cursor = location + 1
            while cursor < source.length {
                if source.substring(with: NSRange(location: cursor, length: 1)) == character,
                   !isEscaped(cursor, in: source) {
                    return cursor + 1
                }
                cursor += 1
            }
            return source.length
        }

        if character == "/", next == "/" {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            return lineRange.upperBound
        }

        if character == "/", next == "*" {
            var cursor = location + 2
            while cursor + 1 < source.length {
                let current = source.substring(with: NSRange(location: cursor, length: 1))
                let following = source.substring(with: NSRange(location: cursor + 1, length: 1))
                if current == "*", following == "/" {
                    return cursor + 2
                }
                cursor += 1
            }
            return source.length
        }

        return nil
    }

    private static func isObjectiveCIdentifierStart(_ unit: unichar) -> Bool {
        unit == underscoreCodeUnit
            || (uppercaseACodeUnit...uppercaseZCodeUnit).contains(unit)
            || (lowercaseACodeUnit...lowercaseZCodeUnit).contains(unit)
    }

    private static func isObjectiveCIdentifierContinue(_ unit: unichar) -> Bool {
        isObjectiveCIdentifierStart(unit) || (zeroCodeUnit...nineCodeUnit).contains(unit)
    }

    private static let structuralObjectiveCEditRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*(?:@(?:class|end|implementation|interface|property|protocol)|typedef\b|static\b(?![^\n;{}]*\([^;{}]*\)\s*[;{])[^;\n{}]*(?:=|;)|[-+]\s*\(|[A-Za-z_][A-Za-z0-9_ <>,_*]*\([^;{}]*\)\s*[;{]|[A-Za-z_][A-Za-z0-9_ <>,_*]*\*+\s*[A-Za-z_][A-Za-z0-9_]*\s*;)|\bNS_(?:ENUM|OPTIONS)\b|^\s*#"#
    )

    private static let objectiveCVariableDeclarationLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?!(?:return|if|for|while|switch|case|break|continue|goto|else|do)\b)[A-Za-z_][A-Za-z0-9_ <>,_*]*[ \t*]+[A-Za-z_][A-Za-z0-9_]*\s*(?:=|;)"#
    )

    private static let objectiveCForLoopVariableDeclarationLineRegex = try! NSRegularExpression(
        pattern: #"\bfor\s*\(\s*[A-Za-z_][A-Za-z0-9_ <>,_*]*[ \t*]+[A-Za-z_][A-Za-z0-9_]*\s*(?:=|in\b)"#
    )

    private static let objectiveCSemanticIndexFunctionSignatureLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-+]\s*\(|(?:static\s+)?[A-Za-z_][A-Za-z0-9_ <>,_*]*[ \t*]+[A-Za-z_][A-Za-z0-9_]*\s*\()"#
    )

    private static let objectiveCSemanticIndexSplitFunctionNameLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?!(?:return|if|for|while|switch|case|break|continue|goto|else|do|sizeof)\b)[A-Za-z_][A-Za-z0-9_]*\s*\([^;{}=]*\)"#
    )

    private static let preprocessorQuotedStringRegex = try! NSRegularExpression(
        pattern: #"@?"(?:\\.|[^"\\])*""#
    )

    private static let boxedBooleanLiteralRegex = try! NSRegularExpression(
        pattern: #"@(YES|NO)\b"#
    )

    private static let objectiveCNumericLiteralTextRegex = try! NSRegularExpression(
        pattern: #"^(?:0[xX][0-9A-Fa-f_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)[uUlLfF]*$"#
    )

    private static let preprocessorObjectiveCMacroRegex = try! NSRegularExpression(
        pattern: #"\b(?:NS_ASSUME_NONNULL_BEGIN|NS_ASSUME_NONNULL_END|NS_ENUM|NS_OPTIONS|NS_SWIFT_NAME)\b"#
    )

    private static let macroLikeObjectiveCIdentifierRegex = try! NSRegularExpression(
        pattern: #"\b[A-Z][A-Z0-9_]*_[A-Z0-9_]+\b"#
    )

    private static let appleMacroFunctionNames: Set<String> = [
        "NS_ENUM",
        "NS_OPTIONS",
    ]

    private static let preprocessorObjectiveCMacroIdentifiers: Set<String> = [
        "NS_ASSUME_NONNULL_BEGIN",
        "NS_ASSUME_NONNULL_END",
        "NS_ENUM",
        "NS_OPTIONS",
        "NS_SWIFT_NAME",
    ]

    private static let knownObjectiveCSystemFunctionNames: Set<String> = [
        "NSClassFromString",
        "NSLog",
        "NSMakeRange",
        "NSSelectorFromString",
        "NSStringFromSelector",
        "calloc",
        "dispatch_once",
        "dlsym",
        "free",
        "objc_msgSend",
        "sel_getName",
        "strcmp",
        "strstr",
    ]

    private static let knownObjectiveCFunctionPointerCastCallees: Set<String> = [
        "objc_msgSend",
    ]

    private static func isObjectiveCIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static let selfRootMemberRegex = try! NSRegularExpression(
        pattern: #"(^|[^A-Za-z0-9_])(self)((?:\s*\))*)\s*(?:\.|->)([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static let trailingCastRegex = try! NSRegularExpression(
        pattern: #"\(\s*[A-Za-z_][A-Za-z0-9_ <>,*]*\s*\)\s*$"#
    )

    private static let keywordLikeTypeNames: Set<String> = [
        "BOOL", "IMP", "SEL", "id", "instancetype"
    ]

    private static let parenthesizedSelfPrefixKeywords: Set<String> = [
        "else if", "for", "if", "return", "switch", "while"
    ]

    private static let parenthesizedSelfPrefixOperators: Set<Character> = [
        "+", "-", "*", "/", "%", "&", "|", "^"
    ]

    private static let underscoreCodeUnit = unichar(95)
    private static let uppercaseACodeUnit = unichar(65)
    private static let uppercaseZCodeUnit = unichar(90)
    private static let lowercaseACodeUnit = unichar(97)
    private static let lowercaseZCodeUnit = unichar(122)
    private static let zeroCodeUnit = unichar(48)
    private static let nineCodeUnit = unichar(57)
}
