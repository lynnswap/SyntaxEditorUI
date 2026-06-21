#if canImport(UIKit)
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView {
    func updateFindHighlightFragmentViews() {
        findHighlightUpdatePassCount += 1
        for case let fragmentView as SyntaxEditorView.TextLayoutFragmentView in textContentView.subviews {
            configureFindHighlights(for: fragmentView, layoutFragmentFrame: fragmentView.layoutFragment.layoutFragmentFrame)
        }
    }

    func configureFindHighlights(
        for fragmentView: SyntaxEditorView.TextLayoutFragmentView,
        layoutFragmentFrame: CGRect
    ) {
        let foundRects: [CGRect]
        let highlightedRects: [CGRect]
        if findFoundRanges.isEmpty && findHighlightedRanges.isEmpty {
            foundRects = []
            highlightedRects = []
        } else {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            foundRects = textHighlightRects(
                in: layoutFragmentFrame,
                ranges: TextLayoutGeometry.ranges(findFoundRanges, intersecting: fragmentRange)
            )
            highlightedRects = textHighlightRects(
                in: layoutFragmentFrame,
                ranges: TextLayoutGeometry.ranges(findHighlightedRanges, intersecting: fragmentRange)
            )
        }
        let foundColor = foundRects.isEmpty
            ? nil
            : UIColor
                .syntaxEditorAlpha(.systemYellow, alpha: 0.28)
                .resolvedColor(with: traitCollection)
                .cgColor
        let highlightedColor = highlightedRects.isEmpty
            ? nil
            : UIColor
                .syntaxEditorAlpha(.systemOrange, alpha: 0.42)
                .resolvedColor(with: traitCollection)
                .cgColor

        let foundChanged = fragmentView.findHighlightRects != foundRects
            || !Self.optionalColorsEqual(fragmentView.findHighlightColor, foundColor)
        let highlightedChanged = fragmentView.currentFindHighlightRects != highlightedRects
            || !Self.optionalColorsEqual(fragmentView.currentFindHighlightColor, highlightedColor)

        fragmentView.findHighlightRects = foundRects
        fragmentView.findHighlightColor = foundColor
        fragmentView.currentFindHighlightRects = highlightedRects
        fragmentView.currentFindHighlightColor = highlightedColor
        if foundChanged || highlightedChanged {
            fragmentView.setNeedsDisplay()
        }
    }
    func decorateFindTextRange(_ range: NSRange, style: UITextSearchFoundTextStyle) {
        let clampedRange = clampedTextRange(range)
        guard clampedRange.length > 0 else { return }

        switch style {
        case .normal:
            guard findFoundRanges.contains(clampedRange) || findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
        case .found:
            guard !findFoundRanges.contains(clampedRange) || findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
            findFoundRanges.append(clampedRange)
        case .highlighted:
            guard findFoundRanges.contains(clampedRange) || !findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.append(clampedRange)
        @unknown default:
            guard !findFoundRanges.contains(clampedRange) || findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
            findFoundRanges.append(clampedRange)
        }

        invalidateFindDecorationRanges([clampedRange])
    }

    func clearFindDecorations() {
        let previousRanges = findFoundRanges + findHighlightedRanges
        guard !previousRanges.isEmpty else { return }

        findFoundRanges.removeAll()
        findHighlightedRanges.removeAll()
        invalidateFindDecorationRanges(previousRanges)
    }

    func beginFindDecorationBatch() {
        findDecorationBatchDepth += 1
    }

    func endFindDecorationBatch() {
        guard findDecorationBatchDepth > 0 else { return }
        findDecorationBatchDepth -= 1
        guard findDecorationBatchDepth == 0 else { return }

        let ranges = pendingFindDecorationInvalidationRanges
        pendingFindDecorationInvalidationRanges.removeAll(keepingCapacity: true)
        guard !ranges.isEmpty else { return }

        setNeedsDisplayForTextRanges(ranges)
        updateFindHighlightFragmentViews()
    }

    func invalidateFindDecorationRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }

        if findDecorationBatchDepth > 0 {
            pendingFindDecorationInvalidationRanges.append(contentsOf: ranges)
        } else {
            setNeedsDisplayForTextRanges(ranges)
            updateFindHighlightFragmentViews()
        }
    }

    func invalidateFindResultsAfterTextChange() {
        clearFindDecorations()
        findCoordinator?.invalidateResultsAfterTextChange()
    }
}
#endif
