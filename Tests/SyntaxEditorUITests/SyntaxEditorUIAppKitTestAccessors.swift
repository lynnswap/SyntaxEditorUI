#if canImport(AppKit)
import AppKit
import ObservationBridge
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit

// Accessors and drivers the tests use to inspect and settle editor internals.
// They live with the tests so the editor targets carry no test-only API.

@MainActor
extension SyntaxEditorView {
    /// Applies the model's current state now instead of waiting for
    /// observation delivery.
    func synchronizeDocumentForTesting() {
        applyObservedConfiguration(
            language: model.language,
            isEditable: model.isEditable,
            lineWrappingEnabled: model.lineWrappingEnabled,
            theme: model.theme,
            drawsBackground: model.drawsBackground,
            fontSizeDelta: model.fontSizeDelta
        )
        applyObservedModelChange()
        applyObservedSelection(model.selectedRange)
    }

    var modelDeliveryForTesting: PortableObservationTracking.Token? { modelObservation }

    var modelConfigurationDeliveryForTesting: PortableObservationTracking.Token? {
        modelConfigurationObservation
    }

    var bracketHighlightRangesForTesting: [NSRange] {
        matchedBracketRanges
    }

    var visibleTextDisplayInvalidationCountForTesting: Int {
        visibleTextDisplayInvalidationCount
    }

    var fullTextDisplayInvalidationCountForTesting: Int {
        fullTextDisplayInvalidationCount
    }

    var fragmentDisplayInvalidationCountForTesting: Int {
        textView.fragmentDisplayInvalidationCount
    }

    var syntaxForegroundMaterializationCountForTesting: Int {
        textSystem.styleStore.epoch
    }

    var syntaxColorRunCountForTesting: Int {
        textSystem.styleStore.appliedColorRunsForTesting.count
    }

    var lineMetricsFullRebuildCountForTesting: Int {
        textView.lineMetrics.fullRebuildCount
    }

    func syntaxForegroundColorForTesting(at location: Int) -> NSColor? {
        guard location >= 0,
            location < textStorage.length
        else {
            return nil
        }
        return textSystem.styleStore.foregroundColor(at: location)
    }

    func syntaxFontForTesting(at location: Int) -> NSFont? {
        guard location >= 0,
            location < textStorage.length
        else {
            return nil
        }
        return textSystem.styleStore.font(at: location)
    }

    func baseForegroundColorForTesting() -> NSColor? {
        textSystem.styleStore.baseForeground
    }
}

@MainActor
extension SyntaxEditorViewController {
    func synchronizeDocumentForTesting() {
        editorView.synchronizeDocumentForTesting()
    }
}

@MainActor
extension SyntaxEditorComparisonView {
    /// Waits until the view shows the model's current comparison and
    /// `isReady` holds.
    func waitForPendingComparisonRefreshForTesting(until isReady: () -> Bool = { true }) async {
        while refreshTask != nil || hasUnappliedComparisonContent
            || displayedSelection != model.selectedChangeIndex || !isReady() {
            if let task = refreshTask {
                await task.value
            } else {
                await withCheckedContinuation { continuation in
                    let previous = didScheduleRefresh
                    didScheduleRefresh = { [weak self] in
                        self?.didScheduleRefresh = previous
                        previous?()
                        continuation.resume()
                    }
                }
            }
        }
    }

    var comparisonDeliveryForTesting: PortableObservationTracking.Token? { comparisonObservation }

    var comparisonConfigurationDeliveryForTesting: PortableObservationTracking.Token? { configurationObservation }

    var displayedPresentationForTesting: SyntaxEditorComparisonModel.Presentation { displayedPresentation }
}

@MainActor
extension SyntaxEditorTextInputView {
    var insertionIndicatorDisplayModeForTesting: NSTextInsertionIndicator.DisplayMode {
        insertionIndicator.displayMode
    }

    var insertionIndicatorFrameForTesting: NSRect {
        insertionIndicator.frame
    }

    var insertionIndicatorIsHiddenForTesting: Bool {
        insertionIndicator.isHidden
    }

    var selectionHighlightRectsForTesting: [CGRect] {
        textContentView.subviews
            .compactMap { $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView }
            .flatMap(\.selectionHighlightRects)
    }

    var findHighlightRectsForTesting: [CGRect] {
        textContentView.subviews
            .compactMap { $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView }
            .flatMap(\.findHighlightRects)
    }

    var findCandidateHighlightFillColorForTesting: NSColor {
        SyntaxEditorTextInputView.TextLayoutFragmentView.findCandidateHighlightFillColor
    }

    var findCandidateHighlightCornerRadiusForTesting: CGFloat {
        SyntaxEditorTextInputView.TextLayoutFragmentView.findCandidateHighlightCornerRadius
    }

    /// Shows `ranges` as the incremental search matches, or returns to the text
    /// finder's own matches when `ranges` is `nil`.
    func setFindHighlightRangesForTesting(_ ranges: [NSRange]?) {
        if let ranges {
            incrementalMatchRangesSource = { ranges }
        } else {
            incrementalMatchRangesSource = { [textFinder] in
                textFinder.incrementalMatchRanges.map(\.rangeValue)
            }
        }
        rebuildFindHighlightRangeIndex()
        updateFindHighlightsForVisibleFragments()
    }

    func resetSyntaxRenderingAttributeCountersForTesting() {
        syntaxRenderingAttributeUTF16LengthForTesting = 0
        syntaxRenderingAttributeColorRunCountForTesting = 0
    }

    func syntaxRenderingAttributeTargetRangesForTesting(
        in textLayoutFragment: NSTextLayoutFragment
    ) -> [NSRange] {
        let fragmentRange = textRange(for: textLayoutFragment)
        guard fragmentRange.length > 0 else { return [] }
        return syntaxRenderingAttributeTargetRanges(
            in: textLayoutFragment,
            fragmentRange: fragmentRange
        )
    }
}
#endif
