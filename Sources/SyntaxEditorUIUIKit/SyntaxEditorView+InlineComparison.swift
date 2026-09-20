#if canImport(UIKit)
import UIKit

final class SyntaxEditorComparisonTextLayoutFragment: NSTextLayoutFragment {
    var comparisonTopMargin: CGFloat = 0
    var comparisonBottomMargin: CGFloat = 0
    override var topMargin: CGFloat { super.topMargin + comparisonTopMargin }
    override var bottomMargin: CGFloat { super.bottomMargin + comparisonBottomMargin }
}

extension SyntaxEditorView: @preconcurrency NSTextLayoutManagerDelegate {
    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = SyntaxEditorComparisonTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        configureComparisonMargins(for: fragment)
        return fragment
    }

    func configureComparisonMargins(for fragment: SyntaxEditorComparisonTextLayoutFragment) {
        let margins = inlineComparisonLayout?.margins(for: textRange(for: fragment)) ?? (top: 0, bottom: 0)
        fragment.comparisonTopMargin = margins.top
        fragment.comparisonBottomMargin = margins.bottom
        if margins.top > 0 || margins.bottom > 0 { comparisonMarginFragments.add(fragment) }
    }

    func invalidateInlineComparisonLayout() {
        needsInlineComparisonLayout = true
        setNeedsTextLayout()
    }

    func updateComparisonMargins() {
        for fragment in comparisonMarginFragments.allObjects {
            fragment.comparisonTopMargin = 0
            fragment.comparisonBottomMargin = 0
            fragment.invalidateLayout()
        }
        comparisonMarginFragments.removeAllObjects()
        for offset in inlineComparisonLayout?.marginAnchorOffsets ?? [] {
            guard let location = textLocation(forUTF16Offset: offset),
                  let fragment = layoutManager.textLayoutFragment(for: location) as? SyntaxEditorComparisonTextLayoutFragment else { continue }
            configureComparisonMargins(for: fragment)
            fragment.invalidateLayout()
        }
        invalidateLayoutManagerLayout()
    }

    func layoutInlineComparison() -> Bool {
        guard let inlineComparisonLayout else { return false }
        var fragments = textContentView.subviews.compactMap {
            ($0 as? TextLayoutFragmentView)?.layoutFragment
        }
        for offset in inlineComparisonLayout.focusedAnchorOffsets {
            guard let range = textRange(forUTF16Range: NSRange(location: offset, length: 1)) else { continue }
            layoutManager.ensureLayout(for: range)
            if let fragment = layoutManager.textLayoutFragment(for: range.location),
               !fragments.contains(where: { $0 === fragment }) { fragments.append(fragment) }
        }
        let caret = storage.length == 0 ? caretRect(forUTF16Location: 0) : nil
        return inlineComparisonLayout.layoutDeletedViews(
            in: fragments, viewport: adjustedVisibleContentRect, emptyDocumentCaretFrame: caret
        )
    }
}
#endif
