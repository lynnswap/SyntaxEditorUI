#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView {
    internal func synchronizeDocumentForTesting() {
        applyObservedConfiguration(
            language: model.language,
            isEditable: model.isEditable,
            lineWrappingEnabled: model.lineWrappingEnabled,
            theme: model.theme,
            drawsBackground: model.drawsBackground,
            fontSizeDelta: model.fontSizeDelta
        )
        applyObservedModelChange(forceTextUpdate: text != model.text)
        applyObservedSelection(model.selectedRange)
    }
    func startModelObservation(
        schedulesInitialHighlight: Bool = true,
        skipsInitialModelDelivery: Bool = false
    ) {
        let model = model
        modelConfigurationObservation = withPortableContinuousObservation { [weak self, model] event in
            guard let self else { return }

            let language = model.language
            let isEditable = model.isEditable
            let lineWrappingEnabled = model.lineWrappingEnabled
            let theme = model.theme
            let drawsBackground = model.drawsBackground
            let fontSizeDelta = model.fontSizeDelta

            self.applyObservedConfiguration(
                language: language,
                isEditable: isEditable,
                lineWrappingEnabled: lineWrappingEnabled,
                theme: theme,
                drawsBackground: drawsBackground,
                fontSizeDelta: fontSizeDelta,
                forceLanguageRefresh: event.kind == .initial,
                schedulesHighlight: event.kind != .initial || schedulesInitialHighlight
            )
        }

        modelObservation = withPortableContinuousObservation { [weak self, model] event in
            guard let self else { return }

            _ = model.text
            let revision = model.textRevision
            let selectedRange = model.selectedRange

            guard !(skipsInitialModelDelivery && event.kind == .initial) else { return }
            self.applyObservedModelChange(
                forceTextUpdate: event.kind == .initial,
                observedRevision: revision
            )
            self.applyObservedSelection(selectedRange)
        }
    }

    func cancelModelObservations() {
        modelConfigurationObservation?.cancel()
        modelConfigurationObservation = nil
        modelObservation?.cancel()
        modelObservation = nil
    }

    func synchronizeReboundModel() {
        applyObservedConfiguration(
            language: model.language,
            isEditable: model.isEditable,
            lineWrappingEnabled: model.lineWrappingEnabled,
            theme: model.theme,
            drawsBackground: model.drawsBackground,
            fontSizeDelta: model.fontSizeDelta,
            forceLanguageRefresh: true,
            schedulesHighlight: false
        )
        applyObservedModelChange(forceTextUpdate: true, observedRevision: model.textRevision)
        applyObservedSelection(model.selectedRange)
    }

    func applyObservedModelChange(forceTextUpdate: Bool = false, observedRevision: Int? = nil) {
        let revision = observedRevision ?? model.textRevision
        guard forceTextUpdate || revision != lastAppliedDocumentRevision else { return }

        isApplyingModel = true
        defer {
            isApplyingModel = false
        }

        let previousText = text
        let nextText = model.text
        let textNeedsUpdate = forceTextUpdate || previousText != nextText

        if textNeedsUpdate {
            commandEngine.invalidateTransientState()
            let change = model.latestTextChange
            if change?.kind == .wholeDocumentReplacement {
                activeUndoManager?.removeAllActions()
            }
            let previousSelection = selectedRange
            if let change,
               change.textRevision == revision,
               change.kind == .incremental,
               !forceTextUpdate,
               lastAppliedDocumentRevision == revision - 1 {
                performRawEdits(change.replacements, previousText: previousText)
            } else {
                replaceEntireStorageText(nextText)
            }
            let nextSelection: NSRange
            if change?.kind == .wholeDocumentReplacement,
               change?.selectedRange == NSRange(location: 0, length: 0) {
                nextSelection = previousSelection
            } else {
                nextSelection = change?.selectedRange ?? previousSelection
            }
            setSelectedRange(
                clampedTextRange(nextSelection, in: nextText),
                preservesCommandState: true,
                schedulesSelectionScroll: true
            )
            updateTypingAttributes()
            updateTextContainerForCurrentWrappingMode()
            invalidateTextLayout()
            let highlightMutation: SyntaxEditorTextChange.Replacement? = if model.latestTextChange?.kind == .wholeDocumentReplacement {
                nil
            } else {
                model.latestTextChange.flatMap(Self.highlightMutation)
            }
            scheduleHighlight(
                source: nextText,
                language: model.language,
                revision: revision,
                mutation: highlightMutation,
                refreshStartUTF16: 0
            )
        } else {
            updateTypingAttributes()
        }

        lastAppliedDocumentRevision = revision
        refreshKeyboardAccessoryState()
    }

    func applyObservedSelection(_ range: NSRange) {
        let clamped = clampedTextRange(range)
        guard currentSelectedRange != clamped else { return }

        isApplyingModel = true
        defer {
            isApplyingModel = false
        }
        setSelectedRange(
            clamped,
            preservesCommandState: true,
            schedulesSelectionScroll: true
        )
    }

    func applyObservedConfiguration(
        language: SyntaxLanguage,
        isEditable: Bool,
        lineWrappingEnabled: Bool,
        theme: SyntaxEditorTheme,
        drawsBackground: Bool,
        fontSizeDelta: Int,
        forceLanguageRefresh: Bool = false,
        schedulesHighlight: Bool = true
    ) {
        let lineWrappingChanged = lastAppliedLineWrappingEnabled != lineWrappingEnabled
        lastAppliedLineWrappingEnabled = lineWrappingEnabled

        let previousTheme = lastAppliedTheme
        let themeChanged = previousTheme != theme
        let fontSizeDeltaChanged = lastAppliedFontSizeDelta != fontSizeDelta
        let appearance = currentThemeAppearance
        let previousBaseFont = resolvedBaseFont(
            for: previousTheme.resolved(for: language, appearance: appearance),
            fontSizeDelta: lastAppliedFontSizeDelta
        )
        let nextBaseFont = resolvedBaseFont(
            for: theme.resolved(for: language, appearance: appearance),
            fontSizeDelta: fontSizeDelta
        )
        let baseFontChanged = !previousBaseFont.isEqual(nextBaseFont)
        if themeChanged || fontSizeDeltaChanged {
            invalidateHorizontalMeasurement()
        }
        if themeChanged {
            applyBaseForegroundColorChange(from: previousTheme, to: theme, language: language)
        }
        lastAppliedTheme = theme
        lastAppliedThemeAppearance = appearance
        lastAppliedFontSizeDelta = fontSizeDelta
        updateEditorBackgroundColor(drawsBackground: drawsBackground)

        updateTextInteractions()
        applyLineWrappingConfiguration(lineWrappingEnabled: lineWrappingEnabled)
        applyParagraphStyleToExistingText()
        updateTextContainerForCurrentWrappingMode()
        if lineWrappingChanged && lineWrappingEnabled {
            resetHorizontalContentOffset()
        }

        let languageChanged = forceLanguageRefresh || lastAppliedLanguageIdentifier != language.syntaxHighlightCacheKey
        lastAppliedLanguageIdentifier = language.syntaxHighlightCacheKey

        updateTypingAttributes()
        if baseFontChanged {
            applyResolvedFontsToExistingText(
                source: storage.string,
                language: language,
                revision: lastAppliedDocumentRevision
            )
        }
        if languageChanged && schedulesHighlight {
            scheduleHighlight(
                source: storage.string,
                language: language,
                revision: lastAppliedDocumentRevision,
                refreshStartUTF16: 0
            )
        } else if (themeChanged || fontSizeDeltaChanged) && schedulesHighlight {
            reapplyCachedHighlight(
                source: storage.string,
                language: language,
                revision: lastAppliedDocumentRevision
            )
        }
        refreshKeyboardAccessoryState()
        invalidateTextLayout()
    }

    func replaceEntireStorageText(_ nextText: String) {
        lineMetrics.reset(source: nextText)
        TextEditingTransaction.perform(on: textContentStorage) { storage in
            storage.setAttributedString(NSAttributedString(string: nextText, attributes: storageBaseAttributes()))
        }
        resetSyntaxHighlightRenderingState(textLength: nextText.utf16.count)
        invalidateFindResultsAfterTextChange()
        markedRange = nil
        markedTextUndoAnchor = nil
        syncTextLayoutSelection()
    }

}
#endif
