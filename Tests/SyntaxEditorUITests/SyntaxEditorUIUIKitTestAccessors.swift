#if canImport(UIKit)
import ObservationBridge
import UIKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIUIKit

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
        applyObservedModelChange(forceTextUpdate: !text.utf16.elementsEqual(model.text.utf16))
        applyObservedSelection(model.selectedRange)
    }

    var modelDeliveryForTesting: PortableObservationTracking.Token? { modelObservation }

    var modelConfigurationDeliveryForTesting: PortableObservationTracking.Token? { modelConfigurationObservation }

    var renderedTextContentFrameForTesting: CGRect {
        textContentView.frame
    }

    var bracketHighlightRangesForTesting: [NSRange] {
        matchedBracketRanges
    }

    var findFoundRangesForTesting: [NSRange] {
        findFoundRanges
    }

    var findHighlightedRangesForTesting: [NSRange] {
        findHighlightedRanges
    }

    var findHighlightUpdatePassCountForTesting: Int {
        findHighlightUpdatePassCount
    }

    func syntaxForegroundColorForTesting(at location: Int) -> UIColor? {
        guard location >= 0,
              location < storage.length
        else {
            return nil
        }
        return highlightStyleStore.foregroundColor(at: location)
    }

    func syntaxFontForTesting(at location: Int) -> UIFont? {
        guard location >= 0,
              location < storage.length
        else {
            return nil
        }
        return highlightStyleStore.font(at: location)
    }

    func baseForegroundColorForTesting() -> UIColor? {
        highlightStyleStore.baseForeground
    }

    var lineMetricsFullRebuildCountForTesting: Int {
        lineMetrics.fullRebuildCount
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
#endif
