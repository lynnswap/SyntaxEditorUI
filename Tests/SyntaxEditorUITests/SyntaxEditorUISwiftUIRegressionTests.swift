import Foundation
import Testing
@testable import SyntaxEditorUI

#if canImport(UIKit)
import UIKit
@testable import SyntaxEditorUIUIKit
#endif

#if canImport(AppKit)
import AppKit
@testable import SyntaxEditorUIAppKit
#endif

/// Test waits are purely event-driven (no wall-clock timeouts, mirroring
/// ObservationBridge); the time limit is the only failure detector for a
/// pipeline that never settles, so it bounds hangs without ever racing a
/// slow-but-correct run into a flaky false.
@Suite("SyntaxEditorUI", .serialized, .timeLimit(.minutes(1)))
struct SyntaxEditorUITests {}

extension SyntaxEditorUITests {
    @Test("SyntaxEditorView clears undo state when rebinding document")
    @MainActor
    func syntaxEditorViewClearsUndoStateWhenRebindingDocument() throws {
        let source = "let value = 1"
        let editedSource = "\(source)!"
        let replacementDocument = SyntaxEditorModel(text: "let other = 2")
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)

#if canImport(UIKit)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editorView.insertText("!")
        let undoManager = try #require(editorView.undoManager)

        #expect(model.model.text == editedSource)
        #expect(undoManager.canUndo)

        editorView.update(model: replacementDocument)

        #expect(editorView.model === replacementDocument)
        #expect(editorView.text == replacementDocument.text)
        #expect(!undoManager.canUndo)
#elseif canImport(AppKit)
        let editorView = SyntaxEditorView(testContext: model)
        let undoManager = try #require(editorView.textView.undoManager)
        let editRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(editRange)
        editorView.textView.insertText("!", replacementRange: editRange)
        editorView.textView.breakUndoCoalescing()

        #expect(model.model.text == editedSource)
        #expect(undoManager.canUndo)

        editorView.update(model: replacementDocument)

        #expect(editorView.model === replacementDocument)
        #expect(editorView.textView.string == replacementDocument.text)
        #expect(!undoManager.canUndo)
#endif
    }

    @Test("SyntaxEditorView clears undo state for observed whole document replacements")
    @MainActor
    func syntaxEditorViewClearsUndoStateForObservedWholeDocumentReplacements() throws {
        let source = "abc"
        let editedSource = "\(source)!"
        let replacementText = "x"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)

#if canImport(UIKit)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editorView.insertText("!")
        let undoManager = try #require(editorView.undoManager)

        #expect(model.model.text == editedSource)
        #expect(undoManager.canUndo)

        model.model.replaceText(replacementText)
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.text == replacementText)
        #expect(!undoManager.canUndo)
#elseif canImport(AppKit)
        let editorView = SyntaxEditorView(testContext: model)
        let undoManager = try #require(editorView.textView.undoManager)
        let editRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(editRange)
        editorView.textView.insertText("!", replacementRange: editRange)
        editorView.textView.breakUndoCoalescing()

        #expect(model.model.text == editedSource)
        #expect(undoManager.canUndo)

        model.model.replaceText(replacementText)
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.textView.string == replacementText)
        #expect(!undoManager.canUndo)
#endif
    }

    @Test("SyntaxEditorView does not reuse cached highlights after document rebind")
    @MainActor
    func syntaxEditorViewDoesNotReuseCachedHighlightsAfterDocumentRebind() async {
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x345678)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x654321),
            keyword: syntaxEditorUITestColor(hex: 0x876543)
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
            text: "let old = 1",
            language: SyntaxLanguage.swift,
            theme: initialTheme
        )
        let replacementDocument = SyntaxEditorModel(text: "abc new = 1", language: .swift)

#if canImport(UIKit)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let didSuspendInitialHighlight = await resetGate.waitUntilSuspended()
        #expect(didSuspendInitialHighlight)
        guard didSuspendInitialHighlight else { return }
        await resetGate.resumeAll()
        let didApplyInitialHighlight = await editorView.waitForPendingHighlightForTesting()
        #expect(didApplyInitialHighlight)
        guard didApplyInitialHighlight else { return }
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), initialTheme.keyword))

        let previousSuspensionCount = await resetGate.currentSuspensionCount()
        editorView.update(model: replacementDocument)
        replacementDocument.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()

        let didSuspendReplacementHighlight = await resetGate.waitUntilSuspended(after: previousSuspensionCount)
        #expect(didSuspendReplacementHighlight)
        guard didSuspendReplacementHighlight else { return }
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.baseForeground))
        await resetGate.resumeAll()
        let didApplyReplacementHighlight = await editorView.waitForAppliedHighlightPhaseForTesting(SyntaxEditorHighlighting.Result.Phase.complete)
        #expect(didApplyReplacementHighlight)
        guard didApplyReplacementHighlight else { return }
        #expect(syntaxEditorUITestColorsEqual(iOSEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
#elseif canImport(AppKit)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        let didSuspendInitialHighlight = await resetGate.waitUntilSuspended()
        #expect(didSuspendInitialHighlight)
        guard didSuspendInitialHighlight else { return }
        let didResumeInitialHighlight = await resetGate.resumeOne()
        #expect(didResumeInitialHighlight)
        guard didResumeInitialHighlight else { return }
        let didApplyInitialHighlight = await editorView.waitForPendingHighlightForTesting()
        #expect(didApplyInitialHighlight)
        guard didApplyInitialHighlight else { return }
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), initialTheme.keyword))

        let previousSuspensionCount = await resetGate.currentSuspensionCount()
        editorView.update(model: replacementDocument)
        replacementDocument.theme = updatedTheme
        editorView.synchronizeDocumentForTesting()

        let didSuspendReplacementHighlight = await resetGate.waitUntilSuspended(after: previousSuspensionCount)
        #expect(didSuspendReplacementHighlight)
        guard didSuspendReplacementHighlight else { return }
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.baseForeground))
        let didResumeReplacementHighlight = await resetGate.resumeOne()
        #expect(didResumeReplacementHighlight)
        guard didResumeReplacementHighlight else { return }
        let didApplyReplacementHighlight = await editorView.waitForPendingHighlightForTesting()
        #expect(didApplyReplacementHighlight)
        guard didApplyReplacementHighlight else { return }
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), updatedTheme.keyword))
#endif
    }

}
