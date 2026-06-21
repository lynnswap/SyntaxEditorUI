#if canImport(UIKit)
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView {
    func applyUserReplacement(
        in range: NSRange,
        replacement: String,
        deletionIntent: EditorCommandEngine.DeletionIntent,
        allowsCommandTransform: Bool = true
    ) {
        guard model.isEditable else {
            return
        }

        let source = text
        let clampedRange = clampedTextRange(range, in: source)

        if allowsCommandTransform,
           !isApplyingModel,
           let result = commandEngine.transformInput(
               source: source,
               range: clampedRange,
               replacementText: replacement,
               language: model.language,
               deletionIntent: deletionIntent
           ) {
            applyCommandResult(result)
            return
        }

        let nextSelection = NSRange(
            location: clampedRange.location + replacement.utf16.count,
            length: 0
        )

        commitTextReplacements(
            [SyntaxEditorTextChange.Replacement(range: clampedRange, replacement: replacement)],
            selectedRange: nextSelection,
            refreshStartUTF16: SyntaxEditorRangeUtilities.lineStartUTF16Offset(
                in: source,
                around: clampedRange.location
            )
        )
    }

    func replaceFindText(in range: NSRange, with replacement: String) {
        applyUserReplacement(
            in: range,
            replacement: replacement,
            deletionIntent: .unspecified,
            allowsCommandTransform: false
        )
    }

    @discardableResult
    func replaceAllFindMatches(
        queryString: String,
        compareOptions: NSString.CompareOptions,
        wordMatchMethod: UITextSearchOptions.WordMatchMethod,
        with replacement: String
    ) -> Bool {
        guard model.isEditable else { return false }

        let source = text
        let ranges = SyntaxEditorFindCoordinator.searchRanges(
            in: source,
            queryString: queryString,
            compareOptions: compareOptions,
            wordMatchMethod: wordMatchMethod
        )
        guard let firstRange = ranges.first else { return false }

        let edits = ranges.map {
            SyntaxEditorTextChange.Replacement(range: $0, replacement: replacement)
        }
        let nextTextLength = source.utf16.count + ranges.reduce(0) { total, range in
            total + replacement.utf16.count - range.length
        }

        let selectionLocation = min(
            firstRange.location + replacement.utf16.count,
            nextTextLength
        )
        let refreshStartUTF16 = SyntaxEditorRangeUtilities.lineStartUTF16Offset(
            in: source,
            around: selectionLocation
        )
        commitTextReplacements(
            edits,
            selectedRange: NSRange(location: selectionLocation, length: 0),
            refreshStartUTF16: refreshStartUTF16
        )
        return true
    }

    func replaceDocumentText(_ nextText: String) {
        let previousText = text
        guard previousText != nextText else {
            updateTypingAttributes()
            return
        }

        isApplyingModel = true
        defer {
            isApplyingModel = false
        }

        commandEngine.invalidateTransientState()
        let nextSelection = clampedTextRange(selectedRange, in: nextText)
        let change = model.replaceText(
            nextText,
            selectedRange: nextSelection
        )
        guard let change else {
            updateTypingAttributes()
            return
        }
        lastAppliedDocumentRevision = change.textRevision
        currentSelectedRange = change.selectedRange
        replaceEntireStorageText(nextText)
        updateTypingAttributes()
        updateTextContainerForCurrentWrappingMode()
        invalidateTextLayout()
        scheduleHighlight(
            source: nextText,
            language: model.language,
            revision: change.textRevision,
            refreshStartUTF16: 0
        )
        refreshKeyboardAccessoryState()
    }

    func commitTextReplacements(
        _ edits: [SyntaxEditorTextChange.Replacement],
        selectedRange nextSelection: NSRange,
        refreshStartUTF16: Int,
        registersUndo: Bool = true,
        preservesMarkedTextUndoAnchor: Bool = false,
        preservesCommandState: Bool = false,
        notifiesInputDelegate: Bool = true
    ) {
        guard model.isEditable else {
            refreshKeyboardAccessoryState()
            return
        }

        guard !edits.isEmpty else {
            setSelectedRange(
                clampedTextRange(nextSelection),
                preservesCommandState: preservesCommandState,
                schedulesSelectionScroll: true
            )
            applyMatchingBracketHighlight()
            refreshKeyboardAccessoryState()
            return
        }

        let previousText = text
        let previousSelection = selectedRange

        if registersUndo, !isApplyingUndoRedo {
            registerUndoAction(
                restore: EditorCommandEngine.UndoState(
                    edits: SyntaxEditorModel.inverseReplacements(for: edits, in: previousText),
                    selectedRange: previousSelection,
                    refreshStartUTF16: SyntaxEditorRangeUtilities.lineStartUTF16Offset(
                        in: previousText,
                        around: refreshStartUTF16
                    )
                ),
                counterpart: EditorCommandEngine.UndoState(
                    edits: edits,
                    selectedRange: nextSelection,
                    refreshStartUTF16: refreshStartUTF16
                )
            )
        }

        isApplyingModel = true
        if notifiesInputDelegate {
            inputDelegate?.textWillChange(self)
            inputDelegate?.selectionWillChange(self)
        }

        performWithoutUndoRegistration {
            performRawEdits(
                edits,
                previousText: previousText,
                preservesMarkedTextUndoAnchor: preservesMarkedTextUndoAnchor
            )
        }
        let shouldDeferSelectionGeometry = shouldDeferSelectionGeometryForTextInputEdits(edits)

        let change = model.commitTextReplacements(
            edits,
            selectedRange: nextSelection
        )
        guard let change else {
            isApplyingModel = false
            refreshKeyboardAccessoryState()
            return
        }
        lastAppliedDocumentRevision = change.textRevision
        let nextText = model.text
        currentSelectedRange = clampedTextRange(nextSelection, in: nextText)
        syncTextLayoutSelection()
        updateTypingAttributes()
        updateTextContainerForCurrentWrappingMode()
        if shouldDeferSelectionGeometry {
            scheduleScrollSelectionToVisibleIfNeeded()
        } else {
            layoutAndScrollSelectionForTextInputGeometry()
        }
        isApplyingModel = false

        let refreshStart = min(
            refreshStartUTF16,
            edits.map(\.range.location).min() ?? refreshStartUTF16
        )
        scheduleHighlight(
            source: nextText,
            language: model.language,
            revision: change.textRevision,
            mutation: Self.highlightMutation(change),
            refreshStartUTF16: refreshStart
        )
        handleSelectionDidChange(preservesCommandState: preservesCommandState)

        if notifiesInputDelegate {
            inputDelegate?.selectionDidChange(self)
            inputDelegate?.textDidChange(self)
        }
        refreshKeyboardAccessoryState()
    }

    private func shouldDeferSelectionGeometryForTextInputEdits(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
        edits.contains { edit in
            edit.range.length > 4_096 || edit.replacement.utf16.count > 4_096
        }
    }

    func performRawEdits(
        _ edits: [SyntaxEditorTextChange.Replacement],
        previousText: String,
        preservesMarkedTextUndoAnchor: Bool = false
    ) {
        textContentStorage.performEditingTransaction {
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                if edit.replacement.isEmpty {
                    storage.replaceCharacters(in: edit.range, with: "")
                } else {
                    storage.replaceCharacters(
                        in: edit.range,
                        with: NSAttributedString(string: edit.replacement, attributes: typingAttributes)
                    )
                }
            }
        }
        lineMetrics.apply(edits: edits, previousSource: previousText)
        updateTextContainerForCurrentWrappingMode()
        updateContentSizeIfNeeded()
        invalidateFindResultsAfterTextChange()
        if !preservesMarkedTextUndoAnchor {
            markedTextUndoAnchor = nil
        }
        markedRange = nil
        invalidateTextLayout()
    }

    func applyCommandResult(_ result: EditorCommandEngine.Result) {
        guard model.isEditable else {
            refreshKeyboardAccessoryState()
            return
        }

        commitTextReplacements(
            result.edits,
            selectedRange: result.selectedRange,
            refreshStartUTF16: result.refreshStartUTF16,
            preservesCommandState: true
        )
    }

    func registerUndoAction(restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState) {
        guard restore != counterpart else { return }
        guard let activeUndoManager else { return }

        registerUndoAction(restore: restore, counterpart: counterpart, in: activeUndoManager)
    }

    func registerUndoAction(
        restore: EditorCommandEngine.UndoState,
        counterpart: EditorCommandEngine.UndoState,
        in undoManager: UndoManager
    ) {
        guard restore != counterpart else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.applyUndoAction(restore: restore, counterpart: counterpart)
        }

        if !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName("Edit")
        }
    }

    func applyUndoAction(restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState) {
        guard model.isEditable else {
            return
        }

        registerUndoAction(restore: counterpart, counterpart: restore)

        isApplyingUndoRedo = true
        applyCommandResult(
            EditorCommandEngine.Result(
                edits: restore.edits,
                selectedRange: restore.selectedRange,
                refreshStartUTF16: restore.refreshStartUTF16
            )
        )
        isApplyingUndoRedo = false
    }

    func setTextSelectionPreservingCommandState(_ range: NSRange) {
        isApplyingCommandSelection = true
        setSelectedRange(
            range,
            preservesCommandState: true,
            schedulesSelectionScroll: true
        )
        isApplyingCommandSelection = false
    }

    func setSelectedRange(
        _ range: NSRange,
        preservesCommandState: Bool,
        schedulesSelectionScroll: Bool
    ) {
        let clamped = clampedTextRange(range)
        let changed = currentSelectedRange != clamped

        if changed {
            inputDelegate?.selectionWillChange(self)
            currentSelectedRange = clamped
            if !isApplyingModel {
                model.selectedRange = clamped
            }
            syncTextLayoutSelection()
            inputDelegate?.selectionDidChange(self)
        }

        handleSelectionDidChange(preservesCommandState: preservesCommandState || isApplyingCommandSelection)

        if schedulesSelectionScroll {
            scheduleScrollSelectionToVisibleIfNeeded()
        }
    }

    func syncTextLayoutSelection() {
        if let textRange = textRange(forUTF16Range: currentSelectedRange) {
            let affinity: NSTextSelection.Affinity = currentSelectedRange.length == 0
                && isHardLineBreakCaretLocation(currentSelectedRange.location)
                ? .upstream
                : .downstream
            layoutManager.textSelections = [
                NSTextSelection(range: textRange, affinity: affinity, granularity: .character),
            ]
        } else {
            layoutManager.textSelections = []
        }
    }

    func handleSelectionDidChange(preservesCommandState: Bool) {
        if !preservesCommandState {
            commandEngine.invalidateTransientState()
        }
        applyMatchingBracketHighlight()
        refreshKeyboardAccessoryState()
    }

    func performWithoutUndoRegistration(_ work: () -> Void) {
        let undoManager = activeUndoManager
        let wasUndoRegistrationEnabled = undoManager?.isUndoRegistrationEnabled ?? false
        if wasUndoRegistrationEnabled {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if wasUndoRegistrationEnabled {
                undoManager?.enableUndoRegistration()
            }
        }

        work()
    }

    func applyTextReplacement(
        previousText: String,
        nextText: String
    ) -> SyntaxEditorTextChange.Replacement? {
        guard let mutation = SyntaxEditorTextChange.Replacement.singleReplacement(from: previousText, to: nextText) else {
            return nil
        }

        let textLength = previousText.utf16.count
        guard mutation.range.location >= 0,
              mutation.range.location + mutation.range.length <= textLength else {
            return nil
        }

        performRawEdits(
            [SyntaxEditorTextChange.Replacement(range: mutation.range, replacement: mutation.replacement)],
            previousText: previousText
        )
        return mutation
    }
}
#endif
