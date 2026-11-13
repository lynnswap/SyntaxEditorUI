import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguages

package final class EditorCommandEngine {
    package struct Result {
        package let edits: [SyntaxEditorTextChange.Replacement]
        package let selectedRange: NSRange

        package init(edits: [SyntaxEditorTextChange.Replacement], selectedRange: NSRange) {
            self.edits = edits
            self.selectedRange = selectedRange
        }

        package init(edit: SyntaxEditorTextChange.Replacement, selectedRange: NSRange) {
            self.init(edits: [edit], selectedRange: selectedRange)
        }
    }

    private let indentUnit = "    "
    private var pendingTOMLMultilineDelimiter: PendingTOMLMultilineDelimiter?

    package enum DeletionIntent {
        case unspecified
        case backward
    }

    package init() {}

    private struct PendingTOMLMultilineDelimiter {
        let cursorLocation: Int
        let quote: Character
    }

    package func invalidateTransientState() {
        pendingTOMLMultilineDelimiter = nil
    }

    package func transformInput(
        source: String,
        range: NSRange,
        replacementText: String,
        language: SyntaxLanguage,
        deletionIntent: DeletionIntent = .unspecified
    ) -> EditorCommandEngine.Result? {
        let nsSource = source as NSString
        let safeRange = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: nsSource.length)
        guard language.supportsCodeEditingCommands else {
            invalidateTransientState()
            return nil
        }
        let singleCharacterInput = replacementText.utf16.count == 1 ? replacementText.first : nil

        if !(singleCharacterInput.map(isQuote) ?? false) {
            invalidateTransientState()
        }

        if replacementText == "\n" {
            return smartNewline(source: source, range: safeRange)
        }

        if replacementText == "\t" {
            return insertTab(source: source, selection: safeRange, language: language)
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

    package func insertTab(
        source: String,
        selection: NSRange,
        language: SyntaxLanguage
    ) -> EditorCommandEngine.Result? {
        guard language.supportsCodeEditingCommands else {
            invalidateTransientState()
            return nil
        }

        invalidateTransientState()
        let nsSource = source as NSString
        let safeSelection = SyntaxEditorRangeUtilities.clampedRange(selection, utf16Length: nsSource.length)

        guard safeSelection.length == 0 else {
            return indentSelection(source: source, selection: safeSelection, language: language)
        }

        let lineRange = nsSource.lineRange(for: NSRange(location: safeSelection.location, length: 0))
        let linePrefixRange = NSRange(
            location: lineRange.location,
            length: safeSelection.location - lineRange.location
        )
        let linePrefix = nsSource.substring(with: linePrefixRange)
        let tabWidth = indentUnit.utf16.count
        let column = SyntaxEditorDisplayColumnUtilities.columnCount(in: linePrefix, tabWidth: tabWidth)
        let spaces = SyntaxEditorDisplayColumnUtilities.spacesToNextTabStop(from: column, tabWidth: tabWidth)
        let replacement = String(repeating: " ", count: spaces)

        return EditorCommandEngine.Result(
            edit: SyntaxEditorTextChange.Replacement(range: safeSelection, replacement: replacement),
            selectedRange: NSRange(location: safeSelection.location + replacement.utf16.count, length: 0)
        )
    }

    package func indentSelection(
        source: String,
        selection: NSRange,
        language: SyntaxLanguage
    ) -> EditorCommandEngine.Result? {
        guard language.supportsCodeEditingCommands else {
            invalidateTransientState()
            return nil
        }

        invalidateTransientState()
        let nsSource = source as NSString
        let safeSelection = SyntaxEditorRangeUtilities.clampedRange(selection, utf16Length: nsSource.length)
        let lineStarts = SyntaxLanguageTextUtilities.lineStartOffsets(in: nsSource, selection: safeSelection)
        guard !lineStarts.isEmpty else { return nil }

        let edits = lineStarts.map {
            SyntaxLanguageTextEdit(range: NSRange(location: $0, length: 0), replacement: indentUnit)
        }

        return wrap(SyntaxLanguageTextUtilities.applyEdits(edits, source: source, selection: safeSelection))
    }

    package func outdentSelection(
        source: String,
        selection: NSRange,
        language: SyntaxLanguage
    ) -> EditorCommandEngine.Result? {
        guard language.supportsCodeEditingCommands else {
            invalidateTransientState()
            return nil
        }

        invalidateTransientState()
        let nsSource = source as NSString
        let safeSelection = SyntaxEditorRangeUtilities.clampedRange(selection, utf16Length: nsSource.length)
        let lineStarts = SyntaxLanguageTextUtilities.lineStartOffsets(in: nsSource, selection: safeSelection)
        guard !lineStarts.isEmpty else { return nil }

        var edits: [SyntaxLanguageTextEdit] = []
        edits.reserveCapacity(lineStarts.count)

        for lineStart in lineStarts {
            let lineRange = nsSource.lineRange(for: NSRange(location: lineStart, length: 0))
            let removable = SyntaxLanguageTextUtilities.removableIndentLength(
                in: nsSource,
                lineRange: lineRange,
                indentUnit: indentUnit
            )
            guard removable > 0 else { continue }
            edits.append(SyntaxLanguageTextEdit(range: NSRange(location: lineStart, length: removable), replacement: ""))
        }

        guard !edits.isEmpty else { return nil }
        return wrap(SyntaxLanguageTextUtilities.applyEdits(edits, source: source, selection: safeSelection))
    }

    package func toggleComment(
        source: String,
        selection: NSRange,
        language: SyntaxLanguage
    ) -> EditorCommandEngine.Result? {
        invalidateTransientState()
        guard language.supportsCodeEditingCommands else { return nil }
        let nsSource = source as NSString
        let safeSelection = SyntaxEditorRangeUtilities.clampedRange(selection, utf16Length: nsSource.length)
        guard let edit = language.toggleComment(source: source, selection: safeSelection) else { return nil }
        return wrap(edit)
    }
}

private extension EditorCommandEngine {
    func wrap(_ edit: SyntaxLanguage.EditResult) -> EditorCommandEngine.Result {
        EditorCommandEngine.Result(edits: edit.edits, selectedRange: edit.selectedRange)
    }

    func autoPair(
        source: String,
        range: NSRange,
        input: Character,
        language: SyntaxLanguage
    ) -> EditorCommandEngine.Result? {
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

        if shouldInsertPendingTOMLMultilineDelimiter(
            range: range,
            input: input,
            language: language
        ) {
            pendingTOMLMultilineDelimiter = nil
            return EditorCommandEngine.Result(
                edit: SyntaxEditorTextChange.Replacement(range: range, replacement: String(input)),
                selectedRange: NSRange(location: range.location + 1, length: 0)
            )
        }

        pendingTOMLMultilineDelimiter = nil

        if isQuote(input),
           range.length == 0,
           let next = SyntaxLanguageTextUtilities.character(in: nsSource, at: range.location),
           next == input
        {
            if shouldStartTOMLMultilineDelimiterPending(
                source: nsSource,
                range: range,
                input: input,
                language: language
            ) {
                pendingTOMLMultilineDelimiter = PendingTOMLMultilineDelimiter(
                    cursorLocation: range.location + 1,
                    quote: input
                )
            }

            return EditorCommandEngine.Result(
                edits: [],
                selectedRange: NSRange(location: range.location + 1, length: 0)
            )
        }

        if let open = openingPairs[input] {
            if isQuote(input),
               language.isInsideLiteralOrComment(source: source, location: range.location)
            {
                return nil
            }

            if range.length > 0 {
                let selected = nsSource.substring(with: range)
                let wrapped = String(input) + selected + String(open)
                let cursor = range.location + wrapped.utf16.count
                return EditorCommandEngine.Result(
                    edit: SyntaxEditorTextChange.Replacement(range: range, replacement: wrapped),
                    selectedRange: NSRange(location: cursor, length: 0)
                )
            }

            let inserted = String(input) + String(open)
            return EditorCommandEngine.Result(
                edit: SyntaxEditorTextChange.Replacement(range: range, replacement: inserted),
                selectedRange: NSRange(location: range.location + 1, length: 0)
            )
        }

        if let pairOpen = closingPairs[input], range.length == 0 {
            if let next = SyntaxLanguageTextUtilities.character(in: nsSource, at: range.location), next == input {
                return EditorCommandEngine.Result(
                    edits: [],
                    selectedRange: NSRange(location: range.location + 1, length: 0)
                )
            }

            if input == "}" {
                if let nextNonWhitespace = SyntaxLanguageTextUtilities.nextNonWhitespaceOffset(in: nsSource, from: range.location),
                   SyntaxLanguageTextUtilities.character(in: nsSource, at: nextNonWhitespace) == input
                {
                    return EditorCommandEngine.Result(
                        edits: [],
                        selectedRange: NSRange(location: nextNonWhitespace + 1, length: 0)
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

    func pairAwareBackspace(source: String, range: NSRange) -> EditorCommandEngine.Result? {
        let nsSource = source as NSString
        guard range.length == 1 else { return nil }
        let deleteOffset = range.location
        let afterOffset = range.location + range.length
        guard let deleted = SyntaxLanguageTextUtilities.character(in: nsSource, at: deleteOffset),
              let after = SyntaxLanguageTextUtilities.character(in: nsSource, at: afterOffset)
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
        return EditorCommandEngine.Result(
            edit: SyntaxEditorTextChange.Replacement(range: removeRange, replacement: ""),
            selectedRange: NSRange(location: deleteOffset, length: 0)
        )
    }

    func smartNewline(source: String, range: NSRange) -> EditorCommandEngine.Result? {
        guard range.length == 0 else { return nil }
        let nsSource = source as NSString

        let lineRange = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
        let lineIndent = SyntaxLanguageTextUtilities.leadingIndent(in: nsSource, lineRange: lineRange)

        let previous = SyntaxLanguageTextUtilities.previousNonWhitespaceCharacter(in: nsSource, before: range.location)
        let next = SyntaxLanguageTextUtilities.character(in: nsSource, at: range.location)
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

        return EditorCommandEngine.Result(
            edit: SyntaxEditorTextChange.Replacement(range: range, replacement: insertion),
            selectedRange: NSRange(location: range.location + cursorOffset, length: 0)
        )
    }

    func outdentForClosingBrace(
        source: String,
        location: Int,
        expectedPairOpen: Character
    ) -> EditorCommandEngine.Result? {
        let nsSource = source as NSString
        let lineRange = nsSource.lineRange(for: NSRange(location: location, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: max(0, location - lineRange.location))
        let prefix = nsSource.substring(with: prefixRange)

        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        guard !prefix.isEmpty else { return nil }

        let removable = SyntaxLanguageTextUtilities.trailingIndentRemovalLength(prefix, indentUnit: indentUnit)
        guard removable > 0 else { return nil }

        let reducedPrefixLength = max(0, prefix.utf16.count - removable)
        let reducedPrefix = String(prefix.prefix(reducedPrefixLength))
        let replacement = reducedPrefix + String(closingCharacter(for: expectedPairOpen))
        let cursor = lineRange.location + replacement.utf16.count

        return EditorCommandEngine.Result(
            edit: SyntaxEditorTextChange.Replacement(range: prefixRange, replacement: replacement),
            selectedRange: NSRange(location: cursor, length: 0)
        )
    }

    func isQuote(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == "`"
    }

    func shouldInsertPendingTOMLMultilineDelimiter(
        range: NSRange,
        input: Character,
        language: SyntaxLanguage
    ) -> Bool {
        guard language == .toml,
              let pendingTOMLMultilineDelimiter,
              range.length == 0,
              pendingTOMLMultilineDelimiter.cursorLocation == range.location,
              pendingTOMLMultilineDelimiter.quote == input
        else {
            return false
        }

        return true
    }

    func shouldStartTOMLMultilineDelimiterPending(
        source: NSString,
        range: NSRange,
        input: Character,
        language: SyntaxLanguage
    ) -> Bool {
        guard language == .toml,
              range.length == 0,
              input == "\"" || input == "'",
              range.location > 0,
              let previous = SyntaxLanguageTextUtilities.character(in: source, at: range.location - 1),
              let next = SyntaxLanguageTextUtilities.character(in: source, at: range.location)
        else {
            return false
        }

        return previous == input && next == input
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
}
