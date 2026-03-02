import Foundation
import Testing
@testable import SyntaxEditorUI

#if canImport(AppKit)
import AppKit
#endif

@Suite("SyntaxEditorUI")
struct SyntaxEditorUITests {
    @Test("SyntaxLanguage normalizedRawValue maps supported values")
    func syntaxLanguageNormalization() {
        #expect(SyntaxLanguage(normalizedRawValue: "css") == .css)
        #expect(SyntaxLanguage(normalizedRawValue: " javascript ") == .javascript)
        #expect(SyntaxLanguage(normalizedRawValue: "JS") == .javascript)
        #expect(SyntaxLanguage(normalizedRawValue: "JSON") == .json)
    }

    @Test("SyntaxLanguage rejects unsupported values")
    func syntaxLanguageRejectsUnsupportedValue() {
        #expect(SyntaxLanguage(normalizedRawValue: "swift") == nil)
    }

    @Test("SyntaxEditorModel stores and mutates state on MainActor")
    @MainActor
    func syntaxEditorModelState() {
        let model = SyntaxEditorModel(text: "{}", language: .json)

        #expect(model.text == "{}")
        #expect(model.language == .json)
        #expect(model.isEditable == true)
        #expect(model.lineWrappingEnabled == false)

        model.text = "body { color: red; }"
        model.language = .css
        model.isEditable = false
        model.lineWrappingEnabled = true

        #expect(model.text == "body { color: red; }")
        #expect(model.language == .css)
        #expect(model.isEditable == false)
        #expect(model.lineWrappingEnabled == true)
    }

    @Test("SyntaxEditorHighlightTheme maps representative captures to Xcode-like palette")
    func syntaxEditorHighlightThemeMapping() {
        #expect(
            SyntaxEditorHighlightTheme.colorPair(for: "keyword.control")
                == SyntaxEditorHexColorPair(light: 0xAD3DA4, dark: 0xFC5FA3)
        )
        #expect(
            SyntaxEditorHighlightTheme.colorPair(for: "string.quoted")
                == SyntaxEditorHexColorPair(light: 0xC41A16, dark: 0xFC6A5D)
        )
        #expect(
            SyntaxEditorHighlightTheme.colorPair(for: "number")
                == SyntaxEditorHexColorPair(light: 0x1C00CF, dark: 0xD0BF69)
        )
        #expect(SyntaxEditorHighlightTheme.colorPair(for: "unknown.capture") == nil)
    }

    @Test("SyntaxEditorRangeUtilities clamps and intersects UTF-16 ranges")
    func syntaxEditorRangeUtilities() {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(NSRange(location: -4, length: 20), utf16Length: 10)
        #expect(clamped == NSRange(location: 0, length: 10))

        let intersection = SyntaxEditorRangeUtilities.intersection(
            of: NSRange(location: 4, length: 6),
            and: NSRange(location: 0, length: 5)
        )
        #expect(intersection == NSRange(location: 4, length: 1))

        let lineStart = SyntaxEditorRangeUtilities.lineStartUTF16Offset(in: "a\nbc\ndef", around: 4)
        #expect(lineStart == 2)
    }

    @Test("TextMutation returns nil when text does not change")
    func textMutationNoChange() {
        #expect(TextMutation.diff(from: "body {}", to: "body {}") == nil)
    }

    @Test("TextMutation computes insertion range for newline")
    func textMutationInsertionRange() {
        let mutation = TextMutation.diff(from: "a\nb", to: "a\n\nb")
        #expect(mutation?.range == NSRange(location: 2, length: 0))
        #expect(mutation?.replacement == "\n")
    }

    @Test("TextMutation computes replacement range for comment toggle")
    func textMutationReplacementRange() {
        let mutation = TextMutation.diff(
            from: "let value = 1;\n",
            to: "// let value = 1;\n"
        )
        #expect(mutation?.range == NSRange(location: 0, length: 0))
        #expect(mutation?.replacement == "// ")
    }

    @Test("TextMutation keeps prefix attributes when applying mutation")
    func textMutationPreservesPrefixAttributes() {
        let oldText = "/* comment */\nbody {\n}"
        let newText = "/* comment */\nbody {\n    \n}"
        guard let mutation = TextMutation.diff(from: oldText, to: newText) else {
            Issue.record("Mutation should exist for changed text")
            return
        }

        let key = NSAttributedString.Key("token")
        let attributed = NSMutableAttributedString(string: oldText)
        attributed.addAttribute(key, value: "comment", range: NSRange(location: 0, length: 12))
        attributed.replaceCharacters(in: mutation.range, with: mutation.replacement)

        #expect(attributed.string == newText)
        #expect((attributed.attribute(key, at: 2, effectiveRange: nil) as? String) == "comment")
    }

    @Test("EditorCommandEngine auto-pairs opening braces")
    func editorCommandEngineAutoPair() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "",
            range: NSRange(location: 0, length: 0),
            replacementText: "{",
            language: .javascript
        )

        #expect(result?.text == "{}")
        #expect(result?.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("EditorCommandEngine wraps selected text with quote")
    func editorCommandEngineWrapSelection() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "value",
            range: NSRange(location: 0, length: 5),
            replacementText: "\"",
            language: .javascript
        )

        #expect(result?.text == "\"value\"")
        #expect(result?.selectedRange == NSRange(location: 7, length: 0))
    }

    @Test("EditorCommandEngine skips duplicate closing brace")
    func editorCommandEngineSkipClosingBrace() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "{}",
            range: NSRange(location: 1, length: 0),
            replacementText: "}",
            language: .javascript
        )

        #expect(result?.text == "{}")
        #expect(result?.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("EditorCommandEngine skips existing closing brace after whitespace")
    func editorCommandEngineSkipClosingBraceAfterWhitespace() {
        let engine = EditorCommandEngine()
        let source = "{\n    \n}"
        let result = engine.transformInput(
            source: source,
            range: NSRange(location: 6, length: 0),
            replacementText: "}",
            language: .javascript
        )

        #expect(result?.text == source)
        #expect(result?.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test("EditorCommandEngine inserts smart newline in brace block")
    func editorCommandEngineSmartNewline() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "{}",
            range: NSRange(location: 1, length: 0),
            replacementText: "\n",
            language: .javascript
        )

        #expect(result?.text == "{\n    \n}")
        #expect(result?.selectedRange == NSRange(location: 6, length: 0))
    }

    @Test("EditorCommandEngine supports repeated smart newline transforms")
    func editorCommandEngineRepeatedSmartNewline() {
        let engine = EditorCommandEngine()
        var source = "{}"
        var selection = NSRange(location: 1, length: 0)

        for _ in 0..<3 {
            guard let result = engine.transformInput(
                source: source,
                range: selection,
                replacementText: "\n",
                language: .javascript
            ) else {
                Issue.record("Smart newline unexpectedly returned nil")
                return
            }
            source = result.text
            selection = result.selectedRange
        }

        #expect(source.contains("\n"))
    }

    @Test("EditorCommandEngine outdents closing brace at line start")
    func editorCommandEngineClosingBraceOutdent() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "    ",
            range: NSRange(location: 4, length: 0),
            replacementText: "}",
            language: .javascript
        )

        #expect(result?.text == "}")
        #expect(result?.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("EditorCommandEngine outdents closing brace by one tab width")
    func editorCommandEngineClosingBraceOutdentWithTabs() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "\t\t",
            range: NSRange(location: 2, length: 0),
            replacementText: "}",
            language: .javascript
        )

        #expect(result?.text == "\t}")
        #expect(result?.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("EditorCommandEngine deletes paired symbols together")
    func editorCommandEnginePairBackspace() {
        let engine = EditorCommandEngine()
        let result = engine.transformInput(
            source: "()",
            range: NSRange(location: 0, length: 1),
            replacementText: "",
            language: .javascript
        )

        #expect(result?.text == "")
        #expect(result?.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test("EditorCommandEngine indents selected lines")
    func editorCommandEngineIndentSelection() {
        let engine = EditorCommandEngine()
        let result = engine.indentSelection(
            source: "a\nb\n",
            selection: NSRange(location: 0, length: 3)
        )

        #expect(result?.text == "    a\n    b\n")
    }

    @Test("EditorCommandEngine indents trailing empty line at document end")
    func editorCommandEngineIndentTrailingEmptyLine() {
        let engine = EditorCommandEngine()
        let source = "a\n"
        let result = engine.indentSelection(
            source: source,
            selection: NSRange(location: source.utf16.count, length: 0)
        )

        #expect(result?.text == "a\n    ")
    }

    @Test("EditorCommandEngine outdents selected lines")
    func editorCommandEngineOutdentSelection() {
        let engine = EditorCommandEngine()
        let result = engine.outdentSelection(
            source: "    a\n    b\n",
            selection: NSRange(location: 0, length: 11)
        )

        #expect(result?.text == "a\nb\n")
    }

    @Test("EditorCommandEngine toggles JavaScript line comments")
    func editorCommandEngineToggleJavaScriptComments() {
        let engine = EditorCommandEngine()
        let source = "let a = 1;\nlet b = 2;\n"

        let first = engine.toggleComment(
            source: source,
            selection: NSRange(location: 0, length: source.utf16.count),
            language: .javascript
        )

        #expect(first?.text == "// let a = 1;\n// let b = 2;\n")

        let second = engine.toggleComment(
            source: first?.text ?? "",
            selection: NSRange(location: 0, length: first?.text.utf16.count ?? 0),
            language: .javascript
        )

        #expect(second?.text == source)
    }

    @Test("EditorCommandEngine toggles CSS block comment")
    func editorCommandEngineToggleCSSComment() {
        let engine = EditorCommandEngine()
        let source = "color: red;\n"

        let first = engine.toggleComment(
            source: source,
            selection: NSRange(location: 0, length: source.utf16.count),
            language: .css
        )

        #expect(first?.text.contains("/*") == true)
        #expect(first?.text.contains("*/") == true)

        let second = engine.toggleComment(
            source: first?.text ?? "",
            selection: NSRange(location: 0, length: first?.text.utf16.count ?? 0),
            language: .css
        )

        #expect(second?.text == source)
    }

    @Test("EditorCommandEngine returns no-op for JSON comments")
    func editorCommandEngineJsonCommentNoop() {
        let engine = EditorCommandEngine()
        let result = engine.toggleComment(
            source: "{\"a\":1}",
            selection: NSRange(location: 0, length: 7),
            language: .json
        )

        #expect(result == nil)
    }

    @Test("EditorCommandEngine auto-pairs quote after URL literal prefix")
    func editorCommandEngineAutoPairQuoteAfterURLLiteral() {
        let engine = EditorCommandEngine()
        let source = "const url = \"https://a\"; const value = "
        let result = engine.transformInput(
            source: source,
            range: NSRange(location: source.utf16.count, length: 0),
            replacementText: "\"",
            language: .javascript
        )

        #expect(result?.text == source + "\"\"")
        #expect(result?.selectedRange == NSRange(location: source.utf16.count + 1, length: 0))
    }

    @Test("EditorCommandEngine suppresses quote auto-pair in template placeholder comments")
    func editorCommandEngineSuppressQuoteAutoPairInTemplatePlaceholderComment() {
        let engine = EditorCommandEngine()
        let source = "const tpl = `${value // comment"
        let result = engine.transformInput(
            source: source,
            range: NSRange(location: source.utf16.count, length: 0),
            replacementText: "\"",
            language: .javascript
        )

        #expect(result == nil)
    }

    @Test("BracketMatcher returns matching pair around caret")
    func bracketMatcherReturnsPair() {
        let source = "function test() { return [1]; }"
        let nsSource = source as NSString
        let braceLocation = nsSource.range(of: "{").location

        let ranges = BracketMatcher.matchedRanges(
            in: source,
            caretUTF16Offset: braceLocation + 1
        )

        #expect(ranges.count == 2)
        #expect(ranges[0].length == 1)
        #expect(ranges[1].length == 1)
    }

    @Test("SyntaxHighlighterEngine returns no tokens for empty source")
    func highlighterReturnsNoTokensForEmptySource() async {
        let engine = SyntaxHighlighterEngine()
        let tokens = await engine.render(source: "", language: .javascript)
        #expect(tokens.isEmpty)
    }

    @Test(
        "SyntaxHighlighterEngine produces highlight tokens for supported languages",
        arguments: [
            (SyntaxLanguage.css, "body { color: red; }"),
            (SyntaxLanguage.javascript, "const answer = 42;"),
            (SyntaxLanguage.json, "{\"enabled\": true, \"count\": 1}"),
        ]
    )
    func highlighterProducesTokens(
        language: SyntaxLanguage,
        source: String
    ) async {
        let engine = SyntaxHighlighterEngine()
        let tokens = await engine.render(source: source, language: language)

        #expect(tokens.isEmpty == false)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine is stable for repeated renders")
    func highlighterRepeatedRenderStability() async {
        let engine = SyntaxHighlighterEngine()
        let source = "const value = 42; const message = 'ok';"

        let first = await engine.render(source: source, language: .javascript)
        let second = await engine.render(source: source, language: .javascript)

        #expect(first.isEmpty == false)
        #expect(first.count == second.count)
    }

    @Test("SyntaxHighlighterEngine returns UTF-16-safe ranges for non-ASCII source")
    func highlighterHandlesNonASCIIRanges() async {
        let engine = SyntaxHighlighterEngine()
        let source = "const label = \"こんにちは😀\";"
        let tokens = await engine.render(source: source, language: .javascript)
        let sourceLength = source.utf16.count

        #expect(tokens.isEmpty == false)
        #expect(tokens.allSatisfy { token in
            token.range.location >= 0 &&
            token.range.length > 0 &&
            token.range.upperBound <= sourceLength
        })
    }

#if canImport(AppKit)
    @Test("SyntaxEditorViewController enables undo support on macOS")
    @MainActor
    func syntaxEditorViewControllerMacUndo() {
        let model = SyntaxEditorModel(text: "{}", language: .javascript)
        let controller = SyntaxEditorViewController(model: model)
        controller.loadViewIfNeeded()

        let textView = controller.textView
        #expect(textView.allowsUndo == true)
    }
#endif
}
