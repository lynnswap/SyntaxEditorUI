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
    @Test("SyntaxEditorView enables iOS find interaction by default")
    @MainActor
    func syntaxEditorViewIOSEnablesFindInteractionByDefault() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "let value = 1"))

        #expect(editorView.isFindInteractionEnabled)
        #expect(editorView.findInteraction != nil)
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.find(_:)), withSender: nil))
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.findAndReplace(_:)), withSender: nil))
        #expect(!editorView.canPerformAction(#selector(UIResponderStandardEditActions.useSelectionForFind(_:)), withSender: nil))

        editorView.selectedRange = NSRange(location: 4, length: 5)
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.useSelectionForFind(_:)), withSender: nil))

        editorView.isFindInteractionEnabled = false
        #expect(editorView.findInteraction == nil)
        #expect(!editorView.canPerformAction(#selector(UIResponderStandardEditActions.find(_:)), withSender: nil))
        #expect(!editorView.canPerformAction(#selector(UIResponderStandardEditActions.findAndReplace(_:)), withSender: nil))
        #expect(!editorView.canPerformAction(#selector(UIResponderStandardEditActions.useSelectionForFind(_:)), withSender: nil))

        editorView.isFindInteractionEnabled = true
        #expect(editorView.findInteraction != nil)
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.find(_:)), withSender: nil))
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.findAndReplace(_:)), withSender: nil))
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.useSelectionForFind(_:)), withSender: nil))
    }

    @Test("SyntaxEditorView clears iOS find decorations when disabling find interaction")
    @MainActor
    func syntaxEditorViewIOSClearsFindDecorationsWhenDisablingFindInteraction() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "let value = value"))
        let foundRange = NSRange(location: 4, length: 5)
        let highlightedRange = NSRange(location: 12, length: 5)

        editorView.decorateFindTextRange(foundRange, style: .found)
        editorView.decorateFindTextRange(highlightedRange, style: .highlighted)
        #expect(editorView.findFoundRangesForTesting == [foundRange])
        #expect(editorView.findHighlightedRangesForTesting == [highlightedRange])

        editorView.isFindInteractionEnabled = false
        #expect(editorView.findFoundRangesForTesting.isEmpty)
        #expect(editorView.findHighlightedRangesForTesting.isEmpty)
    }

    @Test("SyntaxEditorView batches iOS find decoration redraws during search")
    @MainActor
    func syntaxEditorViewIOSBatchesFindDecorationRedrawsDuringSearch() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "foo foo foo"))
        let ranges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
            NSRange(location: 8, length: 3),
        ]
        let initialUpdatePassCount = editorView.findHighlightUpdatePassCountForTesting

        editorView.beginFindDecorationBatch()
        for range in ranges {
            editorView.decorateFindTextRange(range, style: .found)
        }

        #expect(editorView.findFoundRangesForTesting == ranges)
        #expect(editorView.findHighlightUpdatePassCountForTesting == initialUpdatePassCount)

        editorView.endFindDecorationBatch()
        #expect(editorView.findHighlightUpdatePassCountForTesting == initialUpdatePassCount + 1)
    }

    @Test("SyntaxEditorFindCoordinator matches iOS find options")
    @MainActor
    func syntaxEditorFindCoordinatorIOSMatchesFindOptions() {
        let source = "foo foobar barfoo foo_bar foo"

        #expect(SyntaxEditorFindCoordinator.searchRanges(
            in: source,
            queryString: "foo",
            wordMatchMethod: .contains
        ).count == 5)
        #expect(SyntaxEditorFindCoordinator.searchRanges(
            in: source,
            queryString: "foo",
            wordMatchMethod: .startsWith
        ).count == 4)
        #expect(SyntaxEditorFindCoordinator.searchRanges(
            in: source,
            queryString: "foo",
            wordMatchMethod: .fullWord
        ).count == 2)

        let composedSource = "e\u{301}"
        #expect(SyntaxEditorFindCoordinator.searchRanges(
            in: composedSource,
            queryString: "e",
            compareOptions: [.diacriticInsensitive],
            wordMatchMethod: .contains
        ) == [NSRange(location: 0, length: (composedSource as NSString).length)])

        #expect(SyntaxEditorFindCoordinator.searchRanges(
            in: "é éclair 変数 変数名",
            queryString: "é",
            wordMatchMethod: .fullWord
        ).count == 1)
        #expect(SyntaxEditorFindCoordinator.searchRanges(
            in: "é éclair 変数 変数名",
            queryString: "変数",
            wordMatchMethod: .fullWord
        ).count == 1)
    }

    @Test("SyntaxEditorFindCoordinator exposes iOS replace all selector")
    @MainActor
    func syntaxEditorFindCoordinatorIOSExposesReplaceAllSelector() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "foo foo"))
        let replaceAllSelector = NSSelectorFromString(
            "replaceAllOccurrencesOfQueryString:usingOptions:withText:"
        )

        #expect(editorView.findCoordinator?.responds(to: replaceAllSelector) == true)
    }

    @Test("SyntaxEditorView clips iOS find highlight ranges to a fragment")
    @MainActor
    func syntaxEditorViewIOSClipsFindHighlightRangesToFragment() {
        let ranges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3),
            NSRange(location: 12, length: 2),
            NSRange(location: 15, length: 1),
        ]

        #expect(TextLayoutGeometry.ranges(
            ranges,
            intersecting: NSRange(location: 10, length: 5)
        ) == [
            NSRange(location: 10, length: 1),
            NSRange(location: 12, length: 2),
        ])
    }

    @Test("SyntaxEditorView clears stale iOS find decorations after text changes")
    @MainActor
    func syntaxEditorViewIOSClearsStaleFindDecorationsAfterTextChanges() {
        let model = SyntaxEditorTestContext(text: "let value = value", language: .swift)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.decorateFindTextRange(NSRange(location: 4, length: 5), style: .highlighted)

        model.model.replaceText("let other = other")
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.findFoundRangesForTesting.isEmpty)
        #expect(editorView.findHighlightedRangesForTesting.isEmpty)
    }

    @Test("SyntaxEditorView scrolls iOS highlighted find ranges through the editor scroll pipeline")
    @MainActor
    func syntaxEditorViewIOSScrollsHighlightedFindRangesThroughEditorScrollPipeline() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: .swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 120, height: 80)
        let targetLocation = max(0, longSyntaxEditorLine.utf16.count - 20)
        let targetRange = NSRange(location: targetLocation, length: 5)

        editorView.findCoordinator?.willHighlight(
            foundTextRange: SyntaxEditorView.TextRange(nsRange: targetRange),
            document: 0
        )

        #expect(editorView.contentOffset.x > 0)
    }

    @Test("SyntaxEditorView applies iOS find replacement without command transforms")
    @MainActor
    func syntaxEditorViewIOSAppliesFindReplacementWithoutCommandTransforms() {
        let source = "value"
        let model = SyntaxEditorTestContext(text: source, language: .javascript)
        let editorView = SyntaxEditorView(testContext: model)

        editorView.replaceFindText(in: NSRange(location: 0, length: source.utf16.count), with: "{")
        #expect(model.model.text == "{")
        #expect(editorView.text == "{")

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        undoManager.undo()
        #expect(model.model.text == source)
        #expect(editorView.text == source)
    }

    @Test("SyntaxEditorView applies iOS replace all as one undoable edit")
    @MainActor
    func syntaxEditorViewIOSAppliesReplaceAllAsOneUndoableEdit() {
        let source = "foo foo foo"
        let model = SyntaxEditorTestContext(text: source, language: .javascript)
        let editorView = SyntaxEditorView(testContext: model)

        #expect(editorView.replaceAllFindMatches(
            queryString: "foo",
            compareOptions: [],
            wordMatchMethod: .fullWord,
            with: "bar"
        ))
        #expect(model.model.text == "bar bar bar")
        #expect(editorView.text == "bar bar bar")

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        undoManager.undo()
        #expect(model.model.text == source)
        #expect(editorView.text == source)
    }

    @Test("SyntaxEditorView keeps iOS find available while read-only")
    @MainActor
    func syntaxEditorViewIOSKeepsFindAvailableWhileReadOnly() {
        let source = "foo foo"
        let model = SyntaxEditorTestContext(text: source, language: .javascript, isEditable: false)
        let editorView = SyntaxEditorView(testContext: model)

        #expect(editorView.findInteraction != nil)
        #expect(editorView.canPerformAction(#selector(UIResponderStandardEditActions.find(_:)), withSender: nil))
        #expect(!editorView.canPerformAction(#selector(UIResponderStandardEditActions.findAndReplace(_:)), withSender: nil))
        #expect(editorView.findCoordinator?.supportsTextReplacement == false)
        #expect(!editorView.replaceAllFindMatches(
            queryString: "foo",
            compareOptions: [],
            wordMatchMethod: .fullWord,
            with: "bar"
        ))

        editorView.replaceFindText(in: NSRange(location: 0, length: 3), with: "bar")
        #expect(model.model.text == source)
        #expect(editorView.text == source)
    }

}
#endif
