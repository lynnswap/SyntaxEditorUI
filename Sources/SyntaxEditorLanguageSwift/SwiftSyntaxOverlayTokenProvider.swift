import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter

// Provides Swift substring tokens that cannot be expressed by Tree-sitter
// captures alone, such as MARK comments and URLs inside comments.
/// Session state for the Swift semantic pass: the tree-derived scope index.
package struct SwiftSemanticOverlayState: SyntaxOverlayState {
    package var scopeIndex: SwiftScopeIndex?
    package var indexedSourceUTF16Length: Int

    package init(scopeIndex: SwiftScopeIndex? = nil, indexedSourceUTF16Length: Int) {
        self.scopeIndex = scopeIndex
        self.indexedSourceUTF16Length = indexedSourceUTF16Length
    }
}

package typealias SwiftSemanticOverlayResult = SyntaxOverlayResult

private struct SwiftIndexedToken {
    let range: NSRange
    let text: String
}

private struct SwiftTokenIndex {
    private let semanticCandidateTokens: [SwiftIndexedToken]

    init(tokens: [SyntaxEditorHighlighting.Token], source: NSString, targetRange: NSRange?) {
        var semanticCandidateTokens: [SwiftIndexedToken] = []
        semanticCandidateTokens.reserveCapacity(tokens.count / 3)

        for token in tokens {
            guard token.language == .swift || token.language == nil,
                  token.syntaxID == .plain,
                  token.range.location >= 0,
                  token.range.length > 0,
                  token.range.upperBound <= source.length,
                  targetRange.map({ Self.rangesIntersect(token.range, $0) }) ?? true
            else {
                continue
            }

            let text = source.nativeSubstring(with: token.range)
            guard SwiftSyntaxOverlayTokenProvider.isSwiftIdentifier(text) else {
                continue
            }
            semanticCandidateTokens.append(SwiftIndexedToken(range: token.range, text: text))
        }

        self.semanticCandidateTokens = semanticCandidateTokens.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length < $1.range.length
        }
    }

    func semanticTokens(intersecting targetRange: NSRange?) -> ArraySlice<SwiftIndexedToken> {
        guard let targetRange else {
            return semanticCandidateTokens[...]
        }

        let lowerBound = lowerBoundForLocation(targetRange.location)
        var upperBound = lowerBound
        while upperBound < semanticCandidateTokens.count,
              semanticCandidateTokens[upperBound].range.location < targetRange.upperBound {
            upperBound += 1
        }
        return semanticCandidateTokens[lowerBound..<upperBound]
    }

    private func lowerBoundForLocation(_ location: Int) -> Int {
        var lower = 0
        var upper = semanticCandidateTokens.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if semanticCandidateTokens[midpoint].range.upperBound <= location {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        max(lhs.location, rhs.location) < min(lhs.upperBound, rhs.upperBound)
    }
}

package enum SwiftSyntaxOverlayTokenProvider {
    private static func tokensInCommentLines(
        source: NSString,
        existingTokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        let fullRange = NSRange(location: 0, length: source.length)
        let searchRange = targetRange.map {
            SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: source.length)
        } ?? fullRange
        guard searchRange.length > 0 else {
            return []
        }

        let commentRanges = commentTokenRanges(
            overlapping: searchRange,
            existingTokens: existingTokens
        )
        guard !commentRanges.isEmpty else {
            return []
        }

        let sourceString = source as String
        var tokens: [SyntaxEditorHighlighting.Token] = []
        var commentRangeIndex = 0
        var location = searchRange.location
        while location < searchRange.upperBound {
            let remainingRange = NSRange(location: location, length: searchRange.upperBound - location)
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let clampedLineRange = NSIntersectionRange(lineRange, remainingRange)
            guard clampedLineRange.length > 0 else { break }

            while commentRangeIndex < commentRanges.count,
                  commentRanges[commentRangeIndex].upperBound <= clampedLineRange.location {
                commentRangeIndex += 1
            }

            guard commentRangeIndex < commentRanges.count,
                  rangesIntersect(commentRanges[commentRangeIndex], clampedLineRange)
            else {
                location = clampedLineRange.upperBound
                continue
            }

            let line = source.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("// MARK:"),
               let markRange = substringRange("MARK:", in: source, lineRange: clampedLineRange) {
                tokens.append(canonicalToken(range: markTokenRange(from: markRange, in: source), syntaxID: .mark))
            }

            tokens.append(contentsOf: urlTokens(in: sourceString, lineRange: clampedLineRange))
            location = clampedLineRange.upperBound
        }

        return tokens
    }

    private static func tokensInPreprocessorLines(
        source: NSString,
        excludedRanges: [NSRange],
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        let fullRange = NSRange(location: 0, length: source.length)
        let searchRange = targetRange.map {
            SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: source.length)
        } ?? fullRange
        guard searchRange.length > 0 else {
            return []
        }

        let sourceString = source as String
        var tokens: [SyntaxEditorHighlighting.Token] = []
        var location = searchRange.location
        while location < searchRange.upperBound {
            let remainingRange = NSRange(location: location, length: searchRange.upperBound - location)
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let clampedLineRange = NSIntersectionRange(lineRange, remainingRange)
            guard clampedLineRange.length > 0 else { break }

            let line = source.substring(with: clampedLineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#if")
                || trimmed.hasPrefix("#elseif")
                || trimmed.hasPrefix("#else")
                || trimmed.hasPrefix("#endif")
                || trimmed.hasPrefix("#sourceLocation")
            else {
                location = clampedLineRange.upperBound
                continue
            }

            for match in preprocessorRegex.matches(in: sourceString, range: clampedLineRange) {
                let range = match.range
                guard !rangeIntersectsMergedRanges(range, excludedRanges) else {
                    continue
                }
                appendPreprocessorTokens(for: range, in: source, to: &tokens)
            }
            location = clampedLineRange.upperBound
        }

        return tokens
    }

    private static func tokensInSemanticSymbolRanges(
        source: NSString,
        tokenIndex: SwiftTokenIndex,
        index: SwiftScopeIndex,
        targetRange: NSRange?
    ) -> [SyntaxEditorHighlighting.Token] {
        guard source.length > 0 else {
            return []
        }

        var tokens: [SyntaxEditorHighlighting.Token] = []
        let resolution = index.makeResolutionContext()

        for token in tokenIndex.semanticTokens(intersecting: targetRange) {
            guard !isPreprocessorLine(containing: token.range, in: source)
            else {
                continue
            }

            let overlays = semanticOverlays(
                    for: token.text,
                    range: token.range,
                    in: source,
                    index: index,
                    resolution: resolution
            )
            guard !overlays.isEmpty else {
                continue
            }
            tokens.append(contentsOf: overlays.map {
                canonicalToken(range: $0.range, syntaxID: $0.syntaxID)
            })
        }

        return tokens
    }

    private struct SemanticOverlay {
        let range: NSRange
        let syntaxID: EditorSourceSyntax.ID
    }

    private static func semanticOverlays(
        for text: String,
        range: NSRange,
        in source: NSString,
        index: SwiftScopeIndex,
        resolution: SwiftScopeIndex.ResolutionContext
    ) -> [SemanticOverlay] {
        let context = SwiftSemanticTokenContext(source: source, range: range, text: text)

        if let sigilRange = context.attributeSigilRange {
            if index.entry(
                named: text,
                at: range,
                allowedKinds: [.macro, .type]
            , context: resolution) != nil {
                return []
            }

            if knownExternalAttributeFunctionNames.contains(text) {
                return [
                    SemanticOverlay(range: sigilRange, syntaxID: .identifierFunctionSystem),
                    SemanticOverlay(range: range, syntaxID: .identifierFunctionSystem),
                ]
            }
            if knownExternalAttributeClassNames.contains(text) {
                return [
                    SemanticOverlay(range: sigilRange, syntaxID: .identifierClassSystem),
                    SemanticOverlay(range: range, syntaxID: .identifierClassSystem),
                ]
            }

            return []
        }

        if let sigilRange = context.macroInvocationSigilRange,
           let localMacro = index.entry(
            named: text,
            at: range,
            allowedKinds: [.macro]
           , context: resolution) {
            return syntaxIDForLocalEntry(localMacro).map {
                [
                    SemanticOverlay(range: sigilRange, syntaxID: $0),
                    SemanticOverlay(range: range, syntaxID: $0),
                ]
            } ?? []
        }

        if context.macroInvocationSigilRange != nil {
            return []
        }

        guard !context.isImportLine,
              !context.isLabel,
              !context.isDeclarationContext,
              !context.isGenericParameterDeclarationContext,
              !context.isPatternBindingDeclarationContext,
              !context.isAttributeArgumentContext
        else {
            return []
        }

        if context.isMemberAccess {
            if let receiverName = context.memberReceiverName,
               let receiverType = index.declaredTypeName(forValueNamed: receiverName, at: range, context: resolution),
               knownExternalMemberVariablesByReceiverType[receiverType]?.contains(text) == true {
                return [SemanticOverlay(range: range, syntaxID: .identifierVariableSystem)]
            }

            if let localMember = index.entry(
                named: text,
                at: range,
                allowedKinds: [.function, .type, .variable],
                allowedRoles: .member
            , context: resolution) {
                if localMember.kind == .type {
                    return syntaxIDForLocalEntry(localMember).map {
                        [SemanticOverlay(range: range, syntaxID: $0)]
                    } ?? []
                }

                if localMember.kind == .variable, text == "range" {
                    return [SemanticOverlay(range: range, syntaxID: .identifierConstantSystem)]
                }

                let syntaxID: EditorSourceSyntax.ID = localMember.kind == .function
                    ? .identifierFunctionSystem
                    : .identifierVariableSystem
                return [SemanticOverlay(range: range, syntaxID: syntaxID)]
            }

            if let enumCase = index.enumCaseEntry(
                named: text,
                at: range,
                receiverTypeName: context.memberReceiverTypeName
            ) {
                return syntaxIDForLocalEntry(enumCase).map {
                    [SemanticOverlay(range: range, syntaxID: $0)]
                } ?? []
            }

            if context.isOptionalMemberAccess {
                return []
            }
            if let receiverName = context.memberReceiverName,
               index.entry(
                named: receiverName,
                at: range,
                allowedKinds: [.variable],
                allowedRoles: .local
               , context: resolution) != nil {
                return []
            }

            if context.startsLikeTypeName {
                return [SemanticOverlay(range: range, syntaxID: .identifierTypeSystem)]
            }
            if context.isFunctionCall || context.isTrailingClosureCall {
                return [SemanticOverlay(range: range, syntaxID: .identifierFunctionSystem)]
            }
            return [SemanticOverlay(range: range, syntaxID: .identifierVariableSystem)]
        }

        let localValueEntry = index.entry(
            named: text,
            at: range,
            allowedKinds: [.variable],
            allowedRoles: .local
        , context: resolution)
        let isTypeContext = context.isTypeContext

        if localValueEntry != nil, !isTypeContext {
            return []
        }

        if context.isAssignmentExpressionContext,
           let projectVariable = index.entry(
            named: text,
            at: range,
            allowedKinds: [.variable],
            allowedRoles: [.file, .member]
           , context: resolution) {
            return syntaxIDForLocalEntry(projectVariable).map {
                [SemanticOverlay(range: range, syntaxID: $0)]
            } ?? []
        }

        if context.isCallArgumentValueContext,
           let projectVariable = index.entry(
            named: text,
            at: range,
            allowedKinds: [.variable],
            allowedRoles: [.file, .member]
           , context: resolution) {
            return syntaxIDForLocalEntry(projectVariable).map {
                [SemanticOverlay(range: range, syntaxID: $0)]
            } ?? []
        }

        if isTypeContext {
            if localValueEntry != nil,
               context.isAssignmentExpressionContext || context.isCallArgumentValueContext {
                return []
            }

            if index.isGenericParameter(named: text, at: range, context: resolution) {
                return []
            }

            if let localType = index.entry(
                named: text,
                at: range,
                allowedKinds: [.type]
            , context: resolution) {
                return syntaxIDForLocalEntry(localType).map {
                    [SemanticOverlay(range: range, syntaxID: $0)]
                } ?? []
            }

            if context.isFunctionCall,
               let localFunction = index.entry(
                named: text,
                at: range,
                allowedKinds: [.function]
               , context: resolution) {
                return syntaxIDForLocalEntry(localFunction).map {
                    [SemanticOverlay(range: range, syntaxID: $0)]
                } ?? []
            }

            if let syntaxID = syntaxIDForKnownExternalType(named: text) {
                return [SemanticOverlay(range: range, syntaxID: syntaxID)]
            }

            return context.startsLikeTypeName
                ? [SemanticOverlay(range: range, syntaxID: .identifierTypeSystem)]
                : []
        }

        if context.isInsideStringInterpolation,
           index.entry(
            named: text,
            at: range,
            allowedKinds: [.variable],
            allowedRoles: .member
           , context: resolution) != nil {
            return [SemanticOverlay(range: range, syntaxID: .identifierVariableSystem)]
        }

        if context.isInsideStringInterpolation {
            return []
        }

        if let local = index.entry(
            named: text,
            at: range,
            allowedKinds: [.variable],
            allowedRoles: [.file, .member]
        , context: resolution) {
            return syntaxIDForLocalEntry(local).map {
                [SemanticOverlay(range: range, syntaxID: $0)]
            } ?? []
        }

        if context.isFunctionCall {
            if knownExternalFunctionNames.contains(text) {
                return [SemanticOverlay(range: range, syntaxID: .identifierFunctionSystem)]
            }

            guard let localFunction = index.entry(
                named: text,
                at: range,
                allowedKinds: [.function]
            , context: resolution) else {
                return [SemanticOverlay(range: range, syntaxID: .identifierFunctionSystem)]
            }
            if localFunction.role == .member {
                return [SemanticOverlay(range: range, syntaxID: .identifierFunctionSystem)]
            }
            return syntaxIDForLocalEntry(localFunction).map {
                [SemanticOverlay(range: range, syntaxID: $0)]
            } ?? []
        }

        return []
    }

    private static func syntaxIDForKnownExternalType(named name: String) -> EditorSourceSyntax.ID? {
        if knownExternalClassNames.contains(name) {
            return .identifierClassSystem
        }
        if knownExternalTypeNames.contains(name) {
            return .identifierTypeSystem
        }
        return nil
    }

    private static func syntaxIDForLocalEntry(_ entry: SwiftScopeIndex.Resolution?) -> EditorSourceSyntax.ID? {
        guard let entry else {
            return nil
        }
        switch entry.kind {
        case .type:
            return .identifierType
        case .function:
            return .identifierFunction
        case .variable:
            return .identifierVariable
        case .constant:
            return .identifierConstant
        case .macro:
            return .identifierMacro
        }
    }

    private static func canonicalToken(
        range: NSRange,
        syntaxID: EditorSourceSyntax.ID
    ) -> SyntaxEditorHighlighting.Token {
        SyntaxEditorHighlighting.Token(
            range: range,
            syntaxID: syntaxID,
            language: .swift,
            rawCaptureName: EditorSourceSyntax.Capture.rawCaptureName(syntaxID: syntaxID, language: .swift),
            isSemanticOverlay: true
        )
    }

    private static func commentTokenRanges(
        overlapping targetRange: NSRange,
        existingTokens: [SyntaxEditorHighlighting.Token]
    ) -> [NSRange] {
        let ranges = existingTokens.compactMap { token -> NSRange? in
            guard token.language == .swift || token.language == nil,
                  token.syntaxID.rawValue == "comment" || token.syntaxID.rawValue.hasPrefix("comment.")
            else {
                return nil
            }

            let range = SyntaxEditorRangeUtilities.intersection(of: token.range, and: targetRange)
            return range.length > 0 ? range : nil
        }
        .sorted { lhs, rhs in
            if lhs.location != rhs.location {
                return lhs.location < rhs.location
            }
            return lhs.length < rhs.length
        }

        return mergedRanges(ranges)
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard var current = ranges.first else {
            return []
        }

        var merged: [NSRange] = []
        merged.reserveCapacity(ranges.count)
        for range in ranges.dropFirst() {
            guard range.location <= current.upperBound else {
                merged.append(current)
                current = range
                continue
            }

            let upperBound = max(current.upperBound, range.upperBound)
            current = NSRange(location: current.location, length: upperBound - current.location)
        }
        merged.append(current)
        return merged
    }

    private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        max(lhs.location, rhs.location) < min(lhs.upperBound, rhs.upperBound)
    }

    private static func deduplicated(_ tokens: [SyntaxEditorHighlighting.Token]) -> [SyntaxEditorHighlighting.Token] {
        var seen = Set<SyntaxOverlayTokenKey>()
        var unique: [SyntaxEditorHighlighting.Token] = []
        unique.reserveCapacity(tokens.count)

        for token in tokens {
            let key = SyntaxOverlayTokenKey(token)
            guard seen.insert(key).inserted else { continue }
            unique.append(token)
        }

        return unique
    }

    private static func markTokenRange(from markerRange: NSRange, in source: NSString) -> NSRange {
        let lineRange = source.lineRange(for: markerRange)
        let rawRange = NSRange(
            location: markerRange.location,
            length: max(0, lineRange.upperBound - markerRange.location)
        )
        let rawText = source.substring(with: rawRange) as NSString
        let trimmedLength = rawText.trimmingCharacters(in: .newlines).utf16.count
        return NSRange(location: markerRange.location, length: trimmedLength)
    }

    private static func substringRange(
        _ substring: String,
        in source: NSString,
        lineRange: NSRange
    ) -> NSRange? {
        let range = source.range(of: substring, options: [], range: lineRange)
        return range.location == NSNotFound ? nil : range
    }

    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s\])>"]+"#)

    private static let preprocessorRegex = try! NSRegularExpression(
        pattern: #"#[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*|&&|\|\||==|!=|>=|<=|[!<>()(),:]"#
    )






    private static func urlTokens(in source: String, lineRange: NSRange) -> [SyntaxEditorHighlighting.Token] {
        urlRegex.matches(in: source, range: lineRange).map {
            canonicalToken(range: $0.range, syntaxID: .url)
        }
    }

    private static func mergedExcludedPreprocessorRanges(existingTokens: [SyntaxEditorHighlighting.Token]) -> [NSRange] {
        let ranges: [NSRange] = existingTokens.compactMap { token -> NSRange? in
            guard token.language == .swift || token.language == nil else {
                return nil
            }
            let value = token.syntaxID.rawValue
            guard value == "string" || value == "character" || value.hasPrefix("comment") else {
                return nil
            }
            return token.range
        }
        .sorted {
            if $0.location != $1.location {
                return $0.location < $1.location
            }
            return $0.length < $1.length
        }
        return mergedRanges(ranges)
    }

    private static func rangeIntersectsMergedRanges(_ range: NSRange, _ mergedRanges: [NSRange]) -> Bool {
        guard !mergedRanges.isEmpty else {
            return false
        }

        var lower = 0
        var upper = mergedRanges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if mergedRanges[middle].upperBound <= range.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        guard lower < mergedRanges.count else {
            return false
        }
        return mergedRanges[lower].location < range.upperBound
    }

    private static func appendPreprocessorTokens(
        for range: NSRange,
        in source: NSString,
        to tokens: inout [SyntaxEditorHighlighting.Token]
    ) {
        let text = source.nativeSubstring(with: range)
        if text == "#sourceLocation" {
            tokens.append(canonicalToken(range: NSRange(location: range.location, length: 1), syntaxID: .preprocessor))
            tokens.append(canonicalToken(range: NSRange(location: range.location + 1, length: range.length - 1), syntaxID: .preprocessor))
        } else if text.hasPrefix("_"), text.count > 1 {
            tokens.append(canonicalToken(range: NSRange(location: range.location, length: 1), syntaxID: .preprocessor))
            tokens.append(canonicalToken(range: NSRange(location: range.location + 1, length: range.length - 1), syntaxID: .preprocessor))
        } else {
            tokens.append(canonicalToken(range: range, syntaxID: .preprocessor))
        }
    }

    private static func isPreprocessorLine(containing range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0, range.location <= source.length else {
            return false
        }
        let lineRange = source.lineRange(for: NSRange(location: min(range.location, max(0, source.length - 1)), length: 0))
        // Equivalent to trimming .whitespacesAndNewlines and testing
        // hasPrefix("#"): only the first non-whitespace character decides, so
        // scan units directly instead of materializing the line per token.
        var index = lineRange.location
        while index < lineRange.upperBound {
            let unit = source.character(at: index)
            if unit == 0x23 { // '#'
                return true
            }
            if unit == 0x20 || (unit >= 0x09 && unit <= 0x0D) {
                index += 1
                continue
            }
            if unit > 0x7F,
               let scalar = Unicode.Scalar(unit),
               whitespaceAndNewlineSet.contains(scalar) {
                index += 1
                continue
            }
            return false
        }
        return false
    }

    private static let whitespaceAndNewlineSet = CharacterSet.whitespacesAndNewlines

    fileprivate static func isSwiftIdentifier(_ text: String) -> Bool {
        var iterator = text.utf8.makeIterator()
        guard let first = iterator.next(),
              isSwiftIdentifierStartByte(first)
        else {
            return false
        }

        while let byte = iterator.next() {
            guard isSwiftIdentifierContinueByte(byte) else {
                return false
            }
        }
        return true
    }

    private static func isSwiftIdentifierStartByte(_ byte: UInt8) -> Bool {
        byte == 95
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func isSwiftIdentifierContinueByte(_ byte: UInt8) -> Bool {
        isSwiftIdentifierStartByte(byte) || (byte >= 48 && byte <= 57)
    }

    private static let knownExternalTypeNames: Set<String> = [
        "AdditionPrecedence", "Bool", "ClosedRange", "Double", "Float", "Int", "StaticString", "String", "UInt", "UUID"
    ]

    private static let knownExternalClassNames: Set<String> = [
        "CaseIterable", "Comparable", "Hashable", "Identifiable", "MainActor", "Sendable", "Sequence"
    ]

    private static let knownExternalFunctionNames: Set<String> = [
        "max", "min"
    ]

    private static let knownExternalAttributeFunctionNames: Set<String> = [
        "Observable"
    ]

    private static let knownExternalAttributeClassNames: Set<String> = [
        "MainActor"
    ]

    private static let knownExternalMemberVariablesByReceiverType: [String: Set<String>] = [
        "ClosedRange": ["lowerBound", "upperBound"]
    ]
}

private struct SwiftSemanticTokenContext {
    let source: NSString
    let range: NSRange
    let text: String
    let line: NSString
    let before: String
    let after: String

    init(source: NSString, range: NSRange, text: String) {
        self.source = source
        self.range = range
        self.text = text

        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let line = source.substring(with: lineRange) as NSString
        let relativeLocation = max(0, range.location - lineRange.location)
        let afterLocation = min(line.length, relativeLocation + range.length)

        self.line = line
        self.before = line.nativeSubstring(
            with: NSRange(location: 0, length: min(relativeLocation, line.length))
        )
        self.after = line.nativeSubstring(
            with: NSRange(location: afterLocation, length: line.length - afterLocation)
        )
    }

    var startsLikeTypeName: Bool {
        text.first?.isUppercase == true
    }

    var isImportLine: Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("import ")
    }

    var isDeclarationContext: Bool {
        Self.declarationPrefixRegex.firstMatch(
            in: before,
            range: NSRange(location: 0, length: (before as NSString).length)
        ) != nil
    }

    var isGenericParameterDeclarationContext: Bool {
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        guard trimmedBefore.contains("<"),
              !trimmedBefore.hasSuffix(":"),
              !trimmedBefore.contains("=")
        else {
            return false
        }

        return Self.genericParameterDeclarationPrefixRegex.firstMatch(
            in: trimmedBefore,
            range: NSRange(location: 0, length: (trimmedBefore as NSString).length)
        ) != nil
    }

    var isPatternBindingDeclarationContext: Bool {
        Self.patternBindingDeclarationPrefixRegex.firstMatch(
            in: before,
            range: NSRange(location: 0, length: (before as NSString).length)
        ) != nil
            || Self.valuePatternDeclarationPrefixRegex.firstMatch(
                in: before,
                range: NSRange(location: 0, length: (before as NSString).length)
            ) != nil
    }

    var isLabel: Bool {
        after.trimmingCharacters(in: .whitespaces).hasPrefix(":")
            && previousNonWhitespace != "["
            && !isTernaryTrueOperand
    }

    var isCallArgumentValueContext: Bool {
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        guard trimmedBefore.hasSuffix(":"),
              !isTernaryTrueOperand
        else {
            return false
        }

        return nearestUnclosedDelimiter(in: String(trimmedBefore.dropLast())) == "("
    }

    var isTernaryTrueOperand: Bool {
        containsTernaryQuestionAtCurrentNesting
    }

    var attributeSigilRange: NSRange? {
        sigilRangeImmediatelyBeforeToken("@")
    }

    var macroInvocationSigilRange: NSRange? {
        sigilRangeImmediatelyBeforeToken("#")
    }

    var isMemberAccess: Bool {
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        return trimmedBefore.hasSuffix(".") && !trimmedBefore.hasSuffix("..")
    }

    var isOptionalMemberAccess: Bool {
        before.trimmingCharacters(in: .whitespaces).hasSuffix("?.")
    }

    var memberReceiverTypeName: String? {
        memberReceiverName
    }

    var memberReceiverName: String? {
        guard isMemberAccess else {
            return nil
        }

        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        guard trimmedBefore.hasSuffix(".") else {
            return nil
        }

        let receiverText = String(trimmedBefore.dropLast())
        guard let match = Self.memberReceiverRegex.matches(
            in: receiverText,
            range: NSRange(location: 0, length: (receiverText as NSString).length)
        ).last else {
            return nil
        }

        return (receiverText as NSString).nativeSubstring(with: match.range)
    }

    var isFunctionCall: Bool {
        after.trimmingCharacters(in: .whitespaces).hasPrefix("(")
    }

    var isAttributeArgumentContext: Bool {
        guard let atIndex = before.lastIndex(of: "@") else {
            return false
        }
        let suffix = before[atIndex...]
        return suffix.contains("(") && !suffix.contains(")")
    }

    var isTrailingClosureCall: Bool {
        after.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }

    var isTypeInheritanceClause: Bool {
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        return Self.typeInheritancePrefixRegex.firstMatch(
            in: trimmedBefore,
            range: NSRange(location: 0, length: (trimmedBefore as NSString).length)
        ) != nil
    }

    var isOperatorPrecedenceReference: Bool {
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        return Self.operatorPrecedencePrefixRegex.firstMatch(
            in: trimmedBefore,
            range: NSRange(location: 0, length: (trimmedBefore as NSString).length)
        ) != nil
    }

    var isAssignmentExpressionContext: Bool {
        before.trimmingCharacters(in: .whitespaces).hasSuffix("=")
            && Self.typeDeclarationAssignmentPrefixRegex.firstMatch(
                in: before,
                range: NSRange(location: 0, length: (before as NSString).length)
            ) == nil
    }

    private var containsTernaryQuestionAtCurrentNesting: Bool {
        let targetDepth = nestingDepth(in: Array(before))
        var depth = NestingDepth()
        let characters = Array(before)

        for index in characters.indices {
            let character = characters[index]
            if character == "?",
               depth == targetDepth,
               !isOptionalQuestion(at: index, in: characters)
            {
                return true
            }
            depth.apply(character)
        }

        return false
    }

    private func nestingDepth(in characters: [Character]) -> NestingDepth {
        var depth = NestingDepth()
        for character in characters {
            depth.apply(character)
        }
        return depth
    }

    private func isOptionalQuestion(at index: Int, in characters: [Character]) -> Bool {
        if characters.index(after: index) < characters.endIndex,
           characters[characters.index(after: index)] == "?"
        {
            return true
        }

        if nextNonWhitespaceCharacter(after: index, in: characters) == "." {
            return true
        }

        return previousIdentifier(before: index, in: characters) == "try"
    }

    private func nextNonWhitespaceCharacter(after index: Int, in characters: [Character]) -> Character? {
        var scan = characters.index(after: index)
        while scan < characters.endIndex {
            let character = characters[scan]
            if character != " " && character != "\t" {
                return character
            }
            scan = characters.index(after: scan)
        }
        return nil
    }

    private func nearestUnclosedDelimiter(in text: String) -> Character? {
        var stack: [Character] = []
        for character in text {
            switch character {
            case "(", "[", "{":
                stack.append(character)
            case ")":
                if stack.last == "(" { stack.removeLast() }
            case "]":
                if stack.last == "[" { stack.removeLast() }
            case "}":
                if stack.last == "{" { stack.removeLast() }
            default:
                break
            }
        }
        return stack.last
    }

    private func previousIdentifier(before index: Int, in characters: [Character]) -> String? {
        var scan = index
        var identifier = ""
        while scan > characters.startIndex {
            scan = characters.index(before: scan)
            let character = characters[scan]
            if character == " " || character == "\t" {
                if identifier.isEmpty {
                    continue
                }
                break
            }
            guard character.isLetter || character.isNumber || character == "_" else {
                break
            }
            identifier.insert(character, at: identifier.startIndex)
        }
        return identifier.isEmpty ? nil : identifier
    }

    var isTypeContext: Bool {
        if startsLikeTypeName && isFunctionCall {
            return true
        }

        if startsLikeTypeName && (isTypeInheritanceClause || isOperatorPrecedenceReference) {
            return true
        }

        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        if startsLikeTypeName,
           Self.opaqueExistentialTypePrefixRegex.firstMatch(
            in: trimmedBefore,
            range: NSRange(location: 0, length: (trimmedBefore as NSString).length)
           ) != nil {
            return true
        }

        if trimmedBefore.hasSuffix(":")
            || trimmedBefore.hasSuffix("=")
            || trimmedBefore.hasSuffix("->")
            || trimmedBefore.hasSuffix("<")
            || trimmedBefore.hasSuffix("[")
            || trimmedBefore.hasSuffix("(")
            || trimmedBefore.hasSuffix(",")
            || trimmedBefore.hasSuffix("&") {
            return startsLikeTypeName
        }

        if startsLikeTypeName,
           Self.castTypePrefixRegex.firstMatch(
            in: trimmedBefore,
            range: NSRange(location: 0, length: (trimmedBefore as NSString).length)
           ) != nil {
            return true
        }

        if startsLikeTypeName,
           isMemberAccess == false,
           after.trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            return true
        }

        return false
    }

    var isInsideStringInterpolation: Bool {
        guard let opener = before.range(of: "\\(", options: .backwards) else {
            return false
        }
        let suffix = before[opener.upperBound...]
        return suffix.contains(")") == false
    }

    private var previousNonWhitespace: Character? {
        before.reversed().first { !$0.isWhitespace }
    }

    private func sigilRangeImmediatelyBeforeToken(_ sigil: String) -> NSRange? {
        let sigilLength = (sigil as NSString).length
        guard sigilLength > 0,
              range.location >= sigilLength
        else {
            return nil
        }

        let sigilRange = NSRange(location: range.location - sigilLength, length: sigilLength)
        guard source.nativeSubstring(with: sigilRange) == sigil else {
            return nil
        }

        if sigilRange.location > 0 {
            let previousRange = NSRange(location: sigilRange.location - 1, length: 1)
            let previous = source.nativeSubstring(with: previousRange)
            guard previous.range(of: #"^[A-Za-z0-9_#@]$"#, options: .regularExpression) == nil else {
                return nil
            }
        }

        return sigilRange
    }

    private static let declarationPrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:let|var|func|macro|class|struct|enum|actor|protocol|typealias|associatedtype)\s+$"#
    )

    private static let genericParameterDeclarationPrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:class|struct|enum|actor|protocol|func)\s+[A-Za-z_][A-Za-z0-9_]*[^\n<]*<[^=\n{}()]*$"#
    )

    private static let typeDeclarationAssignmentPrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:typealias|associatedtype)\b"#
    )

    private static let patternBindingDeclarationPrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:for\s+(?:case\s+)?(?:let\s+|var\s+)?|case\s+(?:let\s+|var\s+)|case\s+(?:let|var)\b[^\n]*\(|case\b[^\n]*\(\s*(?:let|var)\s+|catch\s+(?:let\s+|var\s+)?)$"#
    )
    private static let valuePatternDeclarationPrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:let|var)\b[^=:\n]*$"#
    )

    private static let castTypePrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:as\?|as!|as|is)$"#
    )

    private static let opaqueExistentialTypePrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:some|any)$"#
    )

    private static let typeInheritancePrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:class|struct|enum|actor|protocol)\s+[A-Za-z_][A-Za-z0-9_]*(?:<[^=\n{}()]*>)?\s*:\s*[^=\n{}()]*$"#
    )

    private static let operatorPrecedencePrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:prefix|infix|postfix)\s+operator\b[^:\n]*:\s*$"#
    )

    private static let memberReceiverRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z_][A-Za-z0-9_]*$"#
    )
}

private struct NestingDepth: Equatable {
    var paren = 0
    var bracket = 0
    var brace = 0

    mutating func apply(_ character: Character) {
        switch character {
        case "(":
            paren += 1
        case ")":
            paren = max(0, paren - 1)
        case "[":
            bracket += 1
        case "]":
            bracket = max(0, bracket - 1)
        case "{":
            brace += 1
        case "}":
            brace = max(0, brace - 1)
        default:
            break
        }
    }
}

extension SwiftSyntaxOverlayTokenProvider {
    /// Target-scoped overlay generation: comment MARK/URL tokens, preprocessor
    /// tokens, and scope-resolved identifier overlays for `targetRange`. The
    /// classification rules are the color specification and are untouched; only
    /// their index moved to the tree-derived scope index.
    package static func overlayTokens(
        in targetRange: NSRange,
        baseTokens: [SyntaxEditorHighlighting.Token],
        source: String,
        index: SwiftScopeIndex?
    ) -> [SyntaxEditorHighlighting.Token] {
        let nsSource = source as NSString
        let clamped = SyntaxEditorRangeUtilities.clampedRange(targetRange, utf16Length: nsSource.length)
        guard clamped.length > 0 else { return [] }

        var overlays = tokensInCommentLines(
            source: nsSource,
            existingTokens: baseTokens,
            targetRange: clamped
        )
        overlays += tokensInPreprocessorLines(
            source: nsSource,
            excludedRanges: mergedExcludedPreprocessorRanges(existingTokens: baseTokens),
            targetRange: clamped
        )
        if let index {
            overlays += tokensInSemanticSymbolRanges(
                source: nsSource,
                tokenIndex: SwiftTokenIndex(tokens: baseTokens, source: nsSource, targetRange: clamped),
                index: index,
                targetRange: clamped
            )
        }
        return deduplicated(overlays.sorted(by: SyntaxHighlightTokenOrdering.displayOrder))
    }

    /// Full-document merge over base tokens. Compat surface for tests and the
    /// conservative engine path; cancellation returns the input unchanged with
    /// `isCancelled` set and leaves `state` untouched.
    package static func mergingOverlayResult(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node? = nil,
        state: inout SwiftSemanticOverlayState?
    ) -> SwiftSemanticOverlayResult {
        let nsSource = source as NSString
        let baseTokens = tokens.filter { !$0.isSemanticOverlay }
        guard nsSource.length > 0 else {
            state = nil
            return SwiftSemanticOverlayResult(tokens: baseTokens, refreshRangeOverride: nil, isCancelled: false)
        }
        guard !Task.isCancelled else {
            return SwiftSemanticOverlayResult(tokens: tokens, refreshRangeOverride: nil, isCancelled: true)
        }

        var index: SwiftScopeIndex?
        if let rootNode {
            guard let built = SwiftScopeIndex(rootNode: rootNode, source: nsSource) else {
                return SwiftSemanticOverlayResult(tokens: tokens, refreshRangeOverride: nil, isCancelled: true)
            }
            index = built
            state = SwiftSemanticOverlayState(scopeIndex: built, indexedSourceUTF16Length: nsSource.length)
        }

        let overlays = overlayTokens(
            in: NSRange(location: 0, length: nsSource.length),
            baseTokens: baseTokens,
            source: source,
            index: index
        )
        guard !Task.isCancelled else {
            return SwiftSemanticOverlayResult(tokens: tokens, refreshRangeOverride: nil, isCancelled: true)
        }
        return SwiftSemanticOverlayResult(
            tokens: deduplicated((baseTokens + overlays).sorted(by: SyntaxHighlightTokenOrdering.displayOrder)),
            refreshRangeOverride: nil,
            isCancelled: false
        )
    }
}
