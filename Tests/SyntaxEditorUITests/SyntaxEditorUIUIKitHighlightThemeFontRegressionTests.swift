#if canImport(UIKit)
import Foundation
import Observation
import ObservationBridge
import SwiftUI
import Testing
import UIKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUICommon
@testable import SyntaxEditorUIUIKit

extension SyntaxEditorUITests {
    @Test("SyntaxEditorView clips iOS highlight ranges to layout fragments")
    @MainActor
    func syntaxEditorViewIOSClipsHighlightRangesToLayoutFragments() {
        let ranges = [
            NSRange(location: 10, length: 5),
            NSRange(location: 30, length: 10),
            NSRange(location: 60, length: 2),
        ]

        #expect(
            TextLayoutGeometry.ranges(
                ranges,
                intersecting: NSRange(location: 12, length: 25)
            ) == [
                NSRange(location: 12, length: 3),
                NSRange(location: 30, length: 7),
            ]
        )
        #expect(TextLayoutGeometry.ranges(ranges, intersecting: NSRange(location: 100, length: 5)).isEmpty)
    }

    @Test("SyntaxEditorView reflects custom iOS theme")
    @MainActor
    func syntaxEditorViewIOSThemeObservation() async {
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

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), initialTheme.baseForeground))

        model.model.theme = updatedTheme

        editorView.synchronizeDocumentForTesting()
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground))
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground))
    }

    @Test("SyntaxEditorView refreshes iOS permanent base foreground after appearance changes")
    @MainActor
    func syntaxEditorViewIOSRefreshesPermanentBaseForegroundAfterAppearanceChanges() throws {
        let model = SyntaxEditorTestContext(
            text: "plain text",
            language: SyntaxLanguage.swift,
            theme: .default
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        editorView.frame = controller.view.bounds
        editorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(editorView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        editorView.overrideUserInterfaceStyle = .light
        controller.view.layoutIfNeeded()
        editorView.refreshForColorAppearanceChange()
        #expect(editorView.traitCollection.userInterfaceStyle == .light)
        let lightForeground = try #require(iOSEditorPermanentForegroundColor(editorView, at: 0))

        editorView.overrideUserInterfaceStyle = .dark
        controller.view.layoutIfNeeded()
        editorView.refreshForColorAppearanceChange()
        #expect(editorView.traitCollection.userInterfaceStyle == .dark)
        let darkBaseForeground = try #require(editorView.baseForegroundColorForTesting())

        withExtendedLifetime(window) {
            #expect(syntaxEditorUITestColorsEqual(iOSEditorPermanentForegroundColor(editorView, at: 0), darkBaseForeground))
            #expect(!syntaxEditorUITestColorsEqual(lightForeground, darkBaseForeground))
        }
    }

    @Test("SyntaxEditorView reflects iOS background drawing configuration")
    @MainActor
    func syntaxEditorViewIOSDrawsBackgroundObservation() async {
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
        let clearsBackground = await delivery.values {
            syntaxEditorUITestColorsEqual(editorView.backgroundColor, UIColor.clear)
                && syntaxEditorUITestColorsEqual(editorView.textContentView.backgroundColor, UIColor.clear)
                && editorView.isOpaque == false
        }

        #expect(syntaxEditorUITestColorsEqual(editorView.backgroundColor, background))
        #expect(syntaxEditorUITestColorsEqual(editorView.textContentView.backgroundColor, background))
        #expect(editorView.isOpaque)

        model.model.drawsBackground = false

        #expect(await clearsBackground.waitUntilValue(true))
    }

    @Test("SyntaxEditorView resets nested empty-style iOS tokens to the base theme")
    @MainActor
    func syntaxEditorViewIOSResetsNestedEmptyStyleTokensToBaseTheme() async {
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

        #expect(await editorView.waitForPendingHighlightForTesting())

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), theme.baseForeground))
    }

    @Test("SyntaxEditorView resets multi-level empty-style iOS tokens to the base theme")
    @MainActor
    func syntaxEditorViewIOSResetsMultiLevelEmptyStyleTokensToBaseTheme() async {
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

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 2), theme.string))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 4), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 6), theme.string))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 8), theme.keyword))
    }

    @Test("SyntaxEditorView clears iOS syntax runs when switching to plain text")
    @MainActor
    func syntaxEditorViewIOSClearsSyntaxRunsWhenSwitchingToPlainText() async {
        let source = "const answer = 42;"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 5),
                    rawCaptureName: "editor.syntax.javascript.keyword",
                    language: .javascript
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(editorView.syntaxForegroundColorForTesting(at: 0) != nil)

        model.model.language = .plainText
        editorView.synchronizeDocumentForTesting()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        #expect(editorView.syntaxForegroundColorForTesting(at: 0) == nil)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.baseForeground))
    }

    @Test("SyntaxEditorView reapplies iOS same-style tokens after empty-style splits")
    @MainActor
    func syntaxEditorViewIOSReappliesSameStyleTokensAfterEmptyStyleSplits() async {
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

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 6), theme.string))
    }

    @Test("SyntaxEditorView keeps iOS empty-style gaps between separated same-style runs")
    @MainActor
    func syntaxEditorViewIOSKeepsEmptyStyleGapsBetweenSeparatedSameStyleRuns() async {
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

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 4), theme.string))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 5), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 6), theme.string))
    }

    @Test("SyntaxEditorView reapplies cached iOS syntax colors without highlighting")
    @MainActor
    func syntaxEditorViewIOSThemeReusesCachedHighlightTokens() async {
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
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), initialTheme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), initialTheme.baseForeground))

        model.model.theme = updatedTheme

        editorView.synchronizeDocumentForTesting()
        #expect(
            syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.keyword)
                && syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground)
        )
        await editorView.waitForPendingHighlightForTesting()
        #expect(await highlighter.callCount() == initialCallCount)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), updatedTheme.baseForeground))
    }

    @Test("SyntaxEditorView refreshes iOS syntax colors when theme changes after incremental edits")
    @MainActor
    func syntaxEditorViewIOSThemeRefreshesAfterIncrementalEditDropsCachedTokens() async {
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
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), initialTheme.keyword))

        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editorView.insertText("!")
        await editorView.waitForPendingHighlightForTesting()
        let editedCallCount = await highlighter.callCount()
        #expect(editedCallCount == initialCallCount + 1)

        model.model.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(await highlighter.callCount() == editedCallCount + 1)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
    }

    @Test("SyntaxEditorView preserves cached iOS syntax colors after font size delta changes")
    @MainActor
    func syntaxEditorViewIOSFontSizeDeltaPreservesCachedHighlightTokens() async throws {
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
        let initialFont = try #require(iOSEditorFont(editorView, at: 0))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorPermanentForegroundColor(editorView, at: 0), theme.baseForeground))

        model.model.fontSizeDelta = 4
        editorView.synchronizeDocumentForTesting()

        #expect(await highlighter.callCount() == initialCallCount)
        let highlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        let plainFont = try #require(iOSEditorFont(editorView, at: 3))
        #expect(abs(highlightedFont.pointSize - (initialFont.pointSize + 4)) < 0.01)
        #expect(abs(plainFont.pointSize - highlightedFont.pointSize) < 0.01)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorPermanentForegroundColor(editorView, at: 0), theme.baseForeground))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 3), theme.baseForeground))
    }

    @Test("SyntaxEditorView applies built-in iOS theme fonts after theme changes")
    @MainActor
    func syntaxEditorViewIOSAppliesBuiltInThemeFontsAfterThemeChanges() async throws {
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
        let highlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        let plainFont = try #require(iOSEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - 30) < 0.01)
        #expect(abs(plainFont.pointSize - 30) < 0.01)
    }

    @Test("SyntaxEditorView reapplies long iOS tokens when refreshing inside their range")
    @MainActor
    func syntaxEditorViewIOSRefreshesInteriorOfLongTokens() async {
        let source = String(repeating: "x", count: 80)
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            comment: syntaxEditorUITestColor(hex: 0x305070),
            string: syntaxEditorUITestColor(hex: 0x507030),
            keyword: syntaxEditorUITestColor(hex: 0x703050)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: source.utf16.count),
                    rawCaptureName: "editor.syntax.swift.comment.doc"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 10, length: 2),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 20, length: 2),
                    rawCaptureName: "editor.syntax.swift.string"
                ),
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 30, length: 2),
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
        let refreshRange = NSRange(location: 60, length: 1)

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        let initialForeground = iOSEditorForegroundColor(editorView, at: refreshRange.location)
        #expect(syntaxEditorUITestColorsEqual(initialForeground, theme.comment))
        #expect(
            syntaxEditorUITestColorsEqual(
                iOSEditorPermanentForegroundColor(editorView, at: refreshRange.location),
                theme.baseForeground
            )
        )

        editorView.reapplyTextAttributes(in: refreshRange)

        #expect(
            syntaxEditorUITestColorsEqual(
                iOSEditorPermanentForegroundColor(editorView, at: refreshRange.location),
                theme.baseForeground
            )
        )
        let reappliedForeground = iOSEditorForegroundColor(editorView, at: refreshRange.location)
        #expect(syntaxEditorUITestColorsEqual(reappliedForeground, theme.comment))
    }

    @Test("SyntaxEditorView applies built-in iOS theme base font to plain and highlighted text")
    @MainActor
    func syntaxEditorViewIOSAppliesBuiltInThemeBaseFont() async throws {
        let source = "let\nvalue"
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

        let highlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        let plainFont = try #require(iOSEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - plainFont.pointSize) < 0.01)
        #expect(abs(plainFont.pointSize - 30) < 0.01)
    }

    @Test("SyntaxEditorView keeps iOS syntax attributes out of TextKit storage")
    @MainActor
    func syntaxEditorViewIOSKeepsSyntaxAttributesOutOfTextKitStorage() async throws {
        let source = "/// doc\nlet value = 1"
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 7),
                    rawCaptureName: "editor.syntax.swift.comment.doc"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await editorView.waitForPendingHighlightForTesting()

        let renderedSyntaxFont = try #require(iOSEditorFont(editorView, at: 0))
        let permanentSyntaxFont = try #require(iOSEditorPermanentFont(editorView, at: 0))
        let permanentPlainFont = try #require(iOSEditorPermanentFont(editorView, at: 8))
        let renderedSyntaxForeground = try #require(iOSEditorForegroundColor(editorView, at: 0))
        let permanentSyntaxForeground = try #require(iOSEditorPermanentForegroundColor(editorView, at: 0))
        let permanentPlainForeground = try #require(iOSEditorPermanentForegroundColor(editorView, at: 8))

        #expect(!syntaxEditorUITestFontsEqual(renderedSyntaxFont, permanentSyntaxFont))
        #expect(syntaxEditorUITestFontsEqual(permanentSyntaxFont, permanentPlainFont))
        #expect(!syntaxEditorUITestColorsEqual(renderedSyntaxForeground, permanentSyntaxForeground))
        #expect(syntaxEditorUITestColorsEqual(permanentSyntaxForeground, permanentPlainForeground))
    }

    @Test("SyntaxEditorView applies iOS font size delta to built-in theme fonts")
    @MainActor
    func syntaxEditorViewIOSAppliesFontSizeDeltaToBuiltInThemeFonts() async throws {
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

        let highlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        let plainFont = try #require(iOSEditorFont(editorView, at: 4))
        #expect(abs(highlightedFont.pointSize - plainFont.pointSize) < 0.01)
        #expect(abs(plainFont.pointSize - 33) < 0.01)
    }

    @Test("SyntaxEditorView clamps iOS font size delta")
    @MainActor
    func syntaxEditorViewIOSClampsFontSizeDelta() async throws {
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
        let maximumHighlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        let maximumPlainFont = try #require(iOSEditorFont(editorView, at: 4))
        #expect(abs(maximumHighlightedFont.pointSize - 64) < 0.01)
        #expect(abs(maximumPlainFont.pointSize - 64) < 0.01)

        model.model.fontSizeDelta = -100
        editorView.synchronizeDocumentForTesting()

        let minimumHighlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        let minimumPlainFont = try #require(iOSEditorFont(editorView, at: 4))
        #expect(abs(minimumHighlightedFont.pointSize - 4) < 0.01)
        #expect(abs(minimumPlainFont.pointSize - 4) < 0.01)
    }

    @Test("SyntaxEditorView keeps iOS font size commands aligned with rendered bounds")
    @MainActor
    func syntaxEditorViewIOSKeepsFontSizeCommandsAlignedWithRenderedBounds() throws {
        let model = SyntaxEditorTestContext(
            text: "let value = 1",
            language: SyntaxLanguage.swift,
            theme: .presentationLarge
        )
        let editorView = SyntaxEditorView(testContext: model)

        for _ in 0..<100 {
            model.model.decreaseFontSize()
        }
        editorView.synchronizeDocumentForTesting()

        #expect(model.model.fontSizeDelta == -26)
        let minimumFont = try #require(iOSEditorFont(editorView, at: 0))
        #expect(abs(minimumFont.pointSize - 4) < 0.01)

        model.model.fontSizeDelta = -100
        model.model.increaseFontSize()
        editorView.synchronizeDocumentForTesting()

        #expect(model.model.fontSizeDelta == -25)
        let increasedFont = try #require(iOSEditorFont(editorView, at: 0))
        #expect(abs(increasedFont.pointSize - 5) < 0.01)

        for _ in 0..<100 {
            model.model.increaseFontSize()
        }
        editorView.synchronizeDocumentForTesting()

        #expect(model.model.fontSizeDelta == 34)
        let maximumFont = try #require(iOSEditorFont(editorView, at: 0))
        #expect(abs(maximumFont.pointSize - 64) < 0.01)
    }

    @Test("SyntaxEditorView applies iOS base attributes before delayed highlight")
    @MainActor
    func syntaxEditorViewIOSAppliesBaseAttributesBeforeDelayedHighlight() async throws {
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
            lineWrappingEnabled: true,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await resetGate.waitUntilSuspended()
        #expect(syntaxEditorUITestFontsEqual(iOSEditorFont(editorView, at: 0), editorView.font))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.baseForeground))
        #expect(iOSEditorLineBreakMode(editorView) == .byCharWrapping)

        await resetGate.resumeOne()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(iOSEditorLineBreakMode(editorView) == .byCharWrapping)
    }

    @Test("SyntaxEditorView applies iOS fast pass highlight before final phase")
    @MainActor
    func syntaxEditorViewIOSAppliesFastPassHighlightBeforeFinalPhase() async {
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
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 4), theme.baseForeground))
        #expect(await highlighter.callCount() == 1)

        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))

        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x112233),
            string: syntaxEditorUITestColor(hex: 0x556677),
            keyword: syntaxEditorUITestColor(hex: 0x334455)
        )
        model.model.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(await highlighter.callCount() == 1)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.string))
    }

    @Test("SyntaxEditorView applies iOS incremental fast pass before any complete highlight")
    @MainActor
    func syntaxEditorViewIOSAppliesIncrementalFastPassBeforeAnyCompleteHighlight() async {
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
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))

        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editorView.insertText("x")

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))
        #expect(editorView.text == "\(source)x")

        await completeGate.resumeAll()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView keeps iOS complete incremental materialization inside refresh range")
    @MainActor
    func syntaxEditorViewIOSKeepsCompleteIncrementalMaterializationInsideRefreshRange() async {
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
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        await completeGate.resumeOne()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))

        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        let updateSuspensionCount = await completeGate.currentSuspensionCount()
        editorView.insertText("x")
        await completeGate.waitUntilSuspended(after: updateSuspensionCount)

        await completeGate.resumeAll()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        #expect(editorView.text == "\(source)x")
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(
            syntaxEditorUITestColorsEqual(
                iOSEditorForegroundColor(editorView, at: source.utf16.count),
                theme.keyword
            )
        )
    }

    @Test("SyntaxEditorView applies iOS incremental fast pass after empty complete highlight")
    @MainActor
    func syntaxEditorViewIOSAppliesIncrementalFastPassAfterEmptyCompleteHighlight() async {
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
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        editorView.selectedRange = NSRange(location: 0, length: 0)
        editorView.insertText("l")

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(editorView.text == "l")

        await completeGate.resumeAll()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
    }

    @Test("SyntaxEditorView preserves iOS semantic highlight during incremental fast pass")
    @MainActor
    func syntaxEditorViewIOSPreservesSemanticHighlightDuringIncrementalFastPass() async {
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
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))

        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editorView.insertText("x")

        let skippedFastPass = await editorView.waitForSkippedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass)
        #expect(skippedFastPass)
        #expect(editorView.text == "\(source)x")
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))

        await completeGate.resumeAll()
        if skippedFastPass {
            await editorView.waitForPendingHighlightForTesting()
            #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))
        }
    }

    @Test("SyntaxEditorView preserves iOS semantic highlight across rapid incremental fast passes")
    @MainActor
    func syntaxEditorViewIOSPreservesSemanticHighlightAcrossRapidIncrementalFastPasses() async {
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
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))

        let firstSuspensionCount = await completeGate.currentSuspensionCount()
        editorView.selectedRange = NSRange(location: 0, length: 0)
        editorView.insertText("x")

        await completeGate.waitUntilSuspended(after: firstSuspensionCount)
        #expect(await editorView.waitForSkippedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(editorView.text == "x\(source)")
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 1), theme.string))

        let secondSuspensionCount = await completeGate.currentSuspensionCount()
        editorView.selectedRange = NSRange(location: editorView.text.utf16.count, length: 0)
        editorView.insertText("y")

        await completeGate.waitUntilSuspended(after: secondSuspensionCount)
        #expect(await editorView.waitForSkippedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.syntacticFastPass))
        #expect(editorView.text == "x\(source)y")
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 1), theme.string))

        await completeGate.resumeAll()
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))
    }

    @Test("SyntaxEditorView applies iOS base attributes to inserted text before delayed update highlight")
    @MainActor
    func syntaxEditorViewIOSAppliesBaseAttributesToInsertedTextBeforeDelayedUpdateHighlight() async {
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
        await editorView.waitForPendingHighlightForTesting()

        editorView.selectedRange = NSRange(location: 0, length: 0)
        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.insertText(insertedPrefix)

        await updateGate.waitUntilSuspended(after: previousSuspensionCount)
        #expect(editorView.text == insertedPrefix + source)
        #expect(syntaxEditorUITestFontsEqual(iOSEditorFont(editorView, at: 0), editorView.font))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        await updateGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView keeps iOS command transforms while attribute highlight is applying")
    @MainActor
    func syntaxEditorViewIOSKeepsCommandTransformsWhileAttributeHighlightIsApplying() async {
        let model = SyntaxEditorTestContext(text: "", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())
        await editorView.waitForPendingHighlightForTesting()

        editorView.selectedRange = NSRange(location: 0, length: 0)
        editorView.setApplyingHighlightForTesting(true)
        editorView.insertText("\"")
        editorView.setApplyingHighlightForTesting(false)
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.text == "\"\"")
        #expect(model.model.text == "\"\"")
        #expect(editorView.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("SyntaxEditorView restores iOS base font when syntax font tokens are removed")
    @MainActor
    func syntaxEditorViewIOSRestoresBaseFontWhenSyntaxFontTokensAreRemoved() async throws {
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

        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        let baseFont = try #require(iOSEditorFont(editorView, at: 4))
        let highlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        #expect(!syntaxEditorUITestFontsEqual(highlightedFont, baseFont))

        editorView.selectedRange = NSRange(location: 0, length: 3)
        editorView.insertText("var")
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        #expect(editorView.text == "var value = 1")
        #expect(syntaxEditorUITestFontsEqual(iOSEditorFont(editorView, at: 0), baseFont))
    }

    @Test("SyntaxEditorView restores shifted iOS syntax font after prefix edits")
    @MainActor
    func syntaxEditorViewIOSRestoresShiftedSyntaxFontAfterPrefixEdits() async throws {
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

        await editorView.waitForPendingHighlightForTesting()
        let baseFont = try #require(iOSEditorFont(editorView, at: 4))
        let highlightedFont = try #require(iOSEditorFont(editorView, at: 0))
        #expect(!syntaxEditorUITestFontsEqual(highlightedFont, baseFont))

        editorView.selectedRange = NSRange(location: 0, length: 0)
        editorView.insertText(insertedPrefix)
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.text == insertedPrefix + source)
        #expect(syntaxEditorUITestFontsEqual(iOSEditorFont(editorView, at: insertedPrefix.utf16.count), baseFont))
    }

    @Test("SyntaxEditorView applies dense iOS highlight tokens across the document")
    @MainActor
    func syntaxEditorViewIOSAppliesDenseHighlightTokensAcrossDocument() async {
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
                iOSEditorForegroundColor(editorView, at: 0),
                syntaxEditorDenseHighlightColor(in: theme, at: 0)
            )
        )
        #expect(
            syntaxEditorUITestColorsEqual(
                iOSEditorForegroundColor(editorView, at: middleLocation),
                syntaxEditorDenseHighlightColor(in: theme, at: middleLocation)
            )
        )
        #expect(
            syntaxEditorUITestColorsEqual(
                iOSEditorForegroundColor(editorView, at: lastLocation),
                syntaxEditorDenseHighlightColor(in: theme, at: lastLocation)
            )
        )
        #expect(iOSEditorFont(editorView, at: middleLocation) != nil)
    }

    @Test("SyntaxEditorView preserves iOS paragraph style while reapplying cached highlight")
    @MainActor
    func syntaxEditorViewIOSCachedHighlightPreservesParagraphStyle() async {
        let source = "let value = 1"
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x112233),
            keyword: syntaxEditorUITestColor(hex: 0x332211)
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

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = iOSEditorLineBreakMode(editorView) ?? .byClipping
        paragraphStyle.paragraphSpacing = 11
        editorView.textStorage.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: source.utf16.count)
        )

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), initialTheme.keyword))
        #expect(iOSEditorParagraphSpacing(editorView) == 11)

        model.model.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()
        await editorView.waitForPendingHighlightForTesting()

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
        #expect(iOSEditorParagraphSpacing(editorView) == 11)
    }

    @Test("SyntaxEditorView refreshes iOS TextKit line fragments after async syntax highlight")
    @MainActor
    func syntaxEditorViewIOSRefreshesLineFragmentsAfterAsyncHighlight() async {
        let source = String(
            repeating: "let value = \"text\"\n",
            count: 100
        )
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
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
            lineWrappingEnabled: false,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        layoutIOSEditorView(editorView, width: 393, height: 658)
        await resetGate.waitUntilSuspended()
        #expect(syntaxEditorUITestColorsEqual(iOSEditorLineFragmentForegroundColor(editorView, at: 0), theme.baseForeground))

        await resetGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorLineFragmentForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView applies latest iOS highlight after model replacement")
    @MainActor
    func syntaxEditorViewIOSAppliesLatestHighlightAfterModelReplacement() async {
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
        layoutIOSEditorView(editorView, width: 393, height: 658)
        await resetGate.waitUntilSuspended()
        let previousSuspensionCount = await resetGate.currentSuspensionCount()

        editorView.update(model: replacementModel)
        await resetGate.waitUntilSuspended(after: previousSuspensionCount)
        await resetGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.model === replacementModel)
        #expect(editorView.text == replacementSource)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.string))
        #expect(syntaxEditorUITestColorsEqual(iOSEditorLineFragmentForegroundColor(editorView, at: 0), theme.string))
    }

    @Test("SyntaxEditorView renders iOS pasted text before async highlight completes")
    @MainActor
    func syntaxEditorViewIOSRendersPastedTextBeforeAsyncHighlightCompletes() async {
        let source = "let start = 0\n"
        let pastedText = String(repeating: "let value = 1\n", count: 293)
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
        layoutIOSEditorView(editorView, width: 393, height: 658)
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))
        let initialContentHeight = editorView.contentSize.height

        editorView.selectedRange = NSRange(location: 0, length: 0)
        editorView.insertPastedText(pastedText)
        await updateGate.waitUntilSuspended()
        layoutIOSEditorView(editorView, width: 393, height: 658)
        let pastedContentHeight = editorView.contentSize.height

        #expect(editorView.text == pastedText + source)
        #expect(model.model.text == pastedText + source)
        #expect(pastedContentHeight > initialContentHeight + 1_000)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorLineFragmentForegroundColor(editorView, at: 0), theme.baseForeground))

        let previousSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.selectedRange = NSRange(location: 0, length: pastedText.utf16.count)
        editorView.delete(nil)
        await updateGate.waitUntilSuspended(after: previousSuspensionCount)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.text == source)
        #expect(model.model.text == source)
        #expect(editorView.contentSize.height < pastedContentHeight - 1_000)

        await updateGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView fully applies iOS highlight when skipped revisions precede an incremental result")
    @MainActor
    func syntaxEditorViewIOSFullyAppliesHighlightAfterSkippedIncrementalRevisions() async {
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
            lineWrappingEnabled: false,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        await resetGate.waitUntilSuspended()

        let firstSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.insertPastedText(firstPaste)
        await updateGate.waitUntilSuspended(after: firstSuspensionCount)
        let secondSuspensionCount = await updateGate.currentSuspensionCount()
        editorView.insertPastedText(secondPaste)
        await updateGate.waitUntilSuspended(after: secondSuspensionCount)

        await resetGate.resumeAll()
        await updateGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.text == firstPaste + secondPaste)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
        #expect(
            syntaxEditorUITestColorsEqual(
                iOSEditorForegroundColor(editorView, at: firstPaste.utf16.count),
                theme.keyword
            )
        )
    }

    @Test("SyntaxEditorView preserves iOS syntax colors after editor state changes")
    @MainActor
    func syntaxEditorViewIOSEditorStateDoesNotResetSyntaxColors() async {
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
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutIOSEditorView(editorView)
        #expect(await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete))

        #expect(editorView.syntaxForegroundColorForTesting(at: 0) != nil)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))

        model.model.lineWrappingEnabled = true

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textContainer.widthTracksTextView)
        layoutIOSEditorView(editorView)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))

        model.model.isEditable = false

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.isEditable == false)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView applies iOS font size key commands")
    @MainActor
    func syntaxEditorViewIOSFontSizeKeyCommands() {
        let model = SyntaxEditorTestContext(text: "let answer = 42", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)

        #expect(performSyntaxEditorSelector("syntaxEditorIncreaseFontSize:", on: editorView))
        #expect(model.model.fontSizeDelta == 1)

        #expect(performSyntaxEditorSelector("syntaxEditorDecreaseFontSize:", on: editorView))
        #expect(model.model.fontSizeDelta == 0)

        model.model.fontSizeDelta = 5
        #expect(performSyntaxEditorSelector("syntaxEditorResetFontSize:", on: editorView))
        #expect(model.model.fontSizeDelta == 0)
    }

    @Test("SyntaxEditorView reapplies iOS bracket highlight after syntax refresh")
    @MainActor
    func syntaxEditorViewIOSReappliesBracketHighlightAfterSyntaxRefresh() async {
        let source = "let pair = ()"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        let bracketLocation = (source as NSString).range(of: "(").location
        editorView.selectedRange = NSRange(location: bracketLocation + 1, length: 0)
        await editorView.waitForPendingHighlightForTesting()

        #expect(iOSEditorHasBackgroundAttribute(editorView, at: bracketLocation))

        model.model.replaceText("\(source) ")

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.text == model.model.text)
        await editorView.waitForPendingHighlightForTesting()
        #expect(iOSEditorHasBackgroundAttribute(editorView, at: bracketLocation))
    }

}
#endif
