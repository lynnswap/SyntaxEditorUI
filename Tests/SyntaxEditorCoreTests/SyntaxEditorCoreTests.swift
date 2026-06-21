import Foundation
import Observation
import Testing
@testable import SyntaxEditorCore

@Suite("SyntaxEditorCore")
struct SyntaxEditorCoreTests {
    @Test("SyntaxLanguage init(identifier:) maps supported values")
    func syntaxLanguageIdentifierInitializerMapsSupportedValues() {
        #expect(SyntaxLanguage(identifier: "plain")?.identifier == SyntaxLanguage.plainText.identifier)
        #expect(SyntaxLanguage(identifier: "plaintext")?.identifier == SyntaxLanguage.plainText.identifier)
        #expect(SyntaxLanguage(identifier: "plain-text")?.identifier == SyntaxLanguage.plainText.identifier)
        #expect(SyntaxLanguage(identifier: "text")?.identifier == SyntaxLanguage.plainText.identifier)
        #expect(SyntaxLanguage(identifier: "txt")?.identifier == SyntaxLanguage.plainText.identifier)
        #expect(SyntaxLanguage(identifier: "text/plain")?.identifier == SyntaxLanguage.plainText.identifier)
        #expect(SyntaxLanguage(identifier: "css")?.identifier == SyntaxLanguage.css.identifier)
        #expect(SyntaxLanguage(identifier: "html")?.identifier == SyntaxLanguage.html.identifier)
        #expect(SyntaxLanguage(identifier: "HTM")?.identifier == SyntaxLanguage.html.identifier)
        #expect(SyntaxLanguage(identifier: " javascript ")?.identifier == SyntaxLanguage.javascript.identifier)
        #expect(SyntaxLanguage(identifier: "JS")?.identifier == SyntaxLanguage.javascript.identifier)
        #expect(SyntaxLanguage(identifier: "JSON")?.identifier == SyntaxLanguage.json.identifier)
        #expect(SyntaxLanguage(identifier: "objective-c")?.identifier == SyntaxLanguage.objectiveC.identifier)
        #expect(SyntaxLanguage(identifier: "objectivec")?.identifier == SyntaxLanguage.objectiveC.identifier)
        #expect(SyntaxLanguage(identifier: "objc")?.identifier == SyntaxLanguage.objectiveC.identifier)
        #expect(SyntaxLanguage(identifier: "Swift")?.identifier == SyntaxLanguage.swift.identifier)
        #expect(SyntaxLanguage(identifier: "toml")?.identifier == SyntaxLanguage.toml.identifier)
        #expect(SyntaxLanguage(identifier: "xml")?.identifier == SyntaxLanguage.xml.identifier)
    }

    @Test("SyntaxLanguage init(identifier:) rejects unsupported values")
    func syntaxLanguageIdentifierInitializerRejectsUnsupportedValue() {
        #expect(SyntaxLanguage(identifier: "yaml") == nil)
    }

    @Test("SyntaxEditorModel stores and mutates editor state on MainActor")
    @MainActor
    func syntaxEditorModelState() {
        let model = SyntaxEditorModel(text: "{}", language: SyntaxLanguage.json)

        #expect(model.text == "{}")
        #expect(model.language.identifier == SyntaxLanguage.json.identifier)
        #expect(model.isEditable == true)
        #expect(model.lineWrappingEnabled == false)
        #expect(model.theme == .default)
        #expect(model.drawsBackground == true)
        #expect(model.fontSizeDelta == 0)

        model.replaceText("body { color: red; }")
        model.language = SyntaxLanguage.css
        model.isEditable = false
        model.lineWrappingEnabled = true
        model.drawsBackground = false
        model.increaseFontSize()
        model.increaseFontSize()
        model.decreaseFontSize()

        #expect(model.text == "body { color: red; }")
        #expect(model.textRevision == 1)
        #expect(model.language.identifier == SyntaxLanguage.css.identifier)
        #expect(model.isEditable == false)
        #expect(model.lineWrappingEnabled == true)
        #expect(model.theme == .default)
        #expect(model.drawsBackground == false)
        #expect(model.fontSizeDelta == 1)

        model.resetFontSize()
        #expect(model.fontSizeDelta == 0)
    }

    @Test("SyntaxEditorModel replaces text and language together")
    @MainActor
    func syntaxEditorModelReplacesContents() {
        let model = SyntaxEditorModel(
            text: "let",
            language: SyntaxLanguage.swift,
            selectedRange: NSRange(location: 1, length: 0)
        )

        let languageOnlyChange = model.replaceContents(
            text: "let",
            language: SyntaxLanguage.json,
            selectedRange: NSRange(location: 2, length: 0)
        )
        #expect(languageOnlyChange == nil)
        #expect(model.text == "let")
        #expect(model.language == SyntaxLanguage.json)
        #expect(model.selectedRange == NSRange(location: 2, length: 0))
        #expect(model.textRevision == 0)
        #expect(model.latestTextChange == nil)

        let textChange = model.replaceContents(
            text: "body { color: red; }",
            language: SyntaxLanguage.css,
            selectedRange: NSRange(location: 4, length: 0)
        )
        #expect(textChange?.kind == .wholeDocumentReplacement)
        #expect(textChange?.textRevision == 1)
        #expect(model.text == "body { color: red; }")
        #expect(model.language == SyntaxLanguage.css)
        #expect(model.selectedRange == NSRange(location: 4, length: 0))
        #expect(model.textRevision == 1)
        #expect(model.latestTextChange?.textRevision == 1)

        let secondLanguageOnlyChange = model.replaceContents(
            text: "body { color: red; }",
            language: SyntaxLanguage.javascript
        )
        #expect(secondLanguageOnlyChange == nil)
        #expect(model.language == SyntaxLanguage.javascript)
        #expect(model.textRevision == 1)
        #expect(model.latestTextChange?.textRevision == 1)
    }

    @Test("SyntaxEditorModel defaults to JavaScript")
    @MainActor
    func syntaxEditorModelDefaultsToJavaScript() {
        let model = SyntaxEditorModel()

        #expect(model.language == .javascript)
        #expect(SyntaxLanguage.allCases.contains(.plainText))
        #expect(SyntaxLanguage.syntaxHighlightedCases.contains(.plainText) == false)
    }

    @Test("SyntaxEditorModel font size commands clamp at rendered bounds")
    @MainActor
    func syntaxEditorModelFontSizeCommandsClampAtRenderedBounds() {
        let model = SyntaxEditorModel(theme: .presentationLarge)
        let basePointSize = model.theme.resolved(for: model.language).base.font.size
        let minimumDelta = Int(ceil(SyntaxEditorTheme.FontSize.minimum - basePointSize))
        let maximumDelta = Int(floor(SyntaxEditorTheme.FontSize.maximum - basePointSize))

        for _ in 0..<100 {
            model.increaseFontSize()
        }
        #expect(model.fontSizeDelta == maximumDelta)

        model.increaseFontSize()
        #expect(model.fontSizeDelta == maximumDelta)

        model.decreaseFontSize()
        #expect(model.fontSizeDelta == maximumDelta - 1)

        for _ in 0..<100 {
            model.decreaseFontSize()
        }
        #expect(model.fontSizeDelta == minimumDelta)

        model.decreaseFontSize()
        #expect(model.fontSizeDelta == minimumDelta)

        model.increaseFontSize()
        #expect(model.fontSizeDelta == minimumDelta + 1)
    }

    @Test("SyntaxEditorModel font size commands recover from explicit overshoot")
    @MainActor
    func syntaxEditorModelFontSizeCommandsRecoverFromExplicitOvershoot() {
        let model = SyntaxEditorModel(theme: .presentationLarge, fontSizeDelta: 100)
        let basePointSize = model.theme.resolved(for: model.language).base.font.size
        let minimumDelta = Int(ceil(SyntaxEditorTheme.FontSize.minimum - basePointSize))
        let maximumDelta = Int(floor(SyntaxEditorTheme.FontSize.maximum - basePointSize))

        model.decreaseFontSize()
        #expect(model.fontSizeDelta == maximumDelta - 1)

        model.fontSizeDelta = -100
        model.increaseFontSize()
        #expect(model.fontSizeDelta == minimumDelta + 1)
    }

    @Test("SyntaxEditorModel text participates in observation")
    @MainActor
    func syntaxEditorModelTextObservation() {
        let model = SyntaxEditorModel(text: "let value = 1")
        var observedText = ""
        let didChange = DispatchSemaphore(value: 0)

        withObservationTracking {
            observedText = model.text
        } onChange: {
            didChange.signal()
        }

        model.replaceText("let value = 2")

        #expect(observedText == "let value = 1")
        #expect(didChange.wait(timeout: .now()) == .success)
    }

    @Test("SyntaxEditorHighlightTheme maps representative captures to theme slots")
    func syntaxEditorHighlightThemeMapping() {
        let theme = SyntaxEditorTheme.default
        let resolved = theme.resolved(for: .swift, appearance: .light)
        let custom = SyntaxEditorTheme(
            baseForeground: .syntaxEditorColor(.init(red: 1, green: 1, blue: 1, alpha: 1)),
            bracketBackground: .syntaxEditorColor(.init(red: 0, green: 0, blue: 0, alpha: 1)),
            comment: .syntaxEditorColor(.init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)),
            string: .syntaxEditorColor(.init(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)),
            keyword: .syntaxEditorColor(.init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)),
            number: .syntaxEditorColor(.init(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)),
            function: .syntaxEditorColor(.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
            type: .syntaxEditorColor(.init(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)),
            constant: .syntaxEditorColor(.init(red: 0.7, green: 0.7, blue: 0.7, alpha: 1)),
            variable: .syntaxEditorColor(.init(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)),
            punctuation: .syntaxEditorColor(.init(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)),
            font: SyntaxEditorTheme.Font.monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        let customResolved = custom.resolved(for: .swift, appearance: .light)

        #expect(SyntaxEditorHighlightTheme.color(for: .keyword, in: theme, language: .swift, appearance: .light) == resolved.keyword.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .string, in: theme, language: .swift, appearance: .light) == resolved.string.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .plain, in: theme, language: .swift, appearance: .light) == resolved.base.foreground)
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(for: .identifierTypeSystem, language: .swift)?.first == "editor.syntax.identifier.type.system")
        #expect(SyntaxEditorHighlightTheme.color(for: .number, in: theme, language: .swift, appearance: .light) == resolved.number.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .declarationType, in: custom, language: .swift, appearance: .light) == customResolved.type.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .declarationOther, in: custom, language: .swift, appearance: .light) == customResolved.function.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .identifierFunctionSystem, in: custom, language: .swift, appearance: .light) == customResolved.function.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .identifierConstantSystem, in: custom, language: .swift, appearance: .light) == customResolved.constant.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .identifierVariableSystem, in: custom, language: .swift, appearance: .light) == customResolved.variable.foreground)
        #expect(SyntaxEditorHighlightTheme.color(for: .identifier, in: custom, language: .swift, appearance: .light) == nil)
        #expect(SyntaxEditorHighlightTheme.color(for: .plain, in: custom, language: .swift, appearance: .light) == nil)
        #expect(SyntaxEditorHighlightTheme.color(for: "unknown.capture", in: theme, language: .swift, appearance: .light) == nil)
    }

    @Test("SyntaxEditorHighlightTheme resolves language-specific built-in styles")
    func syntaxEditorHighlightThemeLanguageSpecificStyles() {
        let theme = SyntaxEditorTheme.default
        let swiftStyle = SyntaxEditorHighlightTheme.style(
            for: .plain,
            in: theme,
            language: .swift,
            appearance: .light
        )
        let swiftResolved = theme.resolved(for: .swift, appearance: .light)
        #expect(swiftStyle?.foreground == swiftResolved.baseForeground)

        let objectiveCStyle = SyntaxEditorHighlightTheme.style(
            for: .plain,
            in: theme,
            language: .objectiveC,
            appearance: .light
        )
        let objectiveCResolved = theme.resolved(for: .objectiveC, appearance: .light)
        #expect(objectiveCStyle?.foreground == objectiveCResolved.baseForeground)
    }

    @Test("EditorSourceSyntax.Capture parses canonical captures and falls back for non-canonical names")
    func editorSyntaxCaptureParser() {
        let swiftKeyword = EditorSourceSyntax.Capture.parse(
            rawCaptureName: "editor.syntax.swift.keyword",
            rootLanguage: .html
        )
        #expect(swiftKeyword.syntaxID == .keyword)
        #expect(swiftKeyword.language == .swift)

        let objectiveCType = EditorSourceSyntax.Capture.parse(
            rawCaptureName: "@editor.syntax.objectivec.identifier.type.system",
            rootLanguage: .swift
        )
        #expect(objectiveCType.syntaxID == .identifierTypeSystem)
        #expect(objectiveCType.language == .objectiveC)

        let fallback = EditorSourceSyntax.Capture.parse(rawCaptureName: "keyword", rootLanguage: .swift)
        #expect(fallback.syntaxID == .plain)
        #expect(fallback.language == .swift)
    }

    @Test("Built-in highlight queries use canonical editor syntax captures")
    func builtInHighlightQueriesUseCanonicalCaptures() throws {
        for language in SyntaxLanguage.syntaxHighlightedCases {
            let source = try String(contentsOf: highlightQueryURL(language: language), encoding: .utf8)
            let captures = captureNames(inQuerySource: source)
            let prefix = "editor.syntax.\(canonicalCaptureLanguageName(for: language))."
            #expect(captures.isEmpty == false, "No captures found for \(language.rawValue)")

            for capture in captures {
                #expect(capture.hasPrefix(prefix), "Non-canonical capture @\(capture) in \(language.rawValue)")
                let classification = EditorSourceSyntax.Capture.parse(
                    rawCaptureName: capture,
                    rootLanguage: language
                )
                #expect(classification.language == language)
                #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(
                    for: classification.syntaxID,
                    language: classification.language
                )?.isEmpty == false)
                #expect(SyntaxEditorHighlightTheme.style(
                    for: classification.syntaxID,
                    in: .default,
                    language: classification.language,
                    appearance: .dark
                ) != nil)
            }
        }
    }

    @Test("Editor syntax style keys stay query-owned")
    func editorSyntaxStyleKeysStayQueryOwned() throws {
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(for: "attribute", language: .toml)?.first == "editor.syntax.attribute")
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(for: "plain", language: .toml)?.first == "editor.syntax.plain")
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(for: "keyword", language: .css)?.first == "editor.syntax.keyword")
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(for: "keyword", language: .html)?.first == "editor.syntax.keyword")
    }

    @Test("Language source files live in language-specific directories")
    func languageSourceFilesLiveInLanguageSpecificDirectories() {
        let languagesURL = repositoryRootURL()
            .appendingPathComponent("Sources/SyntaxEditorCore/Languages", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: languagesURL.appendingPathComponent("Builtin").path))
        #expect(!FileManager.default.fileExists(atPath: languagesURL.appendingPathComponent("Generated").path))
        #expect(!FileManager.default.fileExists(atPath: languagesURL.appendingPathComponent("Support").path))

        for language in SyntaxLanguage.allCases {
            let directoryName = languageImplementationDirectoryName(for: language)
            let typeName = switch language {
            case .plainText:
                "PlainTextLanguage"
            case .css:
                "CSSLanguage"
            case .html:
                "HTMLLanguage"
            case .javascript:
                "JavaScriptLanguage"
            case .json:
                "JSONLanguage"
            case .objectiveC:
                "ObjectiveCLanguage"
            case .swift:
                "SwiftLanguage"
            case .toml:
                "TOMLLanguage"
            case .xml:
                "XMLLanguage"
            }
            let languageDirectory = languagesURL.appendingPathComponent(directoryName, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: languageDirectory.appendingPathComponent("\(typeName).swift").path))
        }
    }

    @Test("SyntaxEditorHighlightTheme exposes exact semantic style keys")
    func syntaxEditorHighlightThemeExposesExactSemanticStyleKeys() throws {
        #expect(
            SyntaxEditorHighlightTheme.semanticStyleKeys(
                for: "xcode.syntax.keyword"
            )?.first == "editor.syntax.keyword"
        )
        #expect(
            SyntaxEditorHighlightTheme.semanticStyleKeys(
                for: "xcode.syntax.preprocessor"
            )?.first == "editor.syntax.preprocessor"
        )
        #expect(
            SyntaxEditorHighlightTheme.semanticStyleKeys(
                for: "xcode.syntax.preprocessor.define"
            )?.first == "editor.syntax.preprocessor.define"
        )
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(for: "xcode.syntax.declaration.precedencegroup") == nil)
        #expect(
            SyntaxEditorHighlightTheme.semanticStyleKeys(
                for: "xcode.syntax.definition.style"
            )?.first == "editor.syntax.definition.style"
        )
        #expect(
            SyntaxEditorHighlightTheme.semanticStyleKeys(
                for: "xcode.syntax.markup.aside.kind"
            )?.first == "editor.syntax.markup.aside.kind"
        )
        #expect(
            SyntaxEditorHighlightTheme.semanticStyleKeys(
                for: "xcode.syntax.definition.macro",
                language: .swift
            )?.first == "editor.syntax.definition.macro"
        )
        #expect(SyntaxEditorHighlightTheme.semanticStyleKeys(
            for: "xcode.syntax.not-a-real-syntax-id",
            language: .swift
        ) == nil)
    }

    @Test("SyntaxEditorHighlightTheme resolves built-in fonts")
    func syntaxEditorHighlightThemeFonts() {
        let theme = SyntaxEditorTheme.default
        let lightComment = SyntaxEditorHighlightTheme.style(
            for: "comment.doc",
            in: theme,
            language: .swift,
            appearance: .light
        )
        #expect(lightComment?.font.family == "HelveticaNeue")
        #expect(lightComment?.font.size == 12 + SyntaxEditorTheme.FontSize.platformThemePointSizeAdjustment)

        let darkKeyword = SyntaxEditorHighlightTheme.style(
            for: "keyword.control",
            in: theme,
            language: .swift,
            appearance: .dark
        )
        #expect(darkKeyword?.font.weight == .bold)
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

    @Test("SyntaxEditorTextChange.Replacement returns nil when text does not change")
    func textMutationNoChange() {
        #expect(SyntaxEditorTextChange.Replacement.singleReplacement(from: "body {}", to: "body {}") == nil)
    }

    @Test("SyntaxEditorTextChange.Replacement computes insertion range for newline")
    func textMutationInsertionRange() {
        let mutation = SyntaxEditorTextChange.Replacement.singleReplacement(from: "a\nb", to: "a\n\nb")
        #expect(mutation?.range == NSRange(location: 2, length: 0))
        #expect(mutation?.replacement == "\n")
    }

    @Test("SyntaxEditorTextChange.Replacement computes replacement range for comment toggle")
    func textMutationReplacementRange() {
        let mutation = SyntaxEditorTextChange.Replacement.singleReplacement(
            from: "let value = 1;\n",
            to: "// let value = 1;\n"
        )
        #expect(mutation?.range == NSRange(location: 0, length: 0))
        #expect(mutation?.replacement == "// ")
    }

    @Test("SyntaxEditorTextChange.Replacement keeps prefix attributes when applying mutation")
    func textMutationPreservesPrefixAttributes() {
        let oldText = "/* comment */\nbody {\n}"
        let newText = "/* comment */\nbody {\n    \n}"
        guard let mutation = SyntaxEditorTextChange.Replacement.singleReplacement(from: oldText, to: newText) else {
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

    @Test("LineMetricsIndex indexes long offscreen lines")
    func lineMetricsIndexInitialLongLineWidth() {
        let source = "short\n\(String(repeating: "x", count: 120))\nmid"
        let index = LineMetricsIndex(source: source, tabWidth: 4)

        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 120)
        #expect(index.horizontalDocumentWidth(columnWidth: 2, textContainerInset: 10, lineFragmentPadding: 5) == 260)
    }

    @Test("LineMetricsIndex estimates wrapped visual line counts")
    func lineMetricsIndexEstimatesWrappedLineCount() {
        let index = LineMetricsIndex(source: "1234567890\nabc\n", tabWidth: 4)

        #expect(index.estimatedWrappedLineCount(maxColumnsPerLine: 4) == 5)
        #expect(index.estimatedWrappedLineCount(maxColumnsPerLine: 20) == 3)
    }

    @Test("LineMetricsIndex updates edited line ranges without full rebuild")
    func lineMetricsIndexIncrementalEdits() {
        var source = "abc\nabcdef"
        let index = LineMetricsIndex(source: source, tabWidth: 4)
        let initialRebuildCount = index.fullRebuildCount

        func apply(_ edit: SyntaxEditorTextChange.Replacement) {
            index.apply(edits: [edit], previousSource: source)
            source = SyntaxEditorModel.applying([edit], to: source)
        }

        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 6)

        apply(SyntaxEditorTextChange.Replacement(range: NSRange(location: 1, length: 0), replacement: "Z"))
        #expect(source == "aZbc\nabcdef")
        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 6)

        apply(SyntaxEditorTextChange.Replacement(range: NSRange(location: 4, length: 0), replacement: "\nwide-line"))
        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 9)

        let maxLineRange = (source as NSString).range(of: "wide-line")
        apply(SyntaxEditorTextChange.Replacement(range: maxLineRange, replacement: "w"))
        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 6)

        let pasteLocation = source.utf16.count
        apply(SyntaxEditorTextChange.Replacement(range: NSRange(location: pasteLocation, length: 0), replacement: "\n1234567890"))
        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 10)
        #expect(index.fullRebuildCount == initialRebuildCount)
    }

    @Test("LineMetricsIndex does not accumulate heap entries for repeated same-width edits")
    func lineMetricsIndexKeepsMaxColumnCacheBounded() {
        var source = "a"
        let index = LineMetricsIndex(source: source, tabWidth: 4)

        for iteration in 0..<100 {
            let replacement = iteration.isMultiple(of: 2) ? "b" : "a"
            let edit = SyntaxEditorTextChange.Replacement(
                range: NSRange(location: 0, length: 1),
                replacement: replacement
            )
            index.apply(edits: [edit], previousSource: source)
            source = SyntaxEditorModel.applying([edit], to: source)
            #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 1)
        }

        #expect(index.cachedMaxColumnEntryCountForTesting == 1)
    }

    @Test("LineMetricsIndex prunes stale heap entries below the maximum")
    func lineMetricsIndexPrunesStaleHeapEntriesBelowMaximum() {
        var source = "\(String(repeating: "x", count: 200))\nshort"
        let index = LineMetricsIndex(source: source, tabWidth: 4)

        for width in 1...80 {
            let lineBreakRange = (source as NSString).range(of: "\n")
            let lineStart = lineBreakRange.location + lineBreakRange.length
            let edit = SyntaxEditorTextChange.Replacement(
                range: NSRange(location: lineStart, length: source.utf16.count - lineStart),
                replacement: String(repeating: "y", count: width)
            )
            index.apply(edits: [edit], previousSource: source)
            source = SyntaxEditorModel.applying([edit], to: source)

            #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 200)
        }

        #expect(index.cachedMaxColumnEntryCountForTesting == 2)
    }

    @Test("LineMetricsIndex removes trailing empty line after deleting final newline")
    func lineMetricsIndexHandlesFinalNewlineDeletion() {
        var source = "abc\n"
        let index = LineMetricsIndex(source: source, tabWidth: 4)
        let edit = SyntaxEditorTextChange.Replacement(
            range: NSRange(location: source.utf16.count - 1, length: 1),
            replacement: ""
        )

        index.apply(edits: [edit], previousSource: source)
        source = SyntaxEditorModel.applying([edit], to: source)

        #expect(source == "abc")
        #expect(index.lineCountForTesting == 1)
        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == 3)
    }

    @Test("LineMetricsIndex matches display column rules for tabs and Unicode")
    func lineMetricsIndexMatchesDisplayColumnRules() {
        let source = "a\tあ\u{200D}b\nplain"
        let index = LineMetricsIndex(source: source, tabWidth: 4)
        let expected = SyntaxEditorDisplayColumnUtilities.maximumColumnCount(in: source, tabWidth: 4)

        #expect(index.horizontalDocumentWidth(columnWidth: 1, textContainerInset: 0, lineFragmentPadding: 0) == CGFloat(expected))
    }

    @Test("LineTokenPlanes preserves later line tokens without suffix shifting")
    func lineTokenPlanesPreservesLaterLinesAcrossPrefixInsertion() {
        let source = "first\nsecond\nthird"
        let updatedSource = "prefix\n" + source
        let mutation = SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: "prefix\n")
        let lineTable = HighlightLineTable()
        lineTable.reset(source: source)
        let planes = LineTokenPlanes(styles: HighlightStyleTable())
        let secondRange = (source as NSString).range(of: "second")
        planes.reset(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: secondRange,
                    syntaxID: .plain,
                    language: .swift,
                    rawCaptureName: "editor.syntax.swift.plain"
                ),
            ],
            lineTable: lineTable
        )

        _ = planes.applyEdit(mutation, previousSource: source, lineTable: lineTable)
        lineTable.apply(mutation: mutation, previousSource: source)

        #expect(planes.tokens(lineTable: lineTable).map(\.range) == [(updatedSource as NSString).range(of: "second")])
    }

    @Test("LineTokenPlanes materializes pushed prefix lines after replacement")
    func lineTokenPlanesMaterializesPushedPrefixLines() {
        let source = "first\nsecond\nthird"
        let prefix = "prefix\n"
        let updatedSource = prefix + source
        let mutation = SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: prefix)
        let lineTable = HighlightLineTable()
        lineTable.reset(source: source)
        let planes = LineTokenPlanes(styles: HighlightStyleTable())
        planes.reset(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: (source as NSString).range(of: "second"),
                    syntaxID: .plain,
                    language: .swift,
                    rawCaptureName: "editor.syntax.swift.plain"
                ),
            ],
            lineTable: lineTable
        )

        _ = planes.applyEdit(mutation, previousSource: source, lineTable: lineTable)
        lineTable.apply(mutation: mutation, previousSource: source)
        let replacementRange = (updatedSource as NSString).lineRange(
            for: NSRange(location: 0, length: prefix.utf16.count + 1)
        )
        _ = planes.replaceTokens(
            in: replacementRange,
            with: [
                SyntaxEditorHighlighting.Token(
                    range: (updatedSource as NSString).range(of: "first"),
                    syntaxID: .keyword,
                    language: .swift,
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            plane: .both,
            lineTable: lineTable
        )

        #expect(planes.tokens(lineTable: lineTable).map(\.range) == [
            (updatedSource as NSString).range(of: "first"),
            (updatedSource as NSString).range(of: "second"),
        ])
    }

    @Test("LineTokenPlanes returns full multi-line tokens for partial reads")
    func lineTokenPlanesReturnsFullMultilineTokensForPartialReads() {
        let source = "let text = \"\"\"\nhello\n\"\"\"\nlet next = 1\n"
        let nsSource = source as NSString
        let lineTable = HighlightLineTable()
        lineTable.reset(source: source)
        let planes = LineTokenPlanes(styles: HighlightStyleTable())
        let multilineStringRange = nsSource.range(of: "\"\"\"\nhello\n\"\"\"")
        planes.reset(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: multilineStringRange,
                    syntaxID: .string,
                    language: .swift,
                    rawCaptureName: "editor.syntax.swift.string"
                ),
            ],
            lineTable: lineTable
        )

        let middleLineRange = nsSource.range(of: "hello")

        #expect(planes.tokens(in: middleLineRange, lineTable: lineTable).map(\.range) == [
            multilineStringRange,
        ])
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
}
