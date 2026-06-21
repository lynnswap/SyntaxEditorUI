#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
    func configureTextFinder() {
        if !usesFindBar {
            textFinder.cancelFindIndicator()
        }
        unsafe textFinder.findBarContainer = usesFindBar ? enclosingScrollView : nil
        textFinder.isIncrementalSearchingEnabled = isIncrementalSearchingEnabled
        rebuildFindHighlightRangeIndex()
        updateFindHighlightsForVisibleFragments()
    }

    func clearTextFinderAttachments() {
        textFinder.cancelFindIndicator()
        unsafe textFinder.findBarContainer = nil
        rebuildFindHighlightRangeIndex()
        updateFindHighlightsForVisibleFragments()
    }

    func updateFindHighlightsForVisibleFragments() {
        layoutVisibleViewport()
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            configureFindHighlights(for: fragmentView)
        }
    }

    func updateFindHighlightsForVisibleFragments(intersecting ranges: [NSRange]) {
        layoutVisibleViewport()
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            guard !TextLayoutGeometry.ranges(ranges, intersecting: fragmentRange).isEmpty else {
                continue
            }
            configureFindHighlights(for: fragmentView)
        }
    }

    func setFindHighlightRangesForTesting(_ ranges: [NSRange]?) {
        findHighlightRangesOverrideForTesting = ranges
        rebuildFindHighlightRangeIndex()
        updateFindHighlightsForVisibleFragments()
    }

    private func currentFindHighlightRanges() -> [NSRange] {
        if let findHighlightRangesOverrideForTesting {
            return findHighlightRangesOverrideForTesting
        }
        guard usesFindBar, isIncrementalSearchingEnabled else {
            return []
        }
        return textFinder.incrementalMatchRanges.map(\.rangeValue)
    }

    func rebuildFindHighlightRangeIndex() {
        findHighlightRangeIndex = TextRangeIntersectionIndex(
            ranges: currentFindHighlightRanges(),
            utf16Length: storage.length
        )
    }

    func handleIncrementalMatchRangesChange(changedRanges: [NSRange]?) {
        guard findHighlightRangesOverrideForTesting == nil else { return }

        rebuildFindHighlightRangeIndex()
        if let changedRanges, !changedRanges.isEmpty {
            updateFindHighlightsForVisibleFragments(intersecting: changedRanges)
        } else {
            updateFindHighlightsForVisibleFragments()
        }
    }

    func configureFindHighlights(for fragmentView: SyntaxEditorTextInputView.TextLayoutFragmentView) {
        guard !findHighlightRangeIndex.isEmpty else {
            fragmentView.setFindHighlights(rects: [])
            return
        }

        let fragmentRange = textRange(for: fragmentView.layoutFragment)
        let sourceRanges = findHighlightRangeIndex
            .sourceRanges(intersecting: fragmentRange)
            .filter { !isCurrentFindMatch($0) }
        let ranges = TextLayoutGeometry.ranges(sourceRanges, intersecting: fragmentRange)
        guard !ranges.isEmpty else {
            fragmentView.setFindHighlights(rects: [])
            return
        }

        let rects = TextLayoutGeometry.standardRects(
            layoutManager: textLayoutManager,
            rangeConverter: textSystem.rangeConverter,
            ranges: ranges,
            offsetBy: fragmentView.frame.origin
        )
        fragmentView.setFindHighlights(rects: rects)
    }

    private func isCurrentFindMatch(_ range: NSRange) -> Bool {
        selectedRangeStorage.length > 0
            && selectedRangeStorage.location == range.location
            && selectedRangeStorage.length == range.length
    }
}
#endif
