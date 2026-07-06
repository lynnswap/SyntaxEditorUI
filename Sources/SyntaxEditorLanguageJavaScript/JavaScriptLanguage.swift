import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter
import TreeSitterJavaScript

package struct JavaScriptLanguage: SyntaxLanguageSupport {
    package init() {}

    package var language: SyntaxLanguage { .javascript }
    package var displayName: String { "JavaScript" }
    package var aliases: Set<String> { ["javascript", "js"] }
    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? {
        SyntaxLanguageTreeSitterSupport(
            name: "JavaScript",
            bundleName: "TreeSitterJavaScript_TreeSitterJavaScript",
            queryDirectories: Self.queryDirectories,
            makeLanguage: { unsafe Language(tree_sitter_javascript()) }
        )
    }

    package func toggleComment(source: String, selection: NSRange) -> SyntaxLanguage.EditResult? {
        SyntaxLanguageTextUtilities.toggleLineComment(
            source: source,
            selection: selection,
            commentPrefix: "//"
        )
    }

    package func isInsideLiteralOrComment(source: String, location: Int) -> Bool {
        let nsSource = source as NSString
        let clampedLocation = max(0, min(location, nsSource.length))
        var analysis = PrefixAnalysis()
        var cursor = 0
        PrefixAnalyzer.advance(
            &analysis,
            in: nsSource,
            cursor: &cursor,
            limit: clampedLocation,
            limitIsEndOfText: true
        )
        return analysis.isInsideLiteralOrComment
    }
}

private extension JavaScriptLanguage {
    static var queryDirectories: [URL] {
        BundledLanguageQueryResources.directories(in: .module, named: "JavaScriptQueries")
    }
}

extension JavaScriptLanguage {
    package struct PrefixAnalysis {
        var inSingleQuote = false
        var inDoubleQuote = false
        var templateExpressionDepthStack: [Int] = []
        var inLineComment = false
        var inBlockComment = false
        var inRegexLiteral = false
        var inRegexCharacterClass = false
        var regexCharacterClassHasContent = false
        var isEscaped = false

        package init() {}

        package var isInsideTemplateLiteralText: Bool {
            templateExpressionDepthStack.contains(0)
        }

        package var isInsideLiteralOrComment: Bool {
            inSingleQuote || inDoubleQuote || isInsideTemplateLiteralText || inLineComment || inBlockComment || inRegexLiteral
        }
    }

    package enum PrefixAnalyzer {
        /// `limitIsEndOfText` treats `limit` as the end of the analyzed text
        /// (no lookahead past it), matching what analyzing a prefix substring
        /// would see. Leave it `false` for streaming callers that keep
        /// advancing the same cursor with growing limits.
        package static func advance(
            _ analysis: inout PrefixAnalysis,
            in source: NSString,
            cursor: inout Int,
            limit: Int,
            limitIsEndOfText: Bool = false
        ) {
            let upperBound = max(0, min(limit, source.length))
            let lookaheadBound = limitIsEndOfText ? upperBound : source.length
            let singleQuote: unichar = 39
            let doubleQuote: unichar = 34
            let backtick: unichar = 96
            let backslash: unichar = 92
            let dollar: unichar = 36
            let slash: unichar = 47
            let asterisk: unichar = 42
            let openBrace: unichar = 123
            let closeBrace: unichar = 125
            let openBracket: unichar = 91
            let closeBracket: unichar = 93
            let newline: unichar = 10
            let carriageReturn: unichar = 13

            while cursor < upperBound {
                let codeUnit = source.character(at: cursor)
                let nextCodeUnit: unichar? = cursor + 1 < lookaheadBound ? source.character(at: cursor + 1) : nil

                if analysis.inLineComment {
                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inLineComment = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inBlockComment {
                    if codeUnit == asterisk, nextCodeUnit == slash {
                        analysis.inBlockComment = false
                        cursor += 2
                    } else {
                        cursor += 1
                    }
                    continue
                }

                if analysis.inRegexLiteral {
                    if analysis.isEscaped {
                        analysis.isEscaped = false
                        if analysis.inRegexCharacterClass {
                            analysis.regexCharacterClassHasContent = true
                        }
                        cursor += 1
                        continue
                    }
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                        cursor += 1
                        continue
                    }
                    if codeUnit == openBracket, !analysis.inRegexCharacterClass {
                        analysis.inRegexCharacterClass = true
                        analysis.regexCharacterClassHasContent = false
                        cursor += 1
                        continue
                    }
                    if codeUnit == closeBracket, analysis.inRegexCharacterClass {
                        if analysis.regexCharacterClassHasContent {
                            analysis.inRegexCharacterClass = false
                            analysis.regexCharacterClassHasContent = false
                        } else {
                            analysis.regexCharacterClassHasContent = true
                        }
                        cursor += 1
                        continue
                    }
                    if codeUnit == slash, !analysis.inRegexCharacterClass {
                        analysis.inRegexLiteral = false
                        cursor += 1
                        while cursor < lookaheadBound {
                            let flagUnit = source.character(at: cursor)
                            guard Self.isIdentifierPart(flagUnit) else { break }
                            cursor += 1
                        }
                        continue
                    }
                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inRegexLiteral = false
                        analysis.inRegexCharacterClass = false
                        analysis.regexCharacterClassHasContent = false
                    } else if analysis.inRegexCharacterClass {
                        analysis.regexCharacterClassHasContent = true
                    }
                    cursor += 1
                    continue
                }

                if analysis.isEscaped {
                    analysis.isEscaped = false
                    cursor += 1
                    continue
                }

                if analysis.inSingleQuote {
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                    } else if codeUnit == singleQuote {
                        analysis.inSingleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inDoubleQuote {
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                    } else if codeUnit == doubleQuote {
                        analysis.inDoubleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if var currentTemplateExpressionDepth = analysis.templateExpressionDepthStack.last {
                    if currentTemplateExpressionDepth == 0 {
                        if codeUnit == backslash {
                            analysis.isEscaped = true
                            cursor += 1
                            continue
                        }
                        if codeUnit == backtick {
                            analysis.templateExpressionDepthStack.removeLast()
                            cursor += 1
                            continue
                        }
                        if codeUnit == dollar, nextCodeUnit == openBrace {
                            currentTemplateExpressionDepth = 1
                            analysis.templateExpressionDepthStack[analysis.templateExpressionDepthStack.count - 1] =
                                currentTemplateExpressionDepth
                            cursor += 2
                            continue
                        }
                        cursor += 1
                        continue
                    }

                    if codeUnit == singleQuote {
                        analysis.inSingleQuote = true
                        cursor += 1
                        continue
                    }
                    if codeUnit == doubleQuote {
                        analysis.inDoubleQuote = true
                        cursor += 1
                        continue
                    }
                    if codeUnit == backtick {
                        analysis.templateExpressionDepthStack.append(0)
                        cursor += 1
                        continue
                    }
                    if codeUnit == slash {
                        if nextCodeUnit == slash {
                            analysis.inLineComment = true
                            cursor += 2
                            continue
                        }
                        if nextCodeUnit == asterisk {
                            analysis.inBlockComment = true
                            cursor += 2
                            continue
                        }
                        if Self.shouldStartRegexLiteral(in: source, at: cursor) {
                            analysis.inRegexLiteral = true
                            analysis.inRegexCharacterClass = false
                            analysis.regexCharacterClassHasContent = false
                            cursor += 1
                            continue
                        }
                    }
                    if codeUnit == openBrace {
                        currentTemplateExpressionDepth += 1
                        analysis.templateExpressionDepthStack[analysis.templateExpressionDepthStack.count - 1] =
                            currentTemplateExpressionDepth
                        cursor += 1
                        continue
                    }
                    if codeUnit == closeBrace {
                        currentTemplateExpressionDepth -= 1
                        analysis.templateExpressionDepthStack[analysis.templateExpressionDepthStack.count - 1] =
                            max(0, currentTemplateExpressionDepth)
                        cursor += 1
                        continue
                    }

                    cursor += 1
                    continue
                }

                if codeUnit == singleQuote {
                    analysis.inSingleQuote = true
                    cursor += 1
                    continue
                }
                if codeUnit == doubleQuote {
                    analysis.inDoubleQuote = true
                    cursor += 1
                    continue
                }
                if codeUnit == backtick {
                    analysis.templateExpressionDepthStack.append(0)
                    cursor += 1
                    continue
                }

                if codeUnit == slash {
                    if nextCodeUnit == slash {
                        analysis.inLineComment = true
                        cursor += 2
                        continue
                    }
                    if nextCodeUnit == asterisk {
                        analysis.inBlockComment = true
                        cursor += 2
                        continue
                    }
                    if Self.shouldStartRegexLiteral(in: source, at: cursor) {
                        analysis.inRegexLiteral = true
                        analysis.inRegexCharacterClass = false
                        analysis.regexCharacterClassHasContent = false
                        cursor += 1
                        continue
                    }
                }

                cursor += 1
            }
        }

        private static func shouldStartRegexLiteral(in source: NSString, at slashOffset: Int) -> Bool {
            guard slashOffset >= 0, slashOffset < source.length else { return false }
            guard let cursor = previousSignificantOffset(in: source, before: slashOffset) else { return true }
            let codeUnit = source.character(at: cursor)

            if let tokenInfo = identifierToken(in: source, endingAt: cursor) {
                let token = tokenInfo.text
                if [
                    "return", "throw", "case", "delete", "void", "typeof", "instanceof", "new", "in", "of", "await",
                    "yield", "else",
                ].contains(token) {
                    if let previousOffset = previousSignificantOffset(in: source, before: tokenInfo.range.location) {
                        let previousCodeUnit = source.character(at: previousOffset)
                        if previousCodeUnit == 46 || previousCodeUnit == 63 {
                            return false
                        }
                    }
                    return true
                }
                return false
            }

            if (48...57).contains(Int(codeUnit)) || codeUnit == 93 || codeUnit == 125 {
                return false
            }
            if codeUnit == 41 {
                return shouldTreatSlashAfterClosingParenAsRegex(in: source, closingParenOffset: cursor)
            }
            if codeUnit == 47 || codeUnit == 46 {
                return false
            }
            if codeUnit == 34 || codeUnit == 39 || codeUnit == 96 {
                return false
            }

            if [
                40, 91, 123, 44, 58, 59, 61, 33, 63, 43, 45, 42, 37, 38, 124, 94, 126, 60, 62,
            ].contains(Int(codeUnit)) {
                if (codeUnit == 43 || codeUnit == 45),
                   SyntaxLanguageTextUtilities.previousNonWhitespaceCodeUnit(in: source, before: cursor) == codeUnit
                {
                    return false
                }
                return true
            }

            return true
        }

        private static func shouldTreatSlashAfterClosingParenAsRegex(
            in source: NSString,
            closingParenOffset: Int
        ) -> Bool {
            guard closingParenOffset >= 0, closingParenOffset < source.length else { return false }
            guard source.character(at: closingParenOffset) == 41 else { return false }
            guard let openParenOffset = matchingOpenParenOffset(in: source, forClosingParenAt: closingParenOffset) else {
                return false
            }
            guard let tokenEnd = previousSignificantOffset(in: source, before: openParenOffset),
                  let tokenInfo = identifierToken(in: source, endingAt: tokenEnd)
            else {
                return false
            }
            if let previousOffset = previousSignificantOffset(in: source, before: tokenInfo.range.location) {
                let previousCodeUnit = source.character(at: previousOffset)
                if previousCodeUnit == 46 || previousCodeUnit == 63 {
                    return false
                }
            }
            return ["if", "while", "for", "with", "switch", "catch"].contains(tokenInfo.text)
        }

        private static func matchingOpenParenOffset(in source: NSString, forClosingParenAt closingParenOffset: Int) -> Int? {
            guard closingParenOffset >= 0, closingParenOffset < source.length else { return nil }
            guard source.character(at: closingParenOffset) == 41 else { return nil }

            let prefix = source.substring(with: NSRange(location: 0, length: closingParenOffset + 1))
            let nsText = prefix as NSString
            var analysis = PrefixAnalysis()
            var parenStack: [Int] = []
            var cursor = 0

            let singleQuote: unichar = 39
            let doubleQuote: unichar = 34
            let backtick: unichar = 96
            let backslash: unichar = 92
            let slash: unichar = 47
            let asterisk: unichar = 42
            let newline: unichar = 10
            let carriageReturn: unichar = 13
            let openBracket: unichar = 91
            let closeBracket: unichar = 93
            let openBrace: unichar = 123
            let closeBrace: unichar = 125
            let openParen: unichar = 40
            let closeParen: unichar = 41
            let dollar: unichar = 36

            while cursor < nsText.length {
                let codeUnit = nsText.character(at: cursor)
                let nextCodeUnit: unichar? = cursor + 1 < nsText.length ? nsText.character(at: cursor + 1) : nil

                if analysis.inLineComment {
                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inLineComment = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inBlockComment {
                    if codeUnit == asterisk, nextCodeUnit == slash {
                        analysis.inBlockComment = false
                        cursor += 2
                    } else {
                        cursor += 1
                    }
                    continue
                }

                if analysis.inRegexLiteral {
                    if analysis.isEscaped {
                        analysis.isEscaped = false
                        if analysis.inRegexCharacterClass {
                            analysis.regexCharacterClassHasContent = true
                        }
                        cursor += 1
                        continue
                    }
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                        cursor += 1
                        continue
                    }
                    if codeUnit == openBracket, !analysis.inRegexCharacterClass {
                        analysis.inRegexCharacterClass = true
                        analysis.regexCharacterClassHasContent = false
                        cursor += 1
                        continue
                    }
                    if codeUnit == closeBracket, analysis.inRegexCharacterClass {
                        if analysis.regexCharacterClassHasContent {
                            analysis.inRegexCharacterClass = false
                            analysis.regexCharacterClassHasContent = false
                        } else {
                            analysis.regexCharacterClassHasContent = true
                        }
                        cursor += 1
                        continue
                    }
                    if codeUnit == slash, !analysis.inRegexCharacterClass {
                        analysis.inRegexLiteral = false
                        cursor += 1
                        while cursor < nsText.length {
                            let flagUnit = nsText.character(at: cursor)
                            guard isIdentifierPart(flagUnit) else { break }
                            cursor += 1
                        }
                        continue
                    }
                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inRegexLiteral = false
                        analysis.inRegexCharacterClass = false
                        analysis.regexCharacterClassHasContent = false
                    } else if analysis.inRegexCharacterClass {
                        analysis.regexCharacterClassHasContent = true
                    }
                    cursor += 1
                    continue
                }

                if analysis.isEscaped {
                    analysis.isEscaped = false
                    cursor += 1
                    continue
                }

                if analysis.inSingleQuote {
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                    } else if codeUnit == singleQuote {
                        analysis.inSingleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inDoubleQuote {
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                    } else if codeUnit == doubleQuote {
                        analysis.inDoubleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if let templateDepth = analysis.templateExpressionDepthStack.last {
                    if templateDepth == 0 {
                        if codeUnit == backslash {
                            analysis.isEscaped = true
                            cursor += 1
                            continue
                        }
                        if codeUnit == backtick {
                            _ = analysis.templateExpressionDepthStack.popLast()
                            cursor += 1
                            continue
                        }
                        if codeUnit == dollar, nextCodeUnit == openBrace {
                            let newDepth = templateDepth + 1
                            _ = analysis.templateExpressionDepthStack.popLast()
                            analysis.templateExpressionDepthStack.append(newDepth)
                            cursor += 2
                            continue
                        }
                        cursor += 1
                        continue
                    }

                    if codeUnit == openBrace {
                        let newDepth = templateDepth + 1
                        _ = analysis.templateExpressionDepthStack.popLast()
                        analysis.templateExpressionDepthStack.append(newDepth)
                        cursor += 1
                        continue
                    }

                    if codeUnit == closeBrace, templateDepth > 0 {
                        let newDepth = templateDepth - 1
                        _ = analysis.templateExpressionDepthStack.popLast()
                        analysis.templateExpressionDepthStack.append(newDepth)
                        cursor += 1
                        continue
                    }

                    if codeUnit == singleQuote {
                        analysis.inSingleQuote = true
                        cursor += 1
                        continue
                    }
                    if codeUnit == doubleQuote {
                        analysis.inDoubleQuote = true
                        cursor += 1
                        continue
                    }
                    if codeUnit == backtick {
                        analysis.templateExpressionDepthStack.append(0)
                        cursor += 1
                        continue
                    }

                    if codeUnit == slash {
                        if nextCodeUnit == slash {
                            analysis.inLineComment = true
                            cursor += 2
                            continue
                        }
                        if nextCodeUnit == asterisk {
                            analysis.inBlockComment = true
                            cursor += 2
                            continue
                        }
                        if shouldStartRegexLiteral(in: nsText, at: cursor) {
                            analysis.inRegexLiteral = true
                            analysis.inRegexCharacterClass = false
                            analysis.regexCharacterClassHasContent = false
                            cursor += 1
                            continue
                        }
                    }

                    if codeUnit == openParen {
                        parenStack.append(cursor)
                        cursor += 1
                        continue
                    }
                    if codeUnit == closeParen {
                        guard let matchedOpen = parenStack.popLast() else {
                            return nil
                        }
                        if cursor == closingParenOffset {
                            return matchedOpen
                        }
                        cursor += 1
                        continue
                    }

                    cursor += 1
                    continue
                }

                if codeUnit == singleQuote {
                    analysis.inSingleQuote = true
                    cursor += 1
                    continue
                }
                if codeUnit == doubleQuote {
                    analysis.inDoubleQuote = true
                    cursor += 1
                    continue
                }
                if codeUnit == backtick {
                    analysis.templateExpressionDepthStack.append(0)
                    cursor += 1
                    continue
                }

                if codeUnit == slash {
                    if nextCodeUnit == slash {
                        analysis.inLineComment = true
                        cursor += 2
                        continue
                    }
                    if nextCodeUnit == asterisk {
                        analysis.inBlockComment = true
                        cursor += 2
                        continue
                    }
                    if shouldStartRegexLiteral(in: nsText, at: cursor) {
                        analysis.inRegexLiteral = true
                        analysis.inRegexCharacterClass = false
                        analysis.regexCharacterClassHasContent = false
                        cursor += 1
                        continue
                    }
                }

                if codeUnit == openParen {
                    parenStack.append(cursor)
                    cursor += 1
                    continue
                }
                if codeUnit == closeParen {
                    guard let matchedOpen = parenStack.popLast() else {
                        return nil
                    }
                    if cursor == closingParenOffset {
                        return matchedOpen
                    }
                    cursor += 1
                    continue
                }

                cursor += 1
            }

            return nil
        }

        private static func identifierToken(
            in source: NSString,
            endingAt offset: Int
        ) -> (range: NSRange, text: String)? {
            guard offset >= 0, offset < source.length else { return nil }
            let endRange = source.rangeOfComposedCharacterSequence(at: offset)
            guard isIdentifierPart(in: source, range: endRange) else { return nil }

            var start = endRange.location
            let end = endRange.location + endRange.length
            while start > 0 {
                let previousRange = source.rangeOfComposedCharacterSequence(at: start - 1)
                guard isIdentifierPart(in: source, range: previousRange) else { break }
                start = previousRange.location
            }

            let range = NSRange(location: start, length: end - start)
            return (range: range, text: source.substring(with: range))
        }

        private static func isIdentifierPart(in source: NSString, range: NSRange) -> Bool {
            guard range.location != NSNotFound, range.length > 0 else { return false }
            let fragment = source.substring(with: range)
            for scalar in fragment.unicodeScalars {
                if scalar.value == 95 || scalar.value == 36 {
                    continue
                }
                if CharacterSet.decimalDigits.contains(scalar) {
                    continue
                }
                if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                    continue
                }
                return false
            }
            return true
        }

        private static func isIdentifierPart(_ codeUnit: unichar) -> Bool {
            if codeUnit == 95 || codeUnit == 36 {
                return true
            }
            if (48...57).contains(Int(codeUnit)) {
                return true
            }
            guard let scalar = UnicodeScalar(codeUnit) else { return false }
            return CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
        }

        private static func previousSignificantOffset(in source: NSString, before location: Int) -> Int? {
            var cursor = location - 1
            while cursor >= 0 {
                let codeUnit = source.character(at: cursor)
                if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                    cursor -= 1
                    continue
                }

                if codeUnit == 47, cursor - 1 >= 0, source.character(at: cursor - 1) == 42 {
                    cursor -= 2
                    var foundOpen = false
                    while cursor >= 1 {
                        if source.character(at: cursor - 1) == 47, source.character(at: cursor) == 42 {
                            cursor -= 2
                            foundOpen = true
                            break
                        }
                        cursor -= 1
                    }
                    if !foundOpen {
                        return nil
                    }
                    continue
                }

                if let commentStart = lineCommentStartOffset(in: source, atOrBefore: cursor) {
                    cursor = commentStart - 1
                    continue
                }

                return cursor
            }
            return nil
        }

        private static func lineCommentStartOffset(in source: NSString, atOrBefore location: Int) -> Int? {
            guard location >= 0, location < source.length else { return nil }
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var cursor = lineRange.location
            var isEscaped = false
            var inSingleQuote = false
            var inDoubleQuote = false
            var inBacktick = false

            while cursor <= location {
                let codeUnit = source.character(at: cursor)
                let nextCodeUnit: unichar? = cursor + 1 < lineRange.location + lineRange.length
                    ? source.character(at: cursor + 1)
                    : nil

                if isEscaped {
                    isEscaped = false
                    cursor += 1
                    continue
                }

                if inSingleQuote {
                    if codeUnit == 92 {
                        isEscaped = true
                    } else if codeUnit == 39 {
                        inSingleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if inDoubleQuote {
                    if codeUnit == 92 {
                        isEscaped = true
                    } else if codeUnit == 34 {
                        inDoubleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if inBacktick {
                    if codeUnit == 92 {
                        isEscaped = true
                    } else if codeUnit == 96 {
                        inBacktick = false
                    }
                    cursor += 1
                    continue
                }

                if codeUnit == 39 {
                    inSingleQuote = true
                    cursor += 1
                    continue
                }
                if codeUnit == 34 {
                    inDoubleQuote = true
                    cursor += 1
                    continue
                }
                if codeUnit == 96 {
                    inBacktick = true
                    cursor += 1
                    continue
                }

                if codeUnit == 47, nextCodeUnit == 47 {
                    return cursor
                }

                cursor += 1
            }

            return nil
        }
    }
}
