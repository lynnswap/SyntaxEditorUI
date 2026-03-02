import Foundation

struct EditorCommandResult {
    let text: String
    let selectedRange: NSRange
    let refreshStartUTF16: Int
}

struct EditorCommandEngine {
    private let indentUnit = "    "

    enum DeletionIntent {
        case unspecified
        case backward
    }

    func transformInput(
        source: String,
        range: NSRange,
        replacementText: String,
        language: SyntaxLanguage,
        deletionIntent: DeletionIntent = .unspecified
    ) -> EditorCommandResult? {
        let nsSource = source as NSString
        let safeRange = Self.clampedRange(range, utf16Length: nsSource.length)

        if replacementText == "\n" {
            return smartNewline(source: source, range: safeRange)
        }

        if deletionIntent == .backward, replacementText.isEmpty, safeRange.length == 1 {
            if let result = pairAwareBackspace(source: source, range: safeRange) {
                return result
            }
        }

        if replacementText.utf16.count == 1, let input = replacementText.first {
            if let result = autoPair(
                source: source,
                range: safeRange,
                input: input,
                language: language
            ) {
                return result
            }
        }

        return nil
    }

    func indentSelection(source: String, selection: NSRange) -> EditorCommandResult? {
        let nsSource = source as NSString
        let safeSelection = Self.clampedRange(selection, utf16Length: nsSource.length)
        let lineStarts = lineStartOffsets(in: nsSource, selection: safeSelection)
        guard !lineStarts.isEmpty else { return nil }

        let edits = lineStarts.map {
            TextEdit(range: NSRange(location: $0, length: 0), replacement: indentUnit)
        }

        return applyEdits(
            edits,
            source: source,
            selection: safeSelection,
            refreshStartUTF16: lineStarts[0]
        )
    }

    func outdentSelection(source: String, selection: NSRange) -> EditorCommandResult? {
        let nsSource = source as NSString
        let safeSelection = Self.clampedRange(selection, utf16Length: nsSource.length)
        let lineStarts = lineStartOffsets(in: nsSource, selection: safeSelection)
        guard !lineStarts.isEmpty else { return nil }

        var edits: [TextEdit] = []
        edits.reserveCapacity(lineStarts.count)

        for lineStart in lineStarts {
            let lineRange = nsSource.lineRange(for: NSRange(location: lineStart, length: 0))
            let removable = removableIndentLength(in: nsSource, lineRange: lineRange)
            guard removable > 0 else { continue }
            edits.append(TextEdit(range: NSRange(location: lineStart, length: removable), replacement: ""))
        }

        guard !edits.isEmpty else { return nil }
        return applyEdits(
            edits,
            source: source,
            selection: safeSelection,
            refreshStartUTF16: lineStarts[0]
        )
    }

    func toggleComment(
        source: String,
        selection: NSRange,
        language: SyntaxLanguage
    ) -> EditorCommandResult? {
        switch language {
        case .javascript:
            return toggleJavaScriptLineComment(source: source, selection: selection)
        case .css:
            return toggleCSSBlockComment(source: source, selection: selection)
        case .json:
            return nil
        }
    }
}

private extension EditorCommandEngine {
    struct TextEdit {
        let range: NSRange
        let replacement: String
    }

    enum SelectionBoundaryAffinity {
        case forward
        case backward
    }

    struct LineInfo {
        let lineRange: NSRange
        let contentRange: NSRange
        let firstNonWhitespaceOffset: Int?
        let isBlank: Bool
        let hasLineComment: Bool
    }

    func autoPair(
        source: String,
        range: NSRange,
        input: Character,
        language: SyntaxLanguage
    ) -> EditorCommandResult? {
        let nsSource = source as NSString
        let openingPairs: [Character: Character] = [
            "(": ")",
            "[": "]",
            "{": "}",
            "\"": "\"",
            "'": "'",
            "`": "`",
        ]
        let closingPairs: [Character: Character] = [
            ")": "(",
            "]": "[",
            "}": "{",
            "\"": "\"",
            "'": "'",
            "`": "`",
        ]

        if isQuote(input),
           range.length == 0,
           let next = character(in: nsSource, at: range.location),
           next == input
        {
            return EditorCommandResult(
                text: source,
                selectedRange: NSRange(location: range.location + 1, length: 0),
                refreshStartUTF16: lineStartUTF16Offset(in: source, around: range.location)
            )
        }

        if let open = openingPairs[input] {
            if isQuote(input) &&
                isLikelyInsideLiteralOrComment(
                    source: nsSource,
                    location: range.location,
                    language: language
                )
            {
                return nil
            }

            if range.length > 0 {
                let selected = nsSource.substring(with: range)
                let wrapped = String(input) + selected + String(open)
                let updated = nsSource.replacingCharacters(in: range, with: wrapped)
                let cursor = range.location + wrapped.utf16.count
                return EditorCommandResult(
                    text: updated,
                    selectedRange: NSRange(location: cursor, length: 0),
                    refreshStartUTF16: lineStartUTF16Offset(in: source, around: range.location)
                )
            }

            let inserted = String(input) + String(open)
            let updated = nsSource.replacingCharacters(in: range, with: inserted)
            return EditorCommandResult(
                text: updated,
                selectedRange: NSRange(location: range.location + 1, length: 0),
                refreshStartUTF16: lineStartUTF16Offset(in: source, around: range.location)
            )
        }

        if let pairOpen = closingPairs[input], range.length == 0 {
            if let next = character(in: nsSource, at: range.location), next == input {
                return EditorCommandResult(
                    text: source,
                    selectedRange: NSRange(location: range.location + 1, length: 0),
                    refreshStartUTF16: lineStartUTF16Offset(in: source, around: range.location)
                )
            }

            if input == "}" {
                if let nextNonWhitespace = nextNonWhitespaceOffset(in: nsSource, from: range.location),
                   character(in: nsSource, at: nextNonWhitespace) == input
                {
                    return EditorCommandResult(
                        text: source,
                        selectedRange: NSRange(location: nextNonWhitespace + 1, length: 0),
                        refreshStartUTF16: lineStartUTF16Offset(in: source, around: range.location)
                    )
                }

                if let result = outdentForClosingBrace(
                    source: source,
                    location: range.location,
                    expectedPairOpen: pairOpen
                ) {
                    return result
                }
            }
        }

        return nil
    }

    func pairAwareBackspace(source: String, range: NSRange) -> EditorCommandResult? {
        let nsSource = source as NSString
        guard range.length == 1 else { return nil }
        let deleteOffset = range.location
        let afterOffset = range.location + range.length
        guard let deleted = character(in: nsSource, at: deleteOffset),
              let after = character(in: nsSource, at: afterOffset)
        else {
            return nil
        }

        let pairs: [Character: Character] = [
            "(": ")",
            "[": "]",
            "{": "}",
            "\"": "\"",
            "'": "'",
            "`": "`",
        ]
        guard pairs[deleted] == after else { return nil }

        let removeRange = NSRange(location: deleteOffset, length: 2)
        let updated = nsSource.replacingCharacters(in: removeRange, with: "")
        return EditorCommandResult(
            text: updated,
            selectedRange: NSRange(location: deleteOffset, length: 0),
            refreshStartUTF16: lineStartUTF16Offset(in: source, around: deleteOffset)
        )
    }

    func smartNewline(source: String, range: NSRange) -> EditorCommandResult? {
        guard range.length == 0 else { return nil }
        let nsSource = source as NSString

        let lineRange = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
        let lineIndent = leadingIndent(in: nsSource, lineRange: lineRange)

        let previous = previousNonWhitespaceCharacter(in: nsSource, before: range.location)
        let next = character(in: nsSource, at: range.location)
        let openToClose: [Character: Character] = [
            "{": "}",
            "[": "]",
            "(": ")",
        ]

        let insertion: String
        let cursorOffset: Int

        if let previous, let pairClose = openToClose[previous], next == pairClose {
            insertion = "\n" + lineIndent + indentUnit + "\n" + lineIndent
            cursorOffset = ("\n" + lineIndent + indentUnit).utf16.count
        } else if let previous, openToClose[previous] != nil {
            insertion = "\n" + lineIndent + indentUnit
            cursorOffset = insertion.utf16.count
        } else {
            insertion = "\n" + lineIndent
            cursorOffset = insertion.utf16.count
        }

        let updated = nsSource.replacingCharacters(in: range, with: insertion)
        return EditorCommandResult(
            text: updated,
            selectedRange: NSRange(location: range.location + cursorOffset, length: 0),
            refreshStartUTF16: lineStartUTF16Offset(in: source, around: range.location)
        )
    }

    func outdentForClosingBrace(
        source: String,
        location: Int,
        expectedPairOpen: Character
    ) -> EditorCommandResult? {
        let nsSource = source as NSString
        let lineRange = nsSource.lineRange(for: NSRange(location: location, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: max(0, location - lineRange.location))
        let prefix = nsSource.substring(with: prefixRange)

        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        guard !prefix.isEmpty else { return nil }

        let removable = trailingIndentRemovalLength(prefix)
        guard removable > 0 else { return nil }

        let reducedPrefixLength = max(0, prefix.utf16.count - removable)
        let reducedPrefix = String(prefix.prefix(reducedPrefixLength))
        let replacement = reducedPrefix + String(closingCharacter(for: expectedPairOpen))
        let updated = nsSource.replacingCharacters(in: prefixRange, with: replacement)
        let cursor = lineRange.location + replacement.utf16.count

        return EditorCommandResult(
            text: updated,
            selectedRange: NSRange(location: cursor, length: 0),
            refreshStartUTF16: lineRange.location
        )
    }

    func toggleJavaScriptLineComment(source: String, selection: NSRange) -> EditorCommandResult? {
        let nsSource = source as NSString
        let safeSelection = Self.clampedRange(selection, utf16Length: nsSource.length)
        let lineRanges = selectedLineRanges(in: nsSource, selection: safeSelection)
        guard !lineRanges.isEmpty else { return nil }

        let lines = lineRanges.map { lineInfo(in: nsSource, lineRange: $0) }
        let actionable = lines.filter { !$0.isBlank }
        guard !actionable.isEmpty else { return nil }

        let shouldUncomment = actionable.allSatisfy(\.hasLineComment)
        var edits: [TextEdit] = []

        for line in actionable {
            guard let firstNonWhitespaceOffset = line.firstNonWhitespaceOffset else { continue }
            if shouldUncomment {
                let afterSlashOffset = firstNonWhitespaceOffset + 2
                var removeLength = 2
                if let next = character(in: nsSource, at: afterSlashOffset), next == " " {
                    removeLength += 1
                }
                edits.append(
                    TextEdit(
                        range: NSRange(location: firstNonWhitespaceOffset, length: removeLength),
                        replacement: ""
                    )
                )
            } else {
                edits.append(
                    TextEdit(
                        range: NSRange(location: firstNonWhitespaceOffset, length: 0),
                        replacement: "// "
                    )
                )
            }
        }

        guard !edits.isEmpty else { return nil }
        return applyEdits(
            edits,
            source: source,
            selection: safeSelection,
            refreshStartUTF16: lineRanges[0].location
        )
    }

    func toggleCSSBlockComment(source: String, selection: NSRange) -> EditorCommandResult? {
        let nsSource = source as NSString
        let safeSelection = Self.clampedRange(selection, utf16Length: nsSource.length)
        let targetLinesRange = selectedLineEnvelope(in: nsSource, selection: safeSelection)
        guard targetLinesRange.length > 0 else { return nil }

        let segment = nsSource.substring(with: targetLinesRange)
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wrappedComment = wrappedCSSCommentBounds(in: segment) {
            let openLocation = wrappedComment.openLocation
            let closeLocation = wrappedComment.closeLocation

            let openAbsolute = targetLinesRange.location + openLocation
            let closeAbsolute = targetLinesRange.location + closeLocation

            var openLength = 2
            if character(in: nsSource, at: openAbsolute + 2) == " " {
                openLength = 3
            }

            var closeRemovalLocation = closeAbsolute
            var closeRemovalLength = 2
            if character(in: nsSource, at: closeAbsolute - 1) == " " {
                closeRemovalLocation -= 1
                closeRemovalLength = 3
            }

            let edits = [
                TextEdit(range: NSRange(location: closeRemovalLocation, length: closeRemovalLength), replacement: ""),
                TextEdit(range: NSRange(location: openAbsolute, length: openLength), replacement: ""),
            ]
            return applyEdits(
                edits,
                source: source,
                selection: safeSelection,
                refreshStartUTF16: targetLinesRange.location
            )
        }

        if trimmed.hasPrefix("/*"), trimmed.hasSuffix("*/") {
            return nil
        }

        if segment.range(of: "/*") != nil || segment.range(of: "*/") != nil {
            return nil
        }

        let edits = [
            TextEdit(range: NSRange(location: targetLinesRange.location + targetLinesRange.length, length: 0), replacement: " */"),
            TextEdit(range: NSRange(location: targetLinesRange.location, length: 0), replacement: "/* "),
        ]
        return applyEdits(
            edits,
            source: source,
            selection: safeSelection,
            refreshStartUTF16: targetLinesRange.location
        )
    }

    func applyEdits(
        _ edits: [TextEdit],
        source: String,
        selection: NSRange,
        refreshStartUTF16: Int
    ) -> EditorCommandResult {
        let sorted = edits.sorted { lhs, rhs in
            lhs.range.location > rhs.range.location
        }

        let mutable = NSMutableString(string: source)
        var selectionStart = selection.location
        var selectionEnd = selection.location + selection.length

        for edit in sorted {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
            selectionStart = adjustedSelectionOffset(selectionStart, for: edit, affinity: .forward)
            selectionEnd = adjustedSelectionOffset(selectionEnd, for: edit, affinity: .backward)
        }

        let clampedStart = max(0, selectionStart)
        let clampedEnd = max(clampedStart, selectionEnd)
        return EditorCommandResult(
            text: mutable as String,
            selectedRange: NSRange(location: clampedStart, length: clampedEnd - clampedStart),
            refreshStartUTF16: max(0, refreshStartUTF16)
        )
    }

    func adjustedSelectionOffset(
        _ offset: Int,
        for edit: TextEdit,
        affinity: SelectionBoundaryAffinity
    ) -> Int {
        let start = edit.range.location
        let oldEnd = start + edit.range.length
        let newEnd = start + edit.replacement.utf16.count

        if offset < start {
            return offset
        }

        if offset == start {
            switch affinity {
            case .forward:
                return newEnd
            case .backward:
                return start
            }
        }

        if offset < oldEnd {
            return newEnd
        }
        return offset + (newEnd - oldEnd)
    }

    func selectedLineRanges(in source: NSString, selection: NSRange) -> [NSRange] {
        let envelope = selectedLineEnvelope(in: source, selection: selection)
        if envelope.length == 0 {
            return [envelope]
        }

        var ranges: [NSRange] = []
        var cursor = envelope.location
        let end = envelope.location + envelope.length

        while cursor < end {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            ranges.append(lineRange)
            cursor = lineRange.location + lineRange.length
        }

        return ranges
    }

    func selectedLineEnvelope(in source: NSString, selection: NSRange) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }

        if selection.length == 0 {
            return source.lineRange(for: NSRange(location: selection.location, length: 0))
        }

        let startLine = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let lastTouchedOffset = max(selection.location, selection.location + selection.length - 1)
        let endLine = source.lineRange(for: NSRange(location: min(lastTouchedOffset, source.length - 1), length: 0))

        let start = startLine.location
        let end = endLine.location + endLine.length
        return NSRange(location: start, length: max(0, end - start))
    }

    func lineStartOffsets(in source: NSString, selection: NSRange) -> [Int] {
        selectedLineRanges(in: source, selection: selection).map(\.location)
    }

    func removableIndentLength(in source: NSString, lineRange: NSRange) -> Int {
        let content = lineContentRange(in: source, lineRange: lineRange)
        guard content.length > 0 else { return 0 }

        var cursor = content.location
        let end = content.location + content.length
        var removedWidth = 0
        var removedUTF16 = 0

        while cursor < end, removedWidth < indentUnit.utf16.count {
            let ch = source.character(at: cursor)
            if ch == 32 { // " "
                removedWidth += 1
                removedUTF16 += 1
            } else if ch == 9 { // "\t"
                removedWidth += indentUnit.utf16.count
                removedUTF16 += 1
            } else {
                break
            }
            cursor += 1
        }

        return removedUTF16
    }

    func lineInfo(in source: NSString, lineRange: NSRange) -> LineInfo {
        let contentRange = lineContentRange(in: source, lineRange: lineRange)

        var firstNonWhitespace: Int?
        var cursor = contentRange.location
        let end = contentRange.location + contentRange.length
        while cursor < end {
            let ch = source.character(at: cursor)
            if ch != 32, ch != 9 {
                firstNonWhitespace = cursor
                break
            }
            cursor += 1
        }

        let isBlank = firstNonWhitespace == nil
        let hasLineComment: Bool
        if let firstNonWhitespace {
            hasLineComment = character(in: source, at: firstNonWhitespace) == "/" &&
                character(in: source, at: firstNonWhitespace + 1) == "/"
        } else {
            hasLineComment = false
        }

        return LineInfo(
            lineRange: lineRange,
            contentRange: contentRange,
            firstNonWhitespaceOffset: firstNonWhitespace,
            isBlank: isBlank,
            hasLineComment: hasLineComment
        )
    }

    func lineContentRange(in source: NSString, lineRange: NSRange) -> NSRange {
        var length = lineRange.length
        if length > 0, source.character(at: lineRange.location + length - 1) == 10 {
            length -= 1
        }
        if length > 0, source.character(at: lineRange.location + length - 1) == 13 {
            length -= 1
        }
        return NSRange(location: lineRange.location, length: max(0, length))
    }

    func leadingIndent(in source: NSString, lineRange: NSRange) -> String {
        let contentRange = lineContentRange(in: source, lineRange: lineRange)
        var cursor = contentRange.location
        let end = contentRange.location + contentRange.length
        while cursor < end {
            let ch = source.character(at: cursor)
            if ch != 32, ch != 9 {
                break
            }
            cursor += 1
        }
        return source.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
    }

    func trailingIndentRemovalLength(_ text: String) -> Int {
        let nsText = text as NSString
        var cursor = nsText.length - 1
        var removedWidth = 0
        var removedUTF16 = 0

        while cursor >= 0, removedWidth < indentUnit.utf16.count {
            let ch = nsText.character(at: cursor)
            if ch == 32 { // " "
                removedWidth += 1
                removedUTF16 += 1
            } else if ch == 9 { // "\t"
                removedWidth += indentUnit.utf16.count
                removedUTF16 += 1
            } else {
                break
            }
            cursor -= 1
        }
        return removedUTF16
    }

    func previousNonWhitespaceCharacter(in source: NSString, before offset: Int) -> Character? {
        var cursor = offset - 1
        while cursor >= 0 {
            let ch = source.character(at: cursor)
            if ch == 32 || ch == 9 || ch == 10 || ch == 13 {
                cursor -= 1
                continue
            }
            return character(in: source, at: cursor)
        }
        return nil
    }

    func nextNonWhitespaceOffset(in source: NSString, from offset: Int) -> Int? {
        var cursor = max(0, offset)
        while cursor < source.length {
            let ch = source.character(at: cursor)
            if ch == 32 || ch == 9 || ch == 10 || ch == 13 {
                cursor += 1
                continue
            }
            return cursor
        }
        return nil
    }

    func character(in source: NSString, at offset: Int) -> Character? {
        guard offset >= 0, offset < source.length else { return nil }
        let composedRange = source.rangeOfComposedCharacterSequence(at: offset)
        guard composedRange.location != NSNotFound, composedRange.length > 0 else {
            return nil
        }
        return source.substring(with: composedRange).first
    }

    func isQuote(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == "`"
    }

    func closingCharacter(for opening: Character) -> Character {
        switch opening {
        case "(":
            return ")"
        case "[":
            return "]"
        case "{":
            return "}"
        default:
            return "}"
        }
    }

    func isLikelyInsideLiteralOrComment(
        source: NSString,
        location: Int,
        language: SyntaxLanguage
    ) -> Bool {
        let clampedLocation = max(0, min(location, source.length))

        if language == .javascript {
            let prefix = source.substring(to: clampedLocation)
            return analyzeJavaScriptPrefix(prefix).isInsideLiteralOrComment
        }

        if language == .css {
            let prefix = source.substring(to: clampedLocation)
            return analyzeCSSPrefix(prefix).isInsideLiteralOrComment
        }

        let lineRange = source.lineRange(for: NSRange(location: clampedLocation, length: 0))
        let prefixLength = max(0, clampedLocation - lineRange.location)
        let prefix = source.substring(with: NSRange(location: lineRange.location, length: prefixLength))
        if hasOddUnescapedQuote(in: prefix, quote: "\"") { return true }

        if language != .json {
            let before = source.substring(to: clampedLocation)
            let openCount = before.components(separatedBy: "/*").count - 1
            let closeCount = before.components(separatedBy: "*/").count - 1
            if openCount > closeCount {
                return true
            }
        }

        return false
    }

    func hasOddUnescapedQuote(in text: String, quote: Character) -> Bool {
        var count = 0
        var isEscaped = false
        for ch in text {
            if isEscaped {
                isEscaped = false
                continue
            }
            if ch == "\\" {
                isEscaped = true
                continue
            }
            if ch == quote {
                count += 1
            }
        }
        return count % 2 == 1
    }

    struct CSSPrefixAnalysis {
        var inSingleQuote = false
        var inDoubleQuote = false
        var inBlockComment = false
        var isEscaped = false

        var isInsideLiteralOrComment: Bool {
            inSingleQuote || inDoubleQuote || inBlockComment
        }
    }

    func analyzeCSSPrefix(_ text: String) -> CSSPrefixAnalysis {
        let nsText = text as NSString
        var analysis = CSSPrefixAnalysis()
        var cursor = 0
        let singleQuote: unichar = 39
        let doubleQuote: unichar = 34
        let backslash: unichar = 92
        let slash: unichar = 47
        let asterisk: unichar = 42

        while cursor < nsText.length {
            let codeUnit = nsText.character(at: cursor)
            let nextCodeUnit: unichar? = cursor + 1 < nsText.length ? nsText.character(at: cursor + 1) : nil

            if analysis.inBlockComment {
                if codeUnit == asterisk, nextCodeUnit == slash {
                    analysis.inBlockComment = false
                    cursor += 2
                } else {
                    cursor += 1
                }
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

            if codeUnit == slash, nextCodeUnit == asterisk {
                analysis.inBlockComment = true
                cursor += 2
                continue
            }

            cursor += 1
        }

        return analysis
    }

    struct JavaScriptPrefixAnalysis {
        var inSingleQuote = false
        var inDoubleQuote = false
        var templateExpressionDepthStack: [Int] = []
        var inLineComment = false
        var inBlockComment = false
        var inRegexLiteral = false
        var inRegexCharacterClass = false
        var regexCharacterClassHasContent = false
        var isEscaped = false

        var isInsideTemplateLiteralText: Bool {
            templateExpressionDepthStack.contains(0)
        }

        var isInsideLiteralOrComment: Bool {
            inSingleQuote || inDoubleQuote || isInsideTemplateLiteralText || inLineComment || inBlockComment || inRegexLiteral
        }
    }

    func analyzeJavaScriptPrefix(_ text: String) -> JavaScriptPrefixAnalysis {
        let nsText = text as NSString
        var analysis = JavaScriptPrefixAnalysis()
        var cursor = 0
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
                        guard isJavaScriptIdentifierPart(flagUnit) else { break }
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
                    if shouldStartJavaScriptRegexLiteral(in: nsText, at: cursor) {
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
                if shouldStartJavaScriptRegexLiteral(in: nsText, at: cursor) {
                    analysis.inRegexLiteral = true
                    analysis.inRegexCharacterClass = false
                    analysis.regexCharacterClassHasContent = false
                    cursor += 1
                    continue
                }
            }

            cursor += 1
        }

        return analysis
    }

    static func clampedRange(_ range: NSRange, utf16Length: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Length)
        let available = max(0, utf16Length - location)
        let length = min(max(0, range.length), available)
        return NSRange(location: location, length: length)
    }

    func lineStartUTF16Offset(in source: String, around offset: Int) -> Int {
        let nsString = source as NSString
        let clampedOffset = min(max(0, offset), nsString.length)
        return nsString.lineRange(for: NSRange(location: clampedOffset, length: 0)).location
    }

    func shouldStartJavaScriptRegexLiteral(in source: NSString, at slashOffset: Int) -> Bool {
        guard slashOffset >= 0, slashOffset < source.length else { return false }
        guard let cursor = previousJavaScriptSignificantOffset(in: source, before: slashOffset) else { return true }
        let codeUnit = source.character(at: cursor)

        if let tokenInfo = javaScriptIdentifierToken(in: source, endingAt: cursor) {
            let token = tokenInfo.text
            if [
                "return", "throw", "case", "delete", "void", "typeof", "instanceof", "new", "in", "of", "await",
                "yield", "else",
            ].contains(token) {
                if let previousOffset = previousJavaScriptSignificantOffset(in: source, before: tokenInfo.range.location) {
                    let previousCodeUnit = source.character(at: previousOffset)
                    if previousCodeUnit == 46 || previousCodeUnit == 63 { // ".", "?"
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
        if codeUnit == 41 { // ")"
            return shouldTreatSlashAfterClosingParenAsRegex(in: source, closingParenOffset: cursor)
        }
        if codeUnit == 47 { // "/"
            return false
        }
        if codeUnit == 46 { // "."
            return false
        }
        if codeUnit == 34 || codeUnit == 39 || codeUnit == 96 { // "\"", "'", "`"
            return false
        }

        if [
            40, 91, 123, 44, 58, 59, 61, 33, 63, 43, 45, 42, 37, 38, 124, 94, 126, 60, 62,
        ].contains(Int(codeUnit)) {
            if (codeUnit == 43 || codeUnit == 45), previousNonWhitespaceCodeUnit(in: source, before: cursor) == codeUnit {
                return false
            }
            return true
        }

        return true
    }

    func shouldTreatSlashAfterClosingParenAsRegex(in source: NSString, closingParenOffset: Int) -> Bool {
        guard closingParenOffset >= 0, closingParenOffset < source.length else { return false }
        guard source.character(at: closingParenOffset) == 41 else { return false } // ")"
        guard let openParenOffset = matchingOpenParenOffset(in: source, forClosingParenAt: closingParenOffset) else {
            return false
        }
        guard let tokenEnd = previousJavaScriptSignificantOffset(in: source, before: openParenOffset),
              let tokenInfo = javaScriptIdentifierToken(in: source, endingAt: tokenEnd)
        else {
            return false
        }
        if let previousOffset = previousJavaScriptSignificantOffset(in: source, before: tokenInfo.range.location) {
            let previousCodeUnit = source.character(at: previousOffset)
            if previousCodeUnit == 46 || previousCodeUnit == 63 { // ".", "?"
                return false
            }
        }
        return ["if", "while", "for", "with", "switch", "catch"].contains(tokenInfo.text)
    }

    func matchingOpenParenOffset(in source: NSString, forClosingParenAt closingParenOffset: Int) -> Int? {
        guard closingParenOffset >= 0, closingParenOffset < source.length else { return nil }
        guard source.character(at: closingParenOffset) == 41 else { return nil } // ")"

        let prefix = source.substring(with: NSRange(location: 0, length: closingParenOffset + 1))
        let nsText = prefix as NSString
        var analysis = JavaScriptPrefixAnalysis()
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
                        guard isJavaScriptIdentifierPart(flagUnit) else { break }
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
                    if shouldStartJavaScriptRegexLiteral(in: nsText, at: cursor) {
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
                if shouldStartJavaScriptRegexLiteral(in: nsText, at: cursor) {
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

    func javaScriptIdentifierToken(in source: NSString, endingAt offset: Int) -> (range: NSRange, text: String)? {
        guard offset >= 0, offset < source.length else { return nil }
        let endRange = source.rangeOfComposedCharacterSequence(at: offset)
        guard isJavaScriptIdentifierPart(in: source, range: endRange) else { return nil }

        var start = endRange.location
        let end = endRange.location + endRange.length
        while start > 0 {
            let previousRange = source.rangeOfComposedCharacterSequence(at: start - 1)
            guard isJavaScriptIdentifierPart(in: source, range: previousRange) else { break }
            start = previousRange.location
        }

        let range = NSRange(location: start, length: end - start)
        return (range: range, text: source.substring(with: range))
    }

    func isJavaScriptIdentifierPart(in source: NSString, range: NSRange) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else { return false }
        let fragment = source.substring(with: range)
        for scalar in fragment.unicodeScalars {
            if scalar.value == 95 || scalar.value == 36 { // "_" and "$"
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

    func isJavaScriptIdentifierPart(_ codeUnit: unichar) -> Bool {
        if codeUnit == 95 || codeUnit == 36 { // "_" and "$"
            return true
        }
        if (48...57).contains(Int(codeUnit)) {
            return true
        }
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    func previousJavaScriptSignificantOffset(in source: NSString, before location: Int) -> Int? {
        var cursor = location - 1
        while cursor >= 0 {
            let codeUnit = source.character(at: cursor)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                cursor -= 1
                continue
            }

            if codeUnit == 47, cursor - 1 >= 0, source.character(at: cursor - 1) == 42 { // "*/"
                cursor -= 2
                var foundOpen = false
                while cursor >= 1 {
                    if source.character(at: cursor - 1) == 47, source.character(at: cursor) == 42 { // "/*"
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

    func lineCommentStartOffset(in source: NSString, atOrBefore location: Int) -> Int? {
        guard location >= 0, location < source.length else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        var cursor = lineRange.location
        var isEscaped = false
        var inSingleQuote = false
        var inDoubleQuote = false
        var inBacktick = false

        while cursor <= location {
            let codeUnit = source.character(at: cursor)
            let nextCodeUnit: unichar? = cursor + 1 < lineRange.location + lineRange.length ? source.character(at: cursor + 1) : nil

            if isEscaped {
                isEscaped = false
                cursor += 1
                continue
            }

            if inSingleQuote {
                if codeUnit == 92 { // "\\"
                    isEscaped = true
                } else if codeUnit == 39 { // "'"
                    inSingleQuote = false
                }
                cursor += 1
                continue
            }

            if inDoubleQuote {
                if codeUnit == 92 { // "\\"
                    isEscaped = true
                } else if codeUnit == 34 { // "\""
                    inDoubleQuote = false
                }
                cursor += 1
                continue
            }

            if inBacktick {
                if codeUnit == 92 { // "\\"
                    isEscaped = true
                } else if codeUnit == 96 { // "`"
                    inBacktick = false
                }
                cursor += 1
                continue
            }

            if codeUnit == 39 { // "'"
                inSingleQuote = true
                cursor += 1
                continue
            }
            if codeUnit == 34 { // "\""
                inDoubleQuote = true
                cursor += 1
                continue
            }
            if codeUnit == 96 { // "`"
                inBacktick = true
                cursor += 1
                continue
            }

            if codeUnit == 47, nextCodeUnit == 47 { // "//"
                return cursor
            }

            cursor += 1
        }

        return nil
    }

    func previousNonWhitespaceOffset(in source: NSString, before location: Int) -> Int? {
        var cursor = location - 1
        while cursor >= 0 {
            let codeUnit = source.character(at: cursor)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                cursor -= 1
                continue
            }
            return cursor
        }
        return nil
    }

    func previousNonWhitespaceCodeUnit(in source: NSString, before location: Int) -> unichar? {
        var cursor = location - 1
        while cursor >= 0 {
            let codeUnit = source.character(at: cursor)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                cursor -= 1
                continue
            }
            return codeUnit
        }
        return nil
    }

    struct CSSWrappedCommentBounds {
        let openLocation: Int
        let closeLocation: Int
    }

    func wrappedCSSCommentBounds(in segment: String) -> CSSWrappedCommentBounds? {
        let nsSegment = segment as NSString
        guard nsSegment.length >= 4 else { return nil }

        var firstNonWhitespace = 0
        while firstNonWhitespace < nsSegment.length {
            let codeUnit = nsSegment.character(at: firstNonWhitespace)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                firstNonWhitespace += 1
                continue
            }
            break
        }
        guard firstNonWhitespace + 1 < nsSegment.length else { return nil }
        guard nsSegment.character(at: firstNonWhitespace) == 47, nsSegment.character(at: firstNonWhitespace + 1) == 42 else {
            return nil
        }

        var lastNonWhitespace = nsSegment.length - 1
        while lastNonWhitespace >= 0 {
            let codeUnit = nsSegment.character(at: lastNonWhitespace)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                lastNonWhitespace -= 1
                continue
            }
            break
        }
        guard lastNonWhitespace - 1 >= 0 else { return nil }
        guard nsSegment.character(at: lastNonWhitespace - 1) == 42, nsSegment.character(at: lastNonWhitespace) == 47 else {
            return nil
        }

        let openLocation = firstNonWhitespace
        let closeLocation = lastNonWhitespace - 1
        guard closeLocation > openLocation else { return nil }

        let closeSearchRange = NSRange(
            location: openLocation + 2,
            length: max(0, nsSegment.length - (openLocation + 2))
        )
        let firstCloseLocation = nsSegment.range(of: "*/", options: [], range: closeSearchRange).location
        guard firstCloseLocation == closeLocation else { return nil }

        return CSSWrappedCommentBounds(openLocation: openLocation, closeLocation: closeLocation)
    }
}
