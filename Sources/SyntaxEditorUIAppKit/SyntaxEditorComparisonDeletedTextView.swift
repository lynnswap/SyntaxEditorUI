#if canImport(AppKit)
import AppKit

@MainActor
final class SyntaxEditorComparisonDeletedTextView: NSTextView {
    var onSelectionChange: ((NSRange) -> Void)?
    var onFind: ((Any?) -> Void)?

    private let contentStorage = NSTextContentStorage()
    private let comparisonStorage = NSTextStorage()
    private let comparisonLayoutManager = NSTextLayoutManager()
    private let comparisonContainer = NSTextContainer()
    private var measuredSize: NSSize?
    private var isInstallingText = false

    init() {
        contentStorage.textStorage = comparisonStorage
        contentStorage.addTextLayoutManager(comparisonLayoutManager)
        comparisonLayoutManager.textContainer = comparisonContainer
        super.init(frame: .zero, textContainer: comparisonContainer)

        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        comparisonContainer.lineFragmentPadding = 0
        comparisonContainer.widthTracksTextView = false
        comparisonContainer.heightTracksTextView = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange),
            name: NSTextView.didChangeSelectionNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Installs the already styled slice of the original document.
    func install(_ attributedString: NSAttributedString) {
        let previousSelection = selectedRanges
        isInstallingText = true
        comparisonStorage.setAttributedString(attributedString)
        selectedRanges = previousSelection.map {
            let range = $0.rangeValue
            let location = min(range.location, attributedString.length)
            return NSValue(range: NSRange(
                location: location,
                length: min(range.length, attributedString.length - location)
            ))
        }
        isInstallingText = false
        measuredSize = nil
        needsLayout = true
        needsDisplay = true
    }

    /// Refines the caller's initial estimate using native viewport layout.
    /// The returned height can change as previously unseen paragraphs are laid out.
    /// The caller owns the containing document's size and scroll-anchor restoration.
    func measure(width: CGFloat, lineWrappingEnabled: Bool, estimatedSize: NSSize) -> NSSize {
        let containerWidth = lineWrappingEnabled ? width : CGFloat.greatestFiniteMagnitude
        if comparisonContainer.size.width != containerWidth {
            comparisonContainer.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            measuredSize = nil
        }
        var size = NSSize(
            width: lineWrappingEnabled ? width : max(width, estimatedSize.width, measuredSize?.width ?? 0),
            height: measuredSize?.height ?? estimatedSize.height
        )
        if frame.size != size { setFrameSize(size) }
        guard !visibleRect.isEmpty else { return size }

        let viewport = comparisonLayoutManager.textViewportLayoutController
        viewport.layoutViewport()
        if let viewportRange = viewport.viewportRange {
            let usage = comparisonLayoutManager.usageBoundsForTextContainer
            size.height = usage.maxY
            if !lineWrappingEnabled { size.width = max(size.width, usage.maxX) }
            if viewportRange.endLocation.compare(contentStorage.documentRange.endLocation) == .orderedSame,
               let location = lastCharacterLocation,
               let fragment = comparisonLayoutManager.textLayoutFragment(for: location),
               let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false) {
                // Keep the final terminator in the selectable text, while omitting
                // the native extra empty line after it from the block's height.
                size.height = fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY
            }
        } else if let endRect = reveal(NSRange(location: comparisonStorage.length, length: 0)) {
            // A viewport beyond an old estimate can have no range. Relocate only
            // the final paragraph so the parent can remove the obsolete blank tail.
            size.height = endRect.maxY
        }
        measuredSize = size
        if frame.size != size { setFrameSize(size) }
        return size
    }

    /// Returns a suggested local rect for the beginning of a range, without
    /// laying out the whole range or changing its selection. The parent scrolls
    /// to this rect and then measures the newly visible viewport.
    func reveal(_ localRange: NSRange) -> NSRect? {
        guard comparisonStorage.length > 0 else { return .zero }
        let offset = localRange.location == comparisonStorage.length
            ? localRange.location - 1
            : localRange.location
        guard let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: offset),
              let end = contentStorage.location(location, offsetBy: 1),
              let range = NSTextRange(location: location, end: end) else { return nil }
        comparisonLayoutManager.ensureLayout(for: range)
        let y = comparisonLayoutManager.textViewportLayoutController.relocateViewport(to: location)
        guard let fragment = comparisonLayoutManager.textLayoutFragment(for: location),
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false) else { return nil }
        return NSRect(x: 0, y: y, width: bounds.width, height: line.typographicBounds.height)
    }

    override func performFindPanelAction(_ sender: Any?) {
        onFind?(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        onFind?(sender)
    }

    private var lastCharacterLocation: (any NSTextLocation)? {
        guard comparisonStorage.length > 0 else { return nil }
        return contentStorage.location(contentStorage.documentRange.endLocation, offsetBy: -1)
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard !isInstallingText else { return }
        onSelectionChange?(selectedRange())
    }
}
#endif
