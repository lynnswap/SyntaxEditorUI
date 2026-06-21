#if canImport(AppKit)
import Foundation
import Observation
import ObservationBridge
import SwiftUI
import Testing
import AppKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit

extension SyntaxEditorUITests {
    @Test("SyntaxEditorView reflects custom macOS theme")
    @MainActor
    func syntaxEditorViewMacThemeObservation() async {
        let source = "let value = \"text\""
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter()
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: initialTheme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), initialTheme.baseForeground))

        model.model.theme = updatedTheme

        editorView.synchronizeDocumentForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground))
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground))
    }

    @Test("SyntaxEditorView refreshes macOS permanent base foreground after appearance changes")
    @MainActor
    func syntaxEditorViewMacRefreshesPermanentBaseForegroundAfterAppearanceChanges() throws {
        let model = SyntaxEditorTestContext(
            text: "plain text",
            language: SyntaxLanguage.swift,
            theme: .default
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())

        editorView.appearance = NSAppearance(named: .aqua)
        editorView.viewDidChangeEffectiveAppearance()
        let lightForeground = try #require(macEditorPermanentForegroundColor(editorView, at: 0))

        editorView.appearance = NSAppearance(named: .darkAqua)
        editorView.viewDidChangeEffectiveAppearance()
        let darkBaseForeground = try #require(editorView.baseForegroundColorForTesting())

        #expect(syntaxEditorUITestColorsEqual(macEditorPermanentForegroundColor(editorView, at: 0), darkBaseForeground))
        #expect(!syntaxEditorUITestColorsEqual(lightForeground, darkBaseForeground))
    }

    @Test("SyntaxEditorView reflects macOS background drawing configuration")
    @MainActor
    func syntaxEditorViewMacDrawsBackgroundObservation() async {
        let background = syntaxEditorUITestColor(hex: 0x112233)
        let theme = syntaxEditorUITestTheme(background: background)
        let model = SyntaxEditorTestContext(
            text: "let value = 1",
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())
        guard let delivery = editorView.modelConfigurationDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorView to expose its production configuration delivery")
            return
        }
        let stopsDrawingBackground = await delivery.values {
            editorView.drawsBackground == false
                && editorView.textView.drawsBackground == false
                && syntaxEditorUITestColorsEqual(editorView.backgroundColor, background)
                && syntaxEditorUITestColorsEqual(editorView.textView.backgroundColor, background)
        }

        #expect(editorView.drawsBackground)
        #expect(!editorView.textView.drawsBackground)
        #expect(syntaxEditorUITestColorsEqual(editorView.backgroundColor, background))
        #expect(syntaxEditorUITestColorsEqual(editorView.textView.backgroundColor, background))

        model.model.drawsBackground = false

        #expect(await stopsDrawingBackground.waitUntilValue(true))
    }

    @Test("SyntaxEditorView resets nested empty-style macOS tokens to the base theme")
    @MainActor
    func syntaxEditorViewMacResetsNestedEmptyStyleTokensToBaseTheme() async {
        let source = "\"${value}\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.javascript.string"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 3, length: 5),
                    rawCaptureName: "editor.syntax.javascript.plain"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), theme.baseForeground))
    }

    @Test("SyntaxEditorView resets multi-level empty-style macOS tokens to the base theme")
    @MainActor
    func syntaxEditorViewMacResetsMultiLevelEmptyStyleTokensToBaseTheme() async {
        let source = "0123456789"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0x654321),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 10),
                    rawCaptureName: "editor.syntax.javascript.keyword"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 2, length: 6),
                    rawCaptureName: "editor.syntax.javascript.string"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 4, length: 2),
                    rawCaptureName: "editor.syntax.javascript.plain"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 2), theme.string))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 6), theme.string))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 8), theme.keyword))
    }

    @Test("SyntaxEditorView reapplies macOS same-style tokens after empty-style splits")
    @MainActor
    func syntaxEditorViewMacReappliesSameStyleTokensAfterEmptyStyleSplits() async {
        let source = "\"${value}\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.javascript.string"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 3, length: 4),
                    rawCaptureName: "editor.syntax.javascript.plain"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 6, length: 4),
                    rawCaptureName: "editor.syntax.javascript.string"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 6), theme.string))
    }

    @Test("SyntaxEditorView keeps macOS empty-style gaps between separated same-style runs")
    @MainActor
    func syntaxEditorViewMacKeepsEmptyStyleGapsBetweenSeparatedSameStyleRuns() async {
        let source = "\"${value}\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.javascript.string"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 4, length: 2),
                    rawCaptureName: "editor.syntax.javascript.plain"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 4, length: 1),
                    rawCaptureName: "editor.syntax.javascript.string"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.string))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 5), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 6), theme.string))
    }

    @Test("SyntaxEditorView reapplies cached macOS syntax colors without highlighting")
    @MainActor
    func syntaxEditorViewMacThemeReusesCachedHighlightTokens() async {
        let source = "let value = \"text\""
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x654321),
            keyword: syntaxEditorUITestColor(hex: 0x876543)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: initialTheme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), initialTheme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), initialTheme.baseForeground))

        model.model.theme = updatedTheme

        editorView.synchronizeDocumentForTesting()
        #expect(
            syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.keyword)
                && syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground)
        )
        await editorView.waitForPendingHighlightForTesting()
        #expect(await highlighter.callCount() == initialCallCount)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground))
    }

    @Test("SyntaxEditorView refreshes macOS syntax colors when theme changes after incremental edits")
    @MainActor
    func syntaxEditorViewMacThemeRefreshesAfterIncrementalEditDropsCachedTokens() async {
        let source = "let value = \"text\""
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x876543)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: initialTheme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), initialTheme.keyword))

        editorView.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        editorView.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        await editorView.waitForPendingHighlightForTesting()
        let editedCallCount = await highlighter.callCount()
        #expect(editedCallCount == initialCallCount + 1)

        model.model.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(await highlighter.callCount() == editedCallCount + 1)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
    }

    @Test("SyntaxEditorView preserves macOS syntax colors after editor state changes")
    @MainActor
    func syntaxEditorViewMacEditorStateDoesNotResetSyntaxColors() async {
        let source = "let value = \"text\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model)

        editorView.textView.textStorage?.addAttribute(
            .foregroundColor,
            value: theme.keyword,
            range: NSRange(location: 0, length: 3)
        )
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        model.model.lineWrappingEnabled = true

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.hasHorizontalScroller == false)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        model.model.isEditable = false

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.isEditable == false)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView preserves cached macOS syntax colors after font size delta changes")
    @MainActor
    func syntaxEditorViewMacFontSizeDeltaPreservesCachedHighlightTokens() async throws {
        let source = "let value = \"text\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()
        let initialFont = try #require(macEditorFont(editorView, at: 0))

        model.model.fontSizeDelta = 4
        editorView.synchronizeDocumentForTesting()

        #expect(await highlighter.callCount() == initialCallCount)
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 3))
        #expect(abs(highlightedFont.pointSize - (initialFont.pointSize + 4)) < 0.01)
        #expect(abs(plainFont.pointSize - highlightedFont.pointSize) < 0.01)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), theme.baseForeground))
    }

    @Test("SyntaxEditorView applies built-in macOS theme fonts after theme changes")
    @MainActor
    func syntaxEditorViewMacAppliesBuiltInThemeFontsAfterThemeChanges() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .default
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()

        model.model.theme = .presentationLarge
        editorView.synchronizeDocumentForTesting()

        #expect(await highlighter.callCount() == initialCallCount)
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - 28) < 0.01)
        #expect(abs(plainFont.pointSize - 28) < 0.01)
    }

    @Test("SyntaxEditorView keeps macOS syntax fonts out of TextKit storage")
    @MainActor
    func syntaxEditorViewMacSyntaxFontsUseRenderingAttributes() async throws {
        let source = "/// doc"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.comment.doc"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .civic
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        editorView.appearance = NSAppearance(named: .aqua)
        editorView.viewDidChangeEffectiveAppearance()

        await editorView.waitForPendingHighlightForTesting()

        let renderedFont = try #require(macEditorFont(editorView, at: 0))
        let highlightedStorageFont = try #require(
            editorView.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let plainStorageFont = try #require(
            editorView.textView.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        )
        #expect(!syntaxEditorUITestFontsEqual(renderedFont, highlightedStorageFont))
        #expect(syntaxEditorUITestFontsEqual(highlightedStorageFont, plainStorageFont))
    }

    @Test("SyntaxEditorView applies macOS theme fonts while selection delays highlight")
    @MainActor
    func syntaxEditorViewMacThemeFontUpdatesSelectedTextBeforeDelayedHighlight() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .default
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 3))
        model.model.theme = .presentationLarge
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.textView.selectedRange() == NSRange(location: 0, length: 3))
        #expect(await highlighter.callCount() == initialCallCount)
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - 28) < 0.01)
        #expect(abs(plainFont.pointSize - 28) < 0.01)

        editorView.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )

        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: 0),
                SyntaxEditorTheme.presentationLarge.keyword
            )
        )
    }

    @Test("SyntaxEditorView applies macOS token fonts while selection delays theme highlight")
    @MainActor
    func syntaxEditorViewMacThemeTokenFontUpdatesSelectedTextBeforeDelayedHighlight() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.comment.doc"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: "",
            language: SyntaxLanguage.swift,
            theme: .default
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        editorView.appearance = NSAppearance(named: .aqua)
        editorView.viewDidChangeEffectiveAppearance()
        model.model.replaceText(source)
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()
        let initialHighlightedFont = try #require(macEditorFont(editorView, at: 0))
        let initialPlainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(!syntaxEditorUITestFontsEqual(initialHighlightedFont, initialPlainFont))

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 3))
        model.model.theme = .civic
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.textView.selectedRange() == NSRange(location: 0, length: 3))
        #expect(await highlighter.callCount() == initialCallCount)
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(syntaxEditorUITestFontsEqual(plainFont, initialPlainFont))
        #expect(!syntaxEditorUITestFontsEqual(highlightedFont, initialHighlightedFont))
        #expect(!syntaxEditorUITestFontsEqual(highlightedFont, plainFont))
    }

    @Test("SyntaxEditorView applies macOS font size delta while selection delays highlight")
    @MainActor
    func syntaxEditorViewMacFontSizeDeltaUpdatesSelectedTextBeforeDelayedHighlight() async throws {
        let source = "let value = \"text\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let initialCallCount = await highlighter.callCount()
        let initialHighlightedFont = try #require(macEditorFont(editorView, at: 0))
        let initialPlainFont = try #require(macEditorFont(editorView, at: 3))

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 3))
        model.model.fontSizeDelta = 4
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.textView.selectedRange() == NSRange(location: 0, length: 3))
        #expect(await highlighter.callCount() == initialCallCount)
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 3))
        #expect(abs(highlightedFont.pointSize - (initialHighlightedFont.pointSize + 4)) < 0.01)
        #expect(abs(plainFont.pointSize - (initialPlainFont.pointSize + 4)) < 0.01)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), theme.baseForeground))
    }

    @Test("SyntaxEditorView applies macOS base attributes before delayed highlight")
    @MainActor
    func syntaxEditorViewMacAppliesBaseAttributesBeforeDelayedHighlight() async throws {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            resetGate: resetGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let baseFont = try #require(editorView.textView.font)

        await resetGate.waitUntilSuspended()
        #expect(syntaxEditorUITestFontsEqual(macEditorFont(editorView, at: 0), baseFont))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView applies macOS fast pass highlight before final phase")
    @MainActor
    func syntaxEditorViewMacAppliesFastPassHighlightBeforeFinalPhase() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0xABCDEF),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.string"
                ),
            ],
            completeGate: completeGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.baseForeground))
        #expect(await highlighter.callCount() == 1)

        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))

        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x112233),
            string: syntaxEditorUITestColor(hex: 0x556677),
            keyword: syntaxEditorUITestColor(hex: 0x334455)
        )
        model.model.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(await highlighter.callCount() == 1)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.string))
    }

    @Test("SyntaxEditorView applies macOS incremental fast pass before any complete highlight")
    @MainActor
    func syntaxEditorViewMacAppliesIncrementalFastPassBeforeAnyCompleteHighlight() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0xABCDEF),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let updateRefreshRange = NSRange(location: 0, length: source.utf16.count + 1)
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateFastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.string"
                ),
            ],
            completeTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeGate: completeGate,
            updateRefreshRange: updateRefreshRange
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)
        editorView.textView.insertText("x", replacementRange: insertionRange)

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))
        #expect(editorView.textView.string == "\(source)x")

        await completeGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView keeps macOS complete incremental materialization inside refresh range")
    @MainActor
    func syntaxEditorViewMacKeepsCompleteIncrementalMaterializationInsideRefreshRange() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0xABCDEF),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let insertedRange = NSRange(location: source.utf16.count, length: 1)
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateFastTokens: [],
            completeTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateCompleteTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.string"
                ),
                SyntaxEditorHighlighting.Token(
                    range: insertedRange,
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeGate: completeGate,
            updateRefreshRange: insertedRange
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)
        let updateSuspensionCount = await completeGate.currentSuspensionCount()
        editorView.textView.insertText("x", replacementRange: insertionRange)
        await completeGate.waitUntilSuspended(after: updateSuspensionCount)

        await completeGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == "\(source)x")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: source.utf16.count),
                theme.keyword
            )
        )
    }

    @Test("SyntaxEditorView applies macOS incremental fast pass after empty complete highlight")
    @MainActor
    func syntaxEditorViewMacAppliesIncrementalFastPassAfterEmptyCompleteHighlight() async {
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [],
            updateFastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 1),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeTokens: [],
            completeGate: completeGate
        )
        let model = SyntaxEditorTestContext(
            text: "",
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editorView.textView.insertText("l", replacementRange: NSRange(location: 0, length: 0))

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(editorView.textView.string == "l")

        await completeGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView preserves macOS semantic highlight during incremental fast pass")
    @MainActor
    func syntaxEditorViewMacPreservesSemanticHighlightDuringIncrementalFastPass() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0xABCDEF),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.string"
                ),
            ],
            completeGate: completeGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))

        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)
        editorView.textView.insertText("x", replacementRange: insertionRange)

        let skippedFastPass = await editorView.waitForSkippedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass)
        #expect(skippedFastPass)
        #expect(editorView.textView.string == "\(source)x")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))

        await completeGate.resumeAll()
        if skippedFastPass {
            await editorView.waitForPendingHighlightForTesting()
            #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))
        }
    }

    @Test("SyntaxEditorView preserves macOS semantic highlight across rapid incremental fast passes")
    @MainActor
    func syntaxEditorViewMacPreservesSemanticHighlightAcrossRapidIncrementalFastPasses() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0xABCDEF),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.string"
                ),
            ],
            completeGate: completeGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))

        let firstSuspensionCount = await completeGate.currentSuspensionCount()
        let firstInsertionRange = NSRange(location: 0, length: 0)
        editorView.textView.setSelectedRange(firstInsertionRange)
        editorView.textView.insertText("x", replacementRange: firstInsertionRange)

        await completeGate.waitUntilSuspended(after: firstSuspensionCount)
        #expect(await editorView.waitForSkippedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(editorView.textView.string == "x\(source)")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 1), theme.string))

        let secondSuspensionCount = await completeGate.currentSuspensionCount()
        let secondInsertionRange = NSRange(location: editorView.textView.string.utf16.count, length: 0)
        editorView.textView.setSelectedRange(secondInsertionRange)
        editorView.textView.insertText("y", replacementRange: secondInsertionRange)

        await completeGate.waitUntilSuspended(after: secondSuspensionCount)
        #expect(await editorView.waitForSkippedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(editorView.textView.string == "x\(source)y")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 1), theme.string))

        await completeGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))
    }

    @Test("SyntaxEditorView resets macOS highlight state without repainting old text before document replacement")
    @MainActor
    func syntaxEditorViewMacResetsHighlightStateWithoutRepaintingOldTextBeforeDocumentReplacement() async {
        let source = "let value = 1"
        let replacement = "var pasted = 2\nprint(pasted)"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            resetGate: resetGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await resetGate.waitUntilSuspended()
        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(editorView.syntaxColorRunCountForTesting == 1)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let suspensionCount = await resetGate.currentSuspensionCount()
        model.model.replaceText(replacement)
        editorView.synchronizeDocumentForTesting()

        await resetGate.waitUntilSuspended(after: suspensionCount)
        #expect(editorView.textView.string == replacement)
        #expect(editorView.syntaxColorRunCountForTesting == 0)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView clears macOS syntax runs when switching to plain text")
    @MainActor
    func syntaxEditorViewMacClearsSyntaxRunsWhenSwitchingToPlainText() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(editorView.syntaxColorRunCountForTesting == 1)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        model.model.language = .plainText
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.syntaxColorRunCountForTesting == 0)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))
    }

    @Test("SyntaxEditorView applies built-in macOS theme base font to plain and highlighted text")
    @MainActor
    func syntaxEditorViewMacAppliesBuiltInThemeBaseFont() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .presentationLarge
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - plainFont.pointSize) < 0.01)
        #expect(abs(plainFont.pointSize - 28) < 0.01)
    }

    @Test("SyntaxEditorView applies macOS font size delta to built-in theme fonts")
    @MainActor
    func syntaxEditorViewMacAppliesFontSizeDeltaToBuiltInThemeFonts() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .presentationLarge,
            fontSizeDelta: 3
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        let plainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - plainFont.pointSize) < 0.01)
        #expect(abs(plainFont.pointSize - 31) < 0.01)
    }

    @Test("SyntaxEditorView clamps macOS font size delta")
    @MainActor
    func syntaxEditorViewMacClampsFontSizeDelta() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .presentationLarge,
            fontSizeDelta: 100
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let maximumHighlightedFont = try #require(macEditorFont(editorView, at: 0))
        let maximumPlainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(maximumHighlightedFont.pointSize - 64) < 0.01)
        #expect(abs(maximumPlainFont.pointSize - 64) < 0.01)

        model.model.fontSizeDelta = -100
        editorView.synchronizeDocumentForTesting()

        let minimumHighlightedFont = try #require(macEditorFont(editorView, at: 0))
        let minimumPlainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(minimumHighlightedFont.pointSize - 4) < 0.01)
        #expect(abs(minimumPlainFont.pointSize - 4) < 0.01)
    }

    @Test("SyntaxEditorView recomputes selected macOS font size after delta overshoot")
    @MainActor
    func syntaxEditorViewMacRecomputesSelectedFontSizeAfterDeltaOvershoot() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: .presentationLarge,
            fontSizeDelta: 100
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let maximumPlainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(maximumPlainFont.pointSize - 64) < 0.01)

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 3))
        model.model.decreaseFontSize()
        editorView.synchronizeDocumentForTesting()

        #expect(model.model.fontSizeDelta == 35)
        let decreasedHighlightedFont = try #require(macEditorFont(editorView, at: 0))
        let decreasedPlainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(decreasedHighlightedFont.pointSize - 63) < 0.01)
        #expect(abs(decreasedPlainFont.pointSize - 63) < 0.01)

        model.model.resetFontSize()
        editorView.synchronizeDocumentForTesting()

        #expect(model.model.fontSizeDelta == 0)
        let resetHighlightedFont = try #require(macEditorFont(editorView, at: 0))
        let resetPlainFont = try #require(macEditorFont(editorView, at: 4))
        #expect(abs(resetHighlightedFont.pointSize - 28) < 0.01)
        #expect(abs(resetPlainFont.pointSize - 28) < 0.01)
    }

    @Test("SyntaxEditorView applies macOS base attributes to inserted text before delayed update highlight")
    @MainActor
    func syntaxEditorViewMacAppliesBaseAttributesToInsertedTextBeforeDelayedUpdateHighlight() async throws {
        let source = "let value = 1"
        let insertedPrefix = "// "
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateTokens: [],
            updateGate: updateGate,
            updateRefreshRange: NSRange(location: 0, length: source.utf16.count + insertedPrefix.utf16.count)
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let baseFont = try #require(editorView.textView.font)
        await editorView.waitForPendingHighlightForTesting()

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText(insertedPrefix, replacementRange: NSRange(location: 0, length: 0))

        await updateGate.waitUntilSuspended(after: previousSuspensionCount)
        #expect(editorView.textView.string == insertedPrefix + source)
        #expect(syntaxEditorUITestFontsEqual(macEditorFont(editorView, at: 0), baseFont))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        await updateGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView restores macOS base font when syntax font tokens are removed")
    @MainActor
    func syntaxEditorViewMacRestoresBaseFontWhenSyntaxFontTokensAreRemoved() async throws {
        let source = "let value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.comment.doc"
                ),
            ],
            updateTokens: [],
            updateRefreshRange: NSRange(location: 0, length: 3)
        )
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let baseFont = try #require(editorView.textView.font)

        await editorView.waitForPendingHighlightForTesting()
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        #expect(!syntaxEditorUITestFontsEqual(highlightedFont, baseFont))

        editorView.textView.insertText("var", replacementRange: NSRange(location: 0, length: 3))
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == "var value = 1")
        #expect(syntaxEditorUITestFontsEqual(macEditorFont(editorView, at: 0), baseFont))
    }

    @Test("SyntaxEditorView restores shifted macOS syntax font after prefix edits")
    @MainActor
    func syntaxEditorViewMacRestoresShiftedSyntaxFontAfterPrefixEdits() async throws {
        let source = "let value = 1"
        let insertedPrefix = "// "
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.comment.doc"
                ),
            ],
            updateTokens: [],
            updateRefreshRange: NSRange(location: 0, length: source.utf16.count + insertedPrefix.utf16.count)
        )
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let baseFont = try #require(editorView.textView.font)

        await editorView.waitForPendingHighlightForTesting()
        let highlightedFont = try #require(macEditorFont(editorView, at: 0))
        #expect(!syntaxEditorUITestFontsEqual(highlightedFont, baseFont))

        editorView.textView.insertText(insertedPrefix, replacementRange: NSRange(location: 0, length: 0))
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == insertedPrefix + source)
        #expect(syntaxEditorUITestFontsEqual(macEditorFont(editorView, at: insertedPrefix.utf16.count), baseFont))
    }

    @Test("SyntaxEditorView applies dense macOS highlight tokens across the document")
    @MainActor
    func syntaxEditorViewMacAppliesDenseHighlightTokensAcrossDocument() async {
        let fixture = syntaxEditorDenseHighlightFixture()
        let theme = syntaxEditorUITestTheme(
            comment: syntaxEditorUITestColor(hex: 0x305070),
            string: syntaxEditorUITestColor(hex: 0x507030),
            keyword: syntaxEditorUITestColor(hex: 0x703050)
        )
        let highlighter = SyntaxEditorUITestHighlighter(tokens: fixture.tokens)
        let model = SyntaxEditorTestContext(
            text: fixture.source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        let middleLocation = fixture.source.utf16.count / 2
        let lastLocation = fixture.source.utf16.count - 1
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: 0),
                syntaxEditorDenseHighlightColor(in: theme, at: 0)
            )
        )
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: middleLocation),
                syntaxEditorDenseHighlightColor(in: theme, at: middleLocation)
            )
        )
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: lastLocation),
                syntaxEditorDenseHighlightColor(in: theme, at: lastLocation)
            )
        )
        #expect(macEditorFont(editorView, at: middleLocation) != nil)
    }

    @Test("SyntaxEditorView applies macOS syntax colors outside draw")
    @MainActor
    func syntaxEditorViewMacAppliesSyntaxColorsOutsideDraw() async {
        let fixture = syntaxEditorDenseHighlightFixture(tokenCount: 1_500)
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            comment: syntaxEditorUITestColor(hex: 0x305070),
            string: syntaxEditorUITestColor(hex: 0x507030),
            keyword: syntaxEditorUITestColor(hex: 0x703050)
        )
        let highlighter = SyntaxEditorUITestHighlighter(tokens: fixture.tokens)
        let model = SyntaxEditorTestContext(
            text: fixture.source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let deferredLocation = 1_000

        await editorView.waitForPendingHighlightForTesting()

        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: deferredLocation),
                syntaxEditorDenseHighlightColor(in: theme, at: deferredLocation)
            )
        )
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorPermanentForegroundColor(editorView, at: deferredLocation),
                theme.baseForeground
            )
        )
    }

    @Test("SyntaxEditorView draws macOS syntax foregrounds through TextKit fragments")
    @MainActor
    func syntaxEditorViewMacDrawsSyntaxForegroundsThroughTextKitFragments() async throws {
        let source = "let let let let let let let"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x0000FF),
            keyword: syntaxEditorUITestColor(hex: 0xFF0000),
            background: syntaxEditorUITestColor(hex: 0x000000)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme,
            fontSizeDelta: 8
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutMacEditorView(editorView, width: 320, height: 140)

        await editorView.waitForPendingHighlightForTesting()
        let fragmentView = try #require(macEditorVisibleFragmentViews(editorView).first)
        let styleEpoch = editorView.syntaxForegroundMaterializationCountForTesting

        let renderedKeywordColor = macEditorRenderedFragmentContainsDominantColor(
            fragmentView,
            targetColor: theme.keyword,
            backgroundColor: theme.background
        )

        #expect(editorView.syntaxForegroundMaterializationCountForTesting == styleEpoch)
        #expect(renderedKeywordColor)
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorPermanentForegroundColor(editorView, at: 0),
                theme.baseForeground
            )
        )
    }

    @Test("SyntaxEditorView keeps macOS rendering attribute validation local during jump scrolls")
    @MainActor
    func syntaxEditorViewMacKeepsRenderingAttributeValidationLocalDuringJumpScrolls() async throws {
        let repeatedToken = "let wrappedValue = wrappedValue "
        let repeatCount = 1_600
        let source = String(repeating: repeatedToken, count: repeatCount)
        let tokenStride = repeatedToken.utf16.count
        let tokens = (0..<repeatCount).map { index in
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: index * tokenStride, length: 3),
                rawCaptureName: "editor.syntax.swift.keyword"
            )
        }
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x0000FF),
            keyword: syntaxEditorUITestColor(hex: 0xFF0000),
            background: syntaxEditorUITestColor(hex: 0x000000)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(tokens: tokens, resetGate: resetGate)
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutMacEditorView(editorView, width: 180, height: 140)

        await resetGate.waitUntilSuspended()
        let initialFragmentView = try #require(macEditorVisibleFragmentViews(editorView).first)
        let initialFragmentRange = editorView.textView.textRange(for: initialFragmentView.layoutFragment)
        #expect(initialFragmentRange.length > source.utf16.count / 2)

        editorView.textView.resetSyntaxRenderingAttributeCountersForTesting()
        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()

        let initialValidatedLength = editorView.textView.syntaxRenderingAttributeUTF16LengthForTesting
        let initialValidatedColorRuns = editorView.textView.syntaxRenderingAttributeColorRunCountForTesting
        #expect(initialValidatedLength > 0)
        #expect(initialValidatedLength < source.utf16.count / 4)
        #expect(initialValidatedColorRuns > 0)
        #expect(initialValidatedColorRuns < tokens.count / 4)

        editorView.contentView.scroll(to: NSPoint(x: 0, y: 8_000))
        editorView.reflectScrolledClipView(editorView.contentView)
        editorView.textView.layoutVisibleViewport()

        let scrolledFragmentView = try #require(
            macEditorVisibleFragmentViews(editorView)
                .first { $0.frame.intersects(editorView.textView.visibleRect) }
        )
        let scrolledFragmentRange = editorView.textView.textRange(for: scrolledFragmentView.layoutFragment)
        let scrolledTargetRanges = editorView.textView.syntaxRenderingAttributeTargetRangesForTesting(
            in: scrolledFragmentView.layoutFragment
        )
        let scrolledTargetLength = scrolledTargetRanges.reduce(0) { $0 + $1.length }
        #expect(!scrolledTargetRanges.isEmpty)
        #expect(scrolledFragmentRange.length > source.utf16.count / 2)
        #expect(scrolledTargetLength < scrolledFragmentRange.length / 4)

        let scrolledDirtyRect = editorView.textView.visibleRect
            .offsetBy(dx: -scrolledFragmentView.frame.minX, dy: -scrolledFragmentView.frame.minY)
            .intersection(scrolledFragmentView.bounds)
        editorView.textView.resetSyntaxRenderingAttributeCountersForTesting()
        macEditorDrawFragment(
            scrolledFragmentView,
            dirtyRect: scrolledDirtyRect,
            backgroundColor: theme.background
        )
        #expect(editorView.textView.syntaxRenderingAttributeUTF16LengthForTesting > 0)
        #expect(editorView.textView.syntaxRenderingAttributeUTF16LengthForTesting < source.utf16.count / 4)
        #expect(editorView.textView.syntaxRenderingAttributeColorRunCountForTesting < tokens.count / 4)

        editorView.textView.resetSyntaxRenderingAttributeCountersForTesting()
        editorView.textView.invalidateSyntaxRenderingAttributes(
            for: [NSRange(location: 0, length: source.utf16.count)]
        )
        #expect(editorView.textView.syntaxRenderingAttributeUTF16LengthForTesting > 0)
        #expect(editorView.textView.syntaxRenderingAttributeUTF16LengthForTesting < source.utf16.count / 4)
        #expect(editorView.textView.syntaxRenderingAttributeColorRunCountForTesting < tokens.count / 4)
    }

    @Test("SyntaxEditorView replaces stale macOS syntax colors after new highlight epochs")
    @MainActor
    func syntaxEditorViewMacReplacesStaleSyntaxColorsAfterNewEpochs() async {
        let source = "let"
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            keyword: syntaxEditorUITestColor(hex: 0x305070)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            keyword: syntaxEditorUITestColor(hex: 0x703050)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: initialTheme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), initialTheme.keyword))

        model.model.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorPermanentForegroundColor(editorView, at: 0),
                updatedTheme.baseForeground
            )
        )
    }

    @Test("SyntaxEditorView keeps macOS syntax colors while typing awaits highlight")
    @MainActor
    func syntaxEditorViewMacKeepsMaterializedSyntaxColorsDuringPendingTypingHighlight() async {
        let source = "let\nvalue"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateGate: updateGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText("!", replacementRange: NSRange(location: source.utf16.count, length: 0))
        await updateGate.waitUntilSuspended(after: previousSuspensionCount)

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        await updateGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView keeps same-line macOS syntax colors while typing awaits highlight")
    @MainActor
    func syntaxEditorViewMacKeepsSameLineSyntaxColorsDuringPendingTypingHighlight() async {
        let source = "extension "
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 9),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateGate: updateGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText("S", replacementRange: NSRange(location: source.utf16.count, length: 0))
        await updateGate.waitUntilSuspended(after: previousSuspensionCount)

        #expect(editorView.textView.string == "extension S")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        await updateGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView keeps shifted stale macOS syntax colors while typing awaits highlight")
    @MainActor
    func syntaxEditorViewMacMaterializesShiftedStaleSyntaxColorsDuringPendingTypingHighlight() async {
        let source = "let\nlet"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 4, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 5, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateGate: updateGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.keyword))

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        await updateGate.waitUntilSuspended(after: previousSuspensionCount)

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 5), theme.keyword))

        await updateGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 5), theme.keyword))
    }

    @Test("SyntaxEditorView avoids full macOS display invalidation after language resets")
    @MainActor
    func syntaxEditorViewMacAvoidsFullDisplayInvalidationAfterLanguageResets() async {
        let source = "let"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0x345678),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorLanguageAwareTestHighlighter(
            swiftTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            jsonTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.json.string"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        let invalidationCount = editorView.fullTextDisplayInvalidationCountForTesting

        model.model.language = SyntaxLanguage.json
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.fullTextDisplayInvalidationCountForTesting == invalidationCount)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))
    }

    @Test("SyntaxEditorView redraws visible macOS text fragments after language resets")
    @MainActor
    func syntaxEditorViewMacRedrawsVisibleTextFragmentsAfterLanguageResets() async {
        let source = (0..<12)
            .map { "let value\($0) = \"text\"" }
            .joined(separator: "\n")
        var lineStart = 0
        let swiftTokens = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            defer {
                lineStart += line.utf16.count + 1
            }
            return SyntaxEditorHighlighting.Token(
                range: NSRange(location: lineStart, length: 3),
                rawCaptureName: "editor.syntax.swift.keyword"
            )
        }
        let highlighter = SyntaxEditorLanguageAwareTestHighlighter(
            swiftTokens: swiftTokens,
            jsonTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.json.string"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        editorView.frame = NSRect(x: 0, y: 0, width: 640, height: 260)
        editorView.layoutSubtreeIfNeeded()

        await editorView.waitForPendingHighlightForTesting()
        let initialFragments = macEditorVisibleFragmentViews(editorView)
        #expect(!initialFragments.isEmpty)
        let fragmentInvalidationCount = editorView.fragmentDisplayInvalidationCountForTesting

        model.model.language = SyntaxLanguage.json
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.fragmentDisplayInvalidationCountForTesting > fragmentInvalidationCount)
    }

    @Test("SyntaxEditorView preserves macOS non-syntax attributes while applying delayed highlight")
    @MainActor
    func syntaxEditorViewMacDelayedHighlightPreservesNonSyntaxAttributes() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            resetGate: resetGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        editorView.textView.textStorage?.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 4, length: 5)
        )

        await resetGate.waitUntilSuspended()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))
        #expect(macEditorUnderlineStyle(editorView, at: 4) == NSUnderlineStyle.single.rawValue)

        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.baseForeground))
        #expect(macEditorUnderlineStyle(editorView, at: 4) == NSUnderlineStyle.single.rawValue)
    }

    @Test("SyntaxEditorView keeps macOS bracket highlight only for caret selections")
    @MainActor
    func syntaxEditorViewAppKitBracketHighlightSkipsNonemptySelection() async {
        let source = "{}"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())
        await editorView.waitForPendingHighlightForTesting()

        let visibleInvalidationCount = editorView.visibleTextDisplayInvalidationCountForTesting
        editorView.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )

        #expect(editorView.bracketHighlightRangesForTesting == [
            NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 1),
        ])
        #expect(macEditorHasBackgroundAttribute(editorView, at: 0))
        #expect(macEditorHasBackgroundAttribute(editorView, at: 1))
        #expect(macEditorTextStorageBackgroundColor(editorView, at: 0) == nil)
        #expect(macEditorTextStorageBackgroundColor(editorView, at: 1) == nil)
        #expect(editorView.visibleTextDisplayInvalidationCountForTesting == visibleInvalidationCount)

        editorView.textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )

        #expect(editorView.bracketHighlightRangesForTesting.isEmpty)
        #expect(!macEditorHasBackgroundAttribute(editorView, at: 0))
        #expect(!macEditorHasBackgroundAttribute(editorView, at: 1))
        #expect(editorView.visibleTextDisplayInvalidationCountForTesting == visibleInvalidationCount)
    }

    @Test("SyntaxEditorView keeps macOS text painting owned by the scroll view")
    @MainActor
    func syntaxEditorViewMacUsesScrollViewBackedTextPainting() {
        let model = SyntaxEditorTestContext(text: "let value = 1", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())

        #expect(editorView.drawsBackground)
        #expect(!editorView.textView.drawsBackground)
        #expect(!editorView.textView.textContentView.wantsLayer)
        #expect(!(editorView.textView.textContentView.layer is CATiledLayer))
        #expect(!type(of: editorView.textView).isCompatibleWithResponsiveScrolling)
    }

    @Test("SyntaxEditorView defers macOS syntax colors while preserving active selection drawing")
    @MainActor
    func syntaxEditorViewMacDefersHighlightApplicationDuringSelection() async {
        let source = "{}\nlet value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 3, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            resetGate: resetGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        await resetGate.waitUntilSuspended()

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 2))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )
        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.bracketHighlightRangesForTesting.isEmpty)
        #expect(!macEditorHasBackgroundAttribute(editorView, at: 0))
        #expect(!macEditorHasBackgroundAttribute(editorView, at: 1))
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), theme.baseForeground))

        editorView.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )

        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 3), theme.keyword))
        #expect(editorView.bracketHighlightRangesForTesting == [
            NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 1),
        ])
    }

    @Test("SyntaxEditorView drops deferred macOS syntax colors after language changes")
    @MainActor
    func syntaxEditorViewMacDropsDeferredHighlightAfterLanguageChange() async {
        let source = "let"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorLanguageAwareTestHighlighter(
            swiftTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            jsonTokens: [],
            resetGate: resetGate
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        await resetGate.waitUntilSuspended()

        editorView.textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )
        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        let previousSuspensionCount = await resetGate.currentSuspensionCount()
        model.model.language = SyntaxLanguage.json
        editorView.synchronizeDocumentForTesting()
        await resetGate.waitUntilSuspended(after: previousSuspensionCount)
        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))
    }

    @Test("SyntaxEditorView applies latest macOS highlight after model replacement")
    @MainActor
    func syntaxEditorViewMacAppliesLatestHighlightAfterModelReplacement() async {
        let initialSource = "let"
        let replacementSource = "\"x\""
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            string: syntaxEditorUITestColor(hex: 0x345678),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorLanguageAwareTestHighlighter(
            swiftTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: initialSource.utf16.count),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            jsonTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: replacementSource.utf16.count),
                    rawCaptureName: "editor.syntax.json.string"
                ),
            ],
            resetGate: resetGate
        )
        let initialModel = SyntaxEditorTestContext(
            text: initialSource,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let replacementModel = SyntaxEditorModel(
            text: replacementSource,
            language: SyntaxLanguage.json,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: initialModel, highlighter: highlighter)
        await resetGate.waitUntilSuspended()
        let previousSuspensionCount = await resetGate.currentSuspensionCount()

        editorView.update(model: replacementModel)
        await resetGate.waitUntilSuspended(after: previousSuspensionCount)
        await resetGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.model === replacementModel)
        #expect(editorView.textView.string == replacementSource)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.string))
    }

    @Test("SyntaxEditorView fully repaints macOS syntax colors after dropping deferred highlights")
    @MainActor
    func syntaxEditorViewMacFullRepaintsAfterDroppingDeferredHighlight() async {
        let source = "let\nlet"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 4, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            resetGate: resetGate,
            updateGate: updateGate,
            updateRefreshRange: NSRange(location: 0, length: source.utf16.count),
            updateTokenPayload: .fullSnapshot
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        await resetGate.waitUntilSuspended()

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editorView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorView.textView)
        )
        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.baseForeground))

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText("var", replacementRange: NSRange(location: 0, length: 3))
        await updateGate.waitUntilSuspended(after: previousSuspensionCount)
        await updateGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == "var\nlet")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 4), theme.keyword))
    }

    @Test("SyntaxEditorView preserves macOS syntax colors outside command edit ranges")
    @MainActor
    func syntaxEditorViewMacCommandEditsPreserveSyntaxColorsOutsideRefreshRange() async {
        let source = "let value = "
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            updateRefreshRange: NSRange(location: source.utf16.count, length: 2)
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)
        editorView.textView.insertText("\"", replacementRange: insertionRange)
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == "\(source)\"\"")
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView preserves macOS highlights for observed document edits")
    @MainActor
    func syntaxEditorViewMacObservedDocumentEditsPreserveExistingHighlights() async {
        let source = "let first = 1\nlet second = 2"
        let appendedText = "\nlet third = 3"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(range: NSRange(location: 0, length: 3), rawCaptureName: "editor.syntax.swift.keyword"),
            ],
            updateRefreshRange: NSRange(location: source.utf16.count, length: appendedText.utf16.count)
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        _ = model.model.commitTextReplacements(
            [
                SyntaxEditorTextChange.Replacement(
                    range: NSRange(location: source.utf16.count, length: 0),
                    replacement: appendedText
                ),
            ],
            selectedRange: NSRange(location: source.utf16.count + appendedText.utf16.count, length: 0)
        )
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == source + appendedText)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView fully applies macOS highlight when skipped revisions precede an incremental result")
    @MainActor
    func syntaxEditorViewMacFullyAppliesHighlightAfterSkippedIncrementalRevisions() async {
        let firstPaste = "let first = 1\n"
        let secondPaste = "let second = 2\n"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let resetGate = ManualSyntaxHighlightGate()
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: firstPaste.utf16.count, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            resetGate: resetGate,
            updateGate: updateGate,
            updateRefreshRange: NSRange(
                location: 0,
                length: firstPaste.utf16.count + secondPaste.utf16.count
            ),
            updateTokenPayload: .fullSnapshot
        )
        let model = SyntaxEditorTestContext(
            text: "",
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        await resetGate.waitUntilSuspended()

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let firstSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText(firstPaste, replacementRange: NSRange(location: 0, length: 0))
        await updateGate.waitUntilSuspended(after: firstSuspensionCount)
        editorView.textView.setSelectedRange(NSRange(location: firstPaste.utf16.count, length: 0))
        let secondSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.insertText(
            secondPaste,
            replacementRange: NSRange(location: firstPaste.utf16.count, length: 0)
        )
        await updateGate.waitUntilSuspended(after: secondSuspensionCount)

        await resetGate.resumeAll()
        await updateGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == firstPaste + secondPaste)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(
            syntaxEditorUITestColorsEqual(
                macEditorForegroundColor(editorView, at: firstPaste.utf16.count),
                theme.keyword
            )
        )
    }

    @Test("SyntaxEditorView renders macOS pasted text before async highlight completes")
    @MainActor
    func syntaxEditorViewMacRendersPastedTextBeforeAsyncHighlightCompletes() async {
        let source = "let start = 0\n"
        let pastedText = String(repeating: "let value = 1\n", count: 500)
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(updateGate: updateGate)
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutMacEditorView(editorView)
        await editorView.waitForPendingHighlightForTesting()
        let initialDocumentHeight = editorView.textView.frame.height

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editorView.textView.insertText(pastedText, replacementRange: NSRange(location: 0, length: 0))
        await updateGate.waitUntilSuspended()
        layoutMacEditorView(editorView)
        let pastedDocumentHeight = editorView.textView.frame.height

        #expect(editorView.textView.string == pastedText + source)
        #expect(model.model.text == pastedText + source)
        #expect(pastedDocumentHeight > initialDocumentHeight + 1_000)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.textView.replaceCharacters(
            in: NSRange(location: 0, length: pastedText.utf16.count),
            with: ""
        )
        await updateGate.waitUntilSuspended(after: previousSuspensionCount)
        layoutMacEditorView(editorView)

        #expect(editorView.textView.string == source)
        #expect(model.model.text == source)
        #expect(editorView.textView.frame.height < pastedDocumentHeight - 1_000)

        await updateGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView schedules macOS paste highlight while attribute highlight is applying")
    @MainActor
    func syntaxEditorViewMacSchedulesPasteHighlightWhileAttributeHighlightIsApplying() async {
        let source = "let value = 1\n"
        let pastedText = "let pasted = 2\n"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()
        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editorView.setApplyingHighlightForTesting(true)
        editorView.textView.insertText(pastedText, replacementRange: NSRange(location: 0, length: 0))
        editorView.setApplyingHighlightForTesting(false)
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == pastedText + source)
        #expect(model.model.text == pastedText + source)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView applies macOS font size key equivalents")
    @MainActor
    func syntaxEditorViewMacFontSizeKeyEquivalents() {
        let model = SyntaxEditorTestContext(text: "let answer = 42", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)

        guard let increaseEvent = makeMacCommandKeyEvent("+"),
              let decreaseEvent = makeMacCommandKeyEvent("-"),
              let resetEvent = makeMacCommandKeyEvent("0", modifierFlags: [.control, .command])
        else {
            Issue.record("Failed to create font size key events")
            return
        }

        #expect(editorView.textView.performKeyEquivalent(with: increaseEvent))
        #expect(model.model.fontSizeDelta == 1)

        #expect(editorView.textView.performKeyEquivalent(with: decreaseEvent))
        #expect(model.model.fontSizeDelta == 0)

        model.model.fontSizeDelta = 5
        #expect(editorView.textView.performKeyEquivalent(with: resetEvent))
        #expect(model.model.fontSizeDelta == 0)
    }

}
#endif
