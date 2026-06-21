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
    @Test("SyntaxEditorView enables macOS find bar by default")
    @MainActor
    func syntaxEditorViewMacEnablesFindBarByDefault() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "let value = 1"))

        #expect(editorView.isFindInteractionEnabled)
        #expect(editorView.textView.usesFindBar)
        #expect(editorView.textView.isIncrementalSearchingEnabled)
        #expect(!editorView.textView.usesFindPanel)

        let showFindItem = NSMenuItem()
        showFindItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        editorView.textView.performTextFinderAction(showFindItem)
        #expect(editorView.isFindBarVisible)

        editorView.isFindInteractionEnabled = false
        #expect(!editorView.textView.usesFindBar)
        #expect(!editorView.textView.isIncrementalSearchingEnabled)
        #expect(!editorView.textView.usesFindPanel)
        #expect(!editorView.isFindBarVisible)

        editorView.isFindInteractionEnabled = true
        #expect(editorView.textView.usesFindBar)
        #expect(editorView.textView.isIncrementalSearchingEnabled)
        #expect(!editorView.textView.usesFindPanel)
    }

    @Test("SyntaxEditorView exposes AppKit text layout geometry to NSTextFinder")
    @MainActor
    func syntaxEditorViewExposesTextLayoutGeometryToTextFinder() {
        let source = "first line\nsecond line\nthird line"
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: source))
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        let contentView = editorView.textView.contentView(at: 0, effectiveCharacterRange: &effectiveRange)

        #expect(contentView === editorView.textView.textContentView)
        #expect(effectiveRange == NSRange(location: 0, length: (source as NSString).length))

        let secondLineRange = (source as NSString).range(of: "second")
        let rects = editorView.textView.rects(forCharacterRange: secondLineRange) ?? []

        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { !$0.rectValue.isEmpty })
    }

    @Test("SyntaxEditorView uses macOS NSTextFinder for match navigation")
    @MainActor
    func syntaxEditorViewMacUsesTextFinderForMatchNavigation() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "alpha beta alpha"))
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        editorView.selectedRange = NSRange(location: 0, length: 5)
        let setSearchStringItem = NSMenuItem()
        setSearchStringItem.tag = NSTextFinder.Action.setSearchString.rawValue
        editorView.textView.performTextFinderAction(setSearchStringItem)

        let nextMatchItem = NSMenuItem()
        nextMatchItem.tag = NSTextFinder.Action.nextMatch.rawValue
        editorView.textView.performTextFinderAction(nextMatchItem)

        #expect(editorView.selectedRange == NSRange(location: 11, length: 5))
    }

    @Test("SyntaxEditorView applies macOS NSTextFinder replacements through the editor pipeline")
    @MainActor
    func syntaxEditorViewMacAppliesTextFinderReplacementThroughEditorPipeline() {
        let model = SyntaxEditorTestContext(text: "alpha beta")
        let editorView = SyntaxEditorView(testContext: model)

        editorView.textView.replaceCharacters(in: NSRange(location: 0, length: 5), with: "omega")

        #expect(model.model.text == "omega beta")
        #expect(editorView.selectedRange == NSRange(location: 5, length: 0))
    }

    @Test("SyntaxEditorView keeps macOS find bar available while read-only")
    @MainActor
    func syntaxEditorViewMacKeepsFindBarAvailableWhileReadOnly() {
        let model = SyntaxEditorTestContext(text: "let value = 1", isEditable: false)
        let editorView = SyntaxEditorView(testContext: model)

        #expect(editorView.isFindInteractionEnabled)
        #expect(editorView.textView.usesFindBar)
        #expect(editorView.textView.isIncrementalSearchingEnabled)
        #expect(editorView.textView.isEditable == false)

        model.model.isEditable = true
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.usesFindBar)
        #expect(editorView.textView.isIncrementalSearchingEnabled)
        #expect(editorView.textView.isEditable)

        model.model.isEditable = false
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.usesFindBar)
        #expect(editorView.textView.isIncrementalSearchingEnabled)
        #expect(editorView.textView.isEditable == false)
    }

    @Test("SyntaxEditorView draws macOS incremental find candidates in rendered fragments")
    @MainActor
    func syntaxEditorViewMacDrawsIncrementalFindCandidatesInRenderedFragments() {
        let source = "m m m"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        editorView.textView.setFindHighlightRangesForTesting([
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 1),
            NSRange(location: 4, length: 1),
        ])

        #expect(editorView.textView.findHighlightRectsForTesting.count >= 3)
        #expect(!editorView.textView.findCandidateHighlightFillColorForTesting.isEqual(NSColor.yellow))
        #expect(editorView.textView.findCandidateHighlightCornerRadiusForTesting > 0)

        let invalidationCount = editorView.fragmentDisplayInvalidationCountForTesting
        editorView.textView.setNeedsDisplayForVisibleTextFragments()
        #expect(editorView.fragmentDisplayInvalidationCountForTesting > invalidationCount)
    }

    @Test("SyntaxEditorView limits macOS incremental find candidates to visible fragments")
    @MainActor
    func syntaxEditorViewMacFindHighlightsIgnoreOffscreenRanges() {
        let source = (0..<500)
            .map { "match \($0)" }
            .joined(separator: "\n")
        let nsSource = source as NSString
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        let offscreenRanges = (250..<500).map { nsSource.range(of: "match \($0)") }
        editorView.textView.setFindHighlightRangesForTesting(offscreenRanges)
        #expect(editorView.textView.findHighlightRectsForTesting.isEmpty)

        let visibleRange = nsSource.range(of: "match 0")
        editorView.textView.setFindHighlightRangesForTesting(offscreenRanges + [visibleRange])
        #expect(editorView.textView.findHighlightRectsForTesting.count == 1)
    }

    @Test("SyntaxEditorView excludes the current macOS find match from candidate highlights")
    @MainActor
    func syntaxEditorViewMacFindHighlightsExcludeCurrentMatch() {
        let source = "m m m"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        editorView.textView.setSelectedRange(NSRange(location: 2, length: 1))
        #expect(editorView.textView.selectedRange() == NSRange(location: 2, length: 1))
        editorView.textView.setFindHighlightRangesForTesting([
            NSRange(location: 0, length: 1),
            NSRange(location: 4, length: 1),
        ])
        let nonCurrentMatchRectCount = editorView.textView.findHighlightRectsForTesting.count
        #expect(nonCurrentMatchRectCount > 0)

        editorView.textView.setFindHighlightRangesForTesting([
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 1),
            NSRange(location: 4, length: 1),
        ])

        #expect(editorView.textView.findHighlightRectsForTesting.count == nonCurrentMatchRectCount)
    }

    @Test("SyntaxEditorView clears macOS find candidate highlights")
    @MainActor
    func syntaxEditorViewMacClearsFindCandidateHighlights() {
        let source = "m m m"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        editorView.textView.setFindHighlightRangesForTesting([
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 1),
        ])
        #expect(!editorView.textView.findHighlightRectsForTesting.isEmpty)

        editorView.textView.setFindHighlightRangesForTesting([])
        #expect(editorView.textView.findHighlightRectsForTesting.isEmpty)

        editorView.textView.setFindHighlightRangesForTesting([
            NSRange(location: 4, length: 1),
        ])
        #expect(!editorView.textView.findHighlightRectsForTesting.isEmpty)

        editorView.textView.setFindHighlightRangesForTesting(nil)
        #expect(editorView.textView.findHighlightRectsForTesting.isEmpty)
    }

}
#endif
