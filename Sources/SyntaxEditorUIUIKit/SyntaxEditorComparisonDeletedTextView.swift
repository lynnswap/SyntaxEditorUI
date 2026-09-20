#if canImport(UIKit)
import UIKit

@MainActor
final class SyntaxEditorComparisonDeletedTextView: UITextView, UITextViewDelegate {
    /// The selection in the original document's UTF-16 coordinates.
    var onSelectionChange: ((NSRange) -> Void)?
    /// A native scroll request, expressed within the complete deleted block.
    var onScroll: ((CGPoint) -> Void)?
    var onFind: ((Selector, Any?) -> Void)?
    var isChangeSelected = false {
        didSet {
            guard isChangeSelected != oldValue else { return }
            updateComparisonBackground()
        }
    }

    private let comparisonContentStorage = NSTextContentStorage()
    private let comparisonStorage = NSTextStorage()
    private let comparisonLayoutManager = NSTextLayoutManager()
    private let comparisonContainer = NSTextContainer()
    private var originalLocation = 0
    private var isApplyingPresentation = false

    init() {
        comparisonContentStorage.textStorage = comparisonStorage
        comparisonContentStorage.addTextLayoutManager(comparisonLayoutManager)
        comparisonContentStorage.primaryTextLayoutManager = comparisonLayoutManager
        comparisonLayoutManager.textContainer = comparisonContainer
        super.init(frame: .zero, textContainer: comparisonContainer)

        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        scrollsToTop = false
        bounces = false
        updateComparisonBackground()
        contentInsetAdjustmentBehavior = .never
        contentInset = .zero
        textContainerInset = .zero
        comparisonContainer.lineFragmentPadding = 0
        comparisonContainer.widthTracksTextView = false
        comparisonContainer.heightTracksTextView = false
        isFindInteractionEnabled = false
        delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // UIKit can reenable the pan recognizer when text-view geometry changes.
        // Native selection scrolling remains enabled; dragging belongs to the parent.
        if gestureRecognizer === panGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Installs a complete, already styled deletion block. `originalLocation`
    /// identifies its first UTF-16 code unit in the original document.
    func install(_ attributedString: NSAttributedString, originalLocation: Int) {
        let previousSelection = selectedRange
        let previousOffset = contentOffset
        let wasApplying = isApplyingPresentation
        isApplyingPresentation = true
        defer { isApplyingPresentation = wasApplying }

        self.originalLocation = originalLocation
        comparisonStorage.setAttributedString(attributedString)
        let location = min(previousSelection.location, attributedString.length)
        let selection = NSRange(
            location: location,
            length: min(previousSelection.length, attributedString.length - location)
        )
        if selectedRange != selection { selectedRange = selection }
        if contentOffset != previousOffset { setContentOffset(previousOffset, animated: false) }
    }

    /// Projects the model's original-document selection into this block without
    /// turning the projection into a selection or scroll request for the parent.
    func setSelection(_ originalRange: NSRange) {
        let lower = min(max(0, originalRange.location - originalLocation), comparisonStorage.length)
        let upper = min(max(0, originalRange.upperBound - originalLocation), comparisonStorage.length)
        let selection = NSRange(location: lower, length: upper - lower)
        guard selectedRange != selection else { return }
        let previousOffset = contentOffset
        let wasApplying = isApplyingPresentation
        isApplyingPresentation = true
        defer { isApplyingPresentation = wasApplying }
        selectedRange = selection
        if contentOffset != previousOffset { setContentOffset(previousOffset, animated: false) }
    }

    /// Both rectangles use the parent's content coordinates. The native view
    /// occupies only their intersection; its text storage retains the full block.
    /// This updates geometry without changing the text selection and returns the
    /// native document-size estimate, refined as previously unseen text is laid out.
    @discardableResult
    func updateLayout(blockFrame: CGRect, viewport: CGRect, lineWrappingEnabled: Bool) -> CGSize {
        let wasApplying = isApplyingPresentation
        isApplyingPresentation = true
        defer { isApplyingPresentation = wasApplying }

        let intersection = blockFrame.intersection(viewport)
        let nextFrame = intersection.isNull
            ? CGRect(origin: blockFrame.origin, size: .zero)
            : intersection
        if frame != nextFrame { frame = nextFrame }
        guard !nextFrame.isEmpty else { return blockFrame.size }
        let containerSize = CGSize(
            width: lineWrappingEnabled ? blockFrame.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        comparisonContainer.lineBreakMode = lineWrappingEnabled ? .byCharWrapping : .byClipping
        if comparisonContainer.size != containerSize { comparisonContainer.size = containerSize }
        let offset = CGPoint(
            x: nextFrame.minX - blockFrame.minX,
            y: nextFrame.minY - blockFrame.minY
        )
        if contentOffset != offset { setContentOffset(offset, animated: false) }
        setNeedsLayout()
        layoutIfNeeded()
        let controller = comparisonLayoutManager.textViewportLayoutController
        controller.layoutViewport()
        let usage = comparisonLayoutManager.usageBoundsForTextContainer
        var size = CGSize(
            width: lineWrappingEnabled ? blockFrame.width : max(blockFrame.width, contentSize.width, usage.maxX),
            height: comparisonStorage.length == 0 ? 0 : usage.maxY
        )
        if let viewportRange = controller.viewportRange,
           viewportRange.endLocation.compare(comparisonContentStorage.documentRange.endLocation) == .orderedSame,
           comparisonStorage.length > 0,
           let last = comparisonContentStorage.location(comparisonContentStorage.documentRange.endLocation, offsetBy: -1),
           let fragment = comparisonLayoutManager.textLayoutFragment(for: last),
           let line = fragment.textLineFragment(for: last, isUpstreamAffinity: false) {
            // The terminator remains selectable; only the extra empty line below
            // it is omitted from the deletion block's displayed height.
            size.height = fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY
        }
        return size
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isApplyingPresentation else { return }
        onSelectionChange?(NSRange(
            location: originalLocation + selectedRange.location,
            length: selectedRange.length
        ))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingPresentation else { return }
        onScroll?(contentOffset)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateComparisonBackground()
    }

    private func updateComparisonBackground() {
        let color = isChangeSelected ? tintColor ?? .systemBlue : .systemRed
        backgroundColor = color.withAlphaComponent(isChangeSelected ? 0.16 : 0.12)
    }

    override func find(_ sender: Any?) {
        onFind?(#selector(UIResponderStandardEditActions.find(_:)), sender)
    }

    override func findNext(_ sender: Any?) {
        onFind?(#selector(UIResponderStandardEditActions.findNext(_:)), sender)
    }

    override func findPrevious(_ sender: Any?) {
        onFind?(#selector(UIResponderStandardEditActions.findPrevious(_:)), sender)
    }

    override func useSelectionForFind(_ sender: Any?) {
        onFind?(#selector(UIResponderStandardEditActions.useSelectionForFind(_:)), sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.find(_:))
            || action == #selector(UIResponderStandardEditActions.findNext(_:))
            || action == #selector(UIResponderStandardEditActions.findPrevious(_:)) {
            return onFind != nil
        }
        if action == #selector(UIResponderStandardEditActions.useSelectionForFind(_:)) {
            return onFind != nil && selectedRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
