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
    @Test("SyntaxEditorView keeps macOS selection when setting unchanged text")
    @MainActor
    func syntaxEditorViewMacKeepsSelectionWhenSettingUnchangedText() {
        let source = "abcdef"
        let replacement = "abcdefghi"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())

        model.model.replaceText(
            replacement,
            selectedRange: NSRange(location: replacement.utf16.count, length: 0)
        )
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.selectedRange() == NSRange(location: replacement.utf16.count, length: 0))

        editorView.selectedRange = NSRange(location: 2, length: 0)
        let revision = model.model.textRevision
        let latestTextChange = model.model.latestTextChange

        editorView.text = replacement

        #expect(model.model.textRevision == revision)
        #expect(model.model.latestTextChange == latestTextChange)
        #expect(model.model.selectedRange == NSRange(location: 2, length: 0))
        #expect(editorView.textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test("SyntaxEditorView clips macOS TextKit fragment drawing to dirty lines")
    @MainActor
    func syntaxEditorViewMacClipsTextKitFragmentDrawingToDirtyLines() async throws {
        let source = Array(repeating: "let wrappedValue = wrappedValue", count: 12).joined(separator: " ")
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
            lineWrappingEnabled: true,
            theme: theme,
            fontSizeDelta: 4
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutMacEditorView(editorView, width: 180, height: 160)

        await editorView.waitForPendingHighlightForTesting()
        let fragmentView = try #require(macEditorVisibleFragmentViews(editorView).first)
        let layoutFragment = try #require(fragmentView.layoutFragment as? SyntaxEditorTextInputView.TextLayoutFragment)
        #expect(layoutFragment.textLineFragments.count > 3)

        let initialDrawCount = layoutFragment.lineFragmentDrawCountForTesting
        macEditorDrawFragment(
            fragmentView,
            dirtyRect: NSRect(x: 0, y: 0, width: fragmentView.bounds.width, height: 4),
            backgroundColor: theme.background
        )
        let drawnLineCount = layoutFragment.lineFragmentDrawCountForTesting - initialDrawCount

        #expect(drawnLineCount > 0)
        #expect(drawnLineCount < layoutFragment.textLineFragments.count)
    }

    @Test("SyntaxEditorView redraws macOS text after enabling wrapping from a horizontal scroll")
    @MainActor
    func syntaxEditorViewMacWrappingResetsHorizontalClipOrigin() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let horizontalScrollNeedsWrapping = true; ", count: 32),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutMacEditorView(editorView)

        editorView.textView.frame.size.width = 1_600
        editorView.contentView.scroll(to: NSPoint(x: 600, y: editorView.contentView.bounds.origin.y))
        editorView.reflectScrolledClipView(editorView.contentView)
        #expect(editorView.contentView.bounds.origin.x > 0)

        model.model.lineWrappingEnabled = true

        editorView.synchronizeDocumentForTesting()
        #expect({
            guard let textContainer = editorView.textView.textContainer else {
                return false
            }

            return editorView.hasHorizontalScroller == false
                && editorView.contentView.bounds.origin.x <= 0.5
                && editorView.textView.visibleRect.origin.x <= 0.5
                && editorView.textView.isHorizontallyResizable == false
                && textContainer.widthTracksTextView == true
                && textContainer.lineBreakMode == .byWordWrapping
                && approximatelyEqual(textContainer.containerSize.width, editorView.contentSize.width)
                && approximatelyEqual(editorView.textView.frame.width, editorView.contentSize.width)
        }())
    }

    @Test("SyntaxEditorView recalculates macOS document height after wrapping toggles")
    @MainActor
    func syntaxEditorViewMacWrappingToggleRecalculatesDocumentHeight() async {
        let source = String(repeating: "let wrappingHeightMustTrackVisualLines = true; ", count: 48)
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutMacEditorView(editorView, width: 240, height: 120)
        let unwrappedHeight = editorView.textView.frame.height

        model.model.lineWrappingEnabled = true

        editorView.synchronizeDocumentForTesting()
        layoutMacEditorView(editorView, width: 240, height: 120)
        let wrappedHeight = editorView.textView.frame.height

        #expect(wrappedHeight > unwrappedHeight + 400)

        model.model.lineWrappingEnabled = false

        editorView.synchronizeDocumentForTesting()
        layoutMacEditorView(editorView, width: 240, height: 120)

        #expect(editorView.textView.frame.height < wrappedHeight - 400)
        #expect(approximatelyEqual(editorView.textView.frame.height, unwrappedHeight))
    }

    @Test("SyntaxEditorView does not repaint all macOS text fragments while scrolling")
    @MainActor
    func syntaxEditorViewMacScrollDoesNotInvalidateVisibleFragments() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let value = 1\n", count: 400),
            language: SyntaxLanguage.swift
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutMacEditorView(editorView)

        let visibleInvalidationCount = editorView.visibleTextDisplayInvalidationCountForTesting
        editorView.contentView.scroll(to: NSPoint(x: 0, y: 400))
        editorView.reflectScrolledClipView(editorView.contentView)

        #expect(editorView.visibleTextDisplayInvalidationCountForTesting == visibleInvalidationCount)
    }

    @Test("SyntaxEditorView does not query offscreen macOS caret geometry while scrolling")
    @MainActor
    func syntaxEditorViewMacScrollDoesNotQueryOffscreenCaretGeometry() {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let value = 1\n", count: 1_200),
            language: SyntaxLanguage.swift
        )
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(editorView.textView))
        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let initialQueryCount = editorView.textView.caretGeometryQueryCountForTesting

        editorView.contentView.scroll(to: NSPoint(x: 0, y: 2_000))
        editorView.reflectScrolledClipView(editorView.contentView)

        #expect(editorView.textView.caretGeometryQueryCountForTesting == initialQueryCount)
        #expect(editorView.textView.insertionIndicatorDisplayModeForTesting == .hidden)
        #expect(editorView.textView.insertionIndicatorIsHiddenForTesting)
    }

    @Test("SyntaxEditorView does not fan out macOS content invalidation to every text fragment")
    @MainActor
    func syntaxEditorViewMacContentInvalidationDoesNotInvalidateAllFragments() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let value = 1\n", count: 400),
            language: SyntaxLanguage.swift
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutMacEditorView(editorView)

        let fragmentInvalidationCount = editorView.fragmentDisplayInvalidationCountForTesting
        editorView.textView.textContentView.setNeedsDisplay(editorView.textView.bounds)

        #expect(editorView.fragmentDisplayInvalidationCountForTesting == fragmentInvalidationCount)
    }

    @Test("SyntaxEditorView wraps to unobscured macOS content width")
    @MainActor
    func syntaxEditorViewMacWrappingAccountsForContentInsets() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let insetAwareWrappingWidth = true; ", count: 16),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.automaticallyAdjustsContentInsets = false
        editorView.contentInsets = NSEdgeInsets(top: 12, left: 80, bottom: 18, right: 24)
        layoutMacEditorView(editorView, width: 360, height: 160)

        #expect({
            guard let textContainer = editorView.textView.textContainer else {
                return false
            }

            let unobscuredContentSize = macUnobscuredContentSize(editorView)
            let expectedClipOriginX = -editorView.contentView.contentInsets.left
            return editorView.hasHorizontalScroller == false
                && approximatelyEqual(editorView.contentView.bounds.origin.x, expectedClipOriginX)
                && textContainer.widthTracksTextView == true
                && approximatelyEqual(textContainer.containerSize.width, unobscuredContentSize.width)
                && approximatelyEqual(editorView.textView.frame.width, unobscuredContentSize.width)
                && approximatelyEqual(editorView.textView.minSize.height, unobscuredContentSize.height)
        }())
    }

    @Test("SyntaxEditorView keeps short macOS content non-scrollable with top insets")
    @MainActor
    func syntaxEditorViewMacShortContentAccountsForTopInsets() async {
        let insetCases = [
            NSEdgeInsets(top: 54, left: 0, bottom: 12, right: 0),
            NSEdgeInsets(top: 16, left: 40, bottom: 28, right: 24),
            NSEdgeInsets(top: 0, left: 20, bottom: 44, right: 36),
        ]

        for lineWrappingEnabled in [true, false] {
            for contentInsets in insetCases {
                let model = SyntaxEditorTestContext(
                    text: #"{"result":"ok"}"#,
                    language: SyntaxLanguage.json,
                    lineWrappingEnabled: lineWrappingEnabled
                )
                let editorView = SyntaxEditorView(testContext: model)
                editorView.automaticallyAdjustsContentInsets = false
                editorView.contentInsets = contentInsets
                layoutMacEditorView(editorView, width: 360, height: 240)

                let unobscuredContentSize = macUnobscuredContentSize(editorView)

                #expect(approximatelyEqual(editorView.textView.frame.height, unobscuredContentSize.height))
                #expect(approximatelyEqual(editorView.textView.minSize.height, unobscuredContentSize.height))
                #expect(editorView.textView.frame.height <= unobscuredContentSize.height + 0.5)
            }
        }
    }

    @Test("SyntaxEditorView updates macOS wrapping geometry after resize")
    @MainActor
    func syntaxEditorViewMacWrappingTracksResizedContentWidth() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let resizedWrappingWidth = true; ", count: 16),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutMacEditorView(editorView, width: 520, height: 180)

        #expect({
            guard let textContainer = editorView.textView.textContainer else {
                return false
            }

            return approximatelyEqual(textContainer.containerSize.width, editorView.contentSize.width)
                && approximatelyEqual(editorView.textView.frame.width, editorView.contentSize.width)
        }())

        layoutMacEditorView(editorView, width: 240, height: 180)

        #expect({
            guard let textContainer = editorView.textView.textContainer else {
                return false
            }

            return editorView.contentView.bounds.origin.x <= 0.5
                && approximatelyEqual(textContainer.containerSize.width, editorView.contentSize.width)
                && approximatelyEqual(editorView.textView.frame.width, editorView.contentSize.width)
        }())
    }

    @Test("SyntaxEditorView does not rebuild macOS line metrics during resize")
    @MainActor
    func syntaxEditorViewMacResizeDoesNotRebuildLineMetrics() async {
        let longLine = String(
            repeating: "let extremelyLongIdentifierName = syntaxEditorHorizontalScrollValue; ",
            count: 4
        )
        let source = (0..<2_000)
            .map { index in
                index == 1_500 ? longLine : "let value\(index) = \(index)"
            }
            .joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutMacEditorView(editorView, width: 720, height: 300)

        let rebuildCount = editorView.lineMetricsFullRebuildCountForTesting
        layoutMacEditorView(editorView, width: 360, height: 300)
        layoutMacEditorView(editorView, width: 640, height: 300)

        #expect(editorView.lineMetricsFullRebuildCountForTesting == rebuildCount)
        #expect(approximatelyEqual(editorView.textView.frame.width, editorView.contentSize.width))
    }

    @Test("SyntaxEditorView keeps unwrapped long macOS content minimum height tied to unobscured insets")
    @MainActor
    func syntaxEditorViewMacUnwrappedLongContentAccountsForTopInsets() async {
        let source = (0..<80)
            .map { "let value\($0) = \(String(repeating: "x", count: 24))" }
            .joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.automaticallyAdjustsContentInsets = false
        editorView.contentInsets = NSEdgeInsets(top: 48, left: 24, bottom: 32, right: 36)
        layoutMacEditorView(editorView, width: 360, height: 180)

        let unobscuredContentSize = macUnobscuredContentSize(editorView)

        #expect(editorView.hasHorizontalScroller)
        #expect(approximatelyEqual(editorView.textView.minSize.height, unobscuredContentSize.height))
        #expect(editorView.textView.frame.height > unobscuredContentSize.height + 1)
        #expect(editorView.textView.frame.width >= unobscuredContentSize.width)
    }

    @Test("SyntaxEditorView keeps inset macOS wrapping geometry after resize")
    @MainActor
    func syntaxEditorViewMacWrappingTracksInsetContentWidthAfterResize() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let insetResizeWrappingWidth = true; ", count: 16),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.automaticallyAdjustsContentInsets = false
        editorView.contentInsets = NSEdgeInsets(top: 0, left: 96, bottom: 0, right: 44)
        layoutMacEditorView(editorView, width: 560, height: 180)

        #expect({
            guard let textContainer = editorView.textView.textContainer else {
                return false
            }

            let contentInsets = editorView.contentView.contentInsets
            let expectedWidth = editorView.contentSize.width - contentInsets.left - contentInsets.right
            let expectedClipOriginX = -contentInsets.left
            return approximatelyEqual(editorView.contentView.bounds.origin.x, expectedClipOriginX)
                && approximatelyEqual(textContainer.containerSize.width, expectedWidth)
                && approximatelyEqual(editorView.textView.frame.width, expectedWidth)
        }())

        layoutMacEditorView(editorView, width: 320, height: 180)

        #expect({
            guard let textContainer = editorView.textView.textContainer else {
                return false
            }

            let contentInsets = editorView.contentView.contentInsets
            let expectedWidth = editorView.contentSize.width - contentInsets.left - contentInsets.right
            let expectedClipOriginX = -contentInsets.left
            return approximatelyEqual(editorView.contentView.bounds.origin.x, expectedClipOriginX)
                && approximatelyEqual(textContainer.containerSize.width, expectedWidth)
                && approximatelyEqual(editorView.textView.frame.width, expectedWidth)
        }())
    }

    @Test("SyntaxEditorView recomputes macOS wrapping geometry after content inset changes")
    @MainActor
    func syntaxEditorViewMacWrappingGeometryTracksContentInsetChanges() async {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let dynamicInsetWrappingWidth = true; ", count: 24),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.automaticallyAdjustsContentInsets = false
        layoutMacEditorView(editorView, width: 520, height: 220)

        guard let textContainer = editorView.textView.textContainer else {
            Issue.record("SyntaxEditorView did not create a text container")
            return
        }
        let initialContainerWidth = textContainer.containerSize.width

        editorView.contentInsets = NSEdgeInsets(top: 28, left: 72, bottom: 36, right: 40)
        layoutMacEditorView(editorView, width: 520, height: 220)

        let unobscuredContentSize = macUnobscuredContentSize(editorView)
        let expectedClipOriginX = -editorView.contentView.contentInsets.left

        #expect(approximatelyEqual(editorView.contentView.bounds.origin.x, expectedClipOriginX))
        #expect(textContainer.containerSize.width < initialContainerWidth)
        #expect(approximatelyEqual(textContainer.containerSize.width, unobscuredContentSize.width))
        #expect(approximatelyEqual(editorView.textView.frame.width, unobscuredContentSize.width))
        #expect(approximatelyEqual(editorView.textView.minSize.height, unobscuredContentSize.height))
    }

    @Test("SyntaxEditorView keeps synchronizing after language changes on macOS")
    @MainActor
    func syntaxEditorViewMacLanguageChangeKeepsObservationAlive() async {
        let model = SyntaxEditorTestContext(text: "let answer = 42", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)

        model.model.language = SyntaxLanguage.json
        model.model.isEditable = false

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.isEditable == false)

        model.model.replaceText("{\"answer\":42}")

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.string == "{\"answer\":42}")
    }

    @Test("SyntaxEditorView shows the macOS insertion indicator for caret selections")
    @MainActor
    func syntaxEditorViewMacShowsInsertionIndicatorForCaretSelections() {
        let source = "let value = 1"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(editorView.textView))
        editorView.textView.setSelectedRange(NSRange(location: 4, length: 0))

        #expect(editorView.textView.insertionIndicatorDisplayModeForTesting == .automatic)
        #expect(!editorView.textView.insertionIndicatorIsHiddenForTesting)
        #expect(!editorView.textView.insertionIndicatorFrameForTesting.isEmpty)
    }

    @Test("SyntaxEditorView draws macOS selection overlay in rendered fragments")
    @MainActor
    func syntaxEditorViewMacDrawsSelectionOverlayInRenderedFragments() {
        let source = "let value = 1"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(editorView.textView))
        editorView.textView.setSelectedRange((source as NSString).range(of: "value"))

        #expect(!editorView.textView.selectionHighlightRectsForTesting.isEmpty)
        #expect(editorView.textView.insertionIndicatorDisplayModeForTesting == .hidden)
        #expect(editorView.textView.insertionIndicatorIsHiddenForTesting)
    }

    @Test("SyntaxEditorView updates macOS mouse drag selections")
    @MainActor
    func syntaxEditorViewMacUpdatesMouseDragSelections() {
        let source = "let value = 1"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        let startPoint = macEditorWindowPoint(
            in: window,
            textView: editorView.textView,
            characterRange: NSRange(location: 0, length: 1)
        )
        let endPoint = macEditorWindowPoint(
            in: window,
            textView: editorView.textView,
            characterRange: NSRange(location: 8, length: 1)
        )
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ),
            let mouseDragged = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: endPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        else {
            Issue.record("Failed to create macOS mouse events")
            return
        }

        editorView.textView.mouseDown(with: mouseDown)
        editorView.textView.mouseDragged(with: mouseDragged)

        #expect(editorView.textView.selectedRange().location == 0)
        #expect(editorView.textView.selectedRange().length > 0)
    }

}
#endif
