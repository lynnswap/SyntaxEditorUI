#if canImport(UIKit)
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView {
    internal var lineMetricsFullRebuildCountForTesting: Int {
        lineMetrics.fullRebuildCount
    }
    public override var bounds: CGRect {
        didSet {
            guard bounds.size != oldValue.size else { return }
            updateTextContainerForCurrentWrappingMode()
            setNeedsLayout()
        }
    }

    public override var frame: CGRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            updateTextContainerForCurrentWrappingMode()
            setNeedsLayout()
        }
    }

    public override var contentOffset: CGPoint {
        get {
            super.contentOffset
        }
        set {
            super.contentOffset = contentOffsetConstrainedForTextInteraction(newValue)
        }
    }

    public override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(
            contentOffsetConstrainedForTextInteraction(contentOffset),
            animated: animated
        )
    }

    public override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        updateTextContainerForCurrentWrappingMode()
        if bounds.width > 0, bounds.height > 0 {
            layoutTextIfNeeded()
        } else {
            setNeedsLayout()
        }
    }

    public override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        guard shouldPreserveHorizontalOffsetForImplicitTextInteractionScroll,
              let preservedX = preservedTextInteractionHorizontalOffset else {
            super.scrollRectToVisible(rect, animated: animated)
            return
        }

        super.scrollRectToVisible(rect, animated: animated)
        guard !contentOffset.x.isNearlyEqual(to: preservedX) else { return }
        super.setContentOffset(CGPoint(x: preservedX, y: contentOffset.y), animated: false)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateTextContainerForCurrentWrappingMode()
        layoutTextIfNeeded()

        if let action = postLayoutAction {
            postLayoutAction = nil
            action()
        }
    }
    func configureTextSystem() {
        container.lineFragmentPadding = 5
        layoutManager.textViewportLayoutController.delegate = self
        configureSyntaxRenderingAttributesValidator()

        addSubview(textContentView)

        editableTextInteraction.textInput = self
        editableTextInteraction.delegate = self
        nonEditableTextInteraction.textInput = self
        nonEditableTextInteraction.delegate = self
        updateTextInteractions()
        updateFindInteraction()

        guardedUndoManager.allowsMutation = { [weak self] in
            self?.model.isEditable ?? true
        }
    }
    func configureScrollView() {
        updateEditorBackgroundColor()
        alwaysBounceVertical = true
        #if !os(visionOS)
        keyboardDismissMode = .interactive
        #endif
        delaysContentTouches = false
        panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]

        autocapitalizationType = .none
        autocorrectionType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no

        #if !os(visionOS)
        keyboardAccessoryView = makeInputAccessoryView()
        #endif
        refreshKeyboardAccessoryState()
    }
    func updateTextInteractions() {
        func addEditableInteraction() {
            removeInteraction(nonEditableTextInteraction)
            if editableTextInteraction.view == nil {
                addInteraction(editableTextInteraction)
            }
        }

        func addNonEditableInteraction() {
            removeInteraction(editableTextInteraction)
            if nonEditableTextInteraction.view == nil {
                addInteraction(nonEditableTextInteraction)
            }
        }

        func removeTextInteractions() {
            removeInteraction(editableTextInteraction)
            removeInteraction(nonEditableTextInteraction)
        }

        if model.isEditable {
            addEditableInteraction()
        } else if isSelectable {
            addNonEditableInteraction()
        } else {
            removeTextInteractions()
        }
    }

    func updateFindInteraction() {
        if isFindInteractionEnabled {
            let coordinator: SyntaxEditorFindCoordinator
            if let findCoordinator {
                coordinator = findCoordinator
            } else {
                coordinator = SyntaxEditorFindCoordinator(editorView: self)
                findCoordinator = coordinator
            }

            if coordinator.findInteraction.view == nil {
                addInteraction(coordinator.findInteraction)
            }
        } else if let findCoordinator {
            findCoordinator.invalidateActiveSearch()
            clearFindDecorations()
            removeInteraction(findCoordinator.findInteraction)
            self.findCoordinator = nil
        }
    }

    public func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        return true
    }

    public func interactionWillBegin(_ interaction: UITextInteraction) {
        isTextInteractionSelectionDrag = false
    }

    public func interactionDidEnd(_ interaction: UITextInteraction) {
        pendingTextInteractionCaretOverride = nil
        isTextInteractionSelectionDrag = false
    }
    func applyLineWrappingConfiguration(lineWrappingEnabled: Bool) {
        alwaysBounceHorizontal = !lineWrappingEnabled
        showsHorizontalScrollIndicator = !lineWrappingEnabled
        updateTextContainerForCurrentWrappingMode()
        setNeedsLayout()
    }

    func updateTextContainerForCurrentWrappingMode() {
        let lineWrappingEnabled = lastAppliedLineWrappingEnabled
        let lineBreakMode: NSLineBreakMode = lineWrappingEnabled ? .byCharWrapping : .byClipping

        if container.widthTracksTextView != lineWrappingEnabled {
            container.widthTracksTextView = lineWrappingEnabled
        }
        if container.lineBreakMode != lineBreakMode {
            container.lineBreakMode = lineBreakMode
        }

        guard bounds.width > 0, bounds.height > 0 else { return }

        let visibleSize = adjustedVisibleContentSize
        let availableWidth = max(0, visibleSize.width - textContainerInset.left - textContainerInset.right)
        let containerWidth = lineWrappingEnabled
            ? availableWidth
            : max(availableWidth, measuredHorizontalDocumentLayoutWidth() - textContainerInset.left - textContainerInset.right)
        let nextSize = CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        if !container.size.isNearlyEqual(to: nextSize) {
            container.size = nextSize
            invalidateLayoutManagerLayout()
        }
    }

    func layoutTextIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        isLayingOutText = true
        defer {
            isLayingOutText = false
        }

        updateTextContentViewFrameIfNeeded(contentSize: contentSize)

        var remainingIterations = 5
        while remainingIterations > 0 {
            needsTextRelayout = false
            layoutManager.textViewportLayoutController.layoutViewport()
            if !needsTextRelayout {
                break
            }
            remainingIterations -= 1
        }

        updateContentSizeIfNeeded()
    }

    func updateContentSizeIfNeeded() {
        let estimatedLayoutSize = estimatedDocumentLayoutSize()
        let minimumContentSize = adjustedVisibleContentSize
        let lineHeight = resolvedBaseFont().lineHeight
        let textHeight = max(lineHeight, ceil(estimatedLayoutSize.height))
        let targetWidth = lastAppliedLineWrappingEnabled
            ? minimumContentSize.width
            : max(minimumContentSize.width, measuredHorizontalDocumentLayoutWidth(), ceil(estimatedLayoutSize.width + textContainerInset.left + textContainerInset.right))
        let targetHeight = max(minimumContentSize.height, ceil(textHeight + textContainerInset.top + textContainerInset.bottom))
        let nextContentSize = CGSize(width: targetWidth, height: targetHeight)

        if !contentSize.isNearlyEqual(to: nextContentSize) {
            contentSize = nextContentSize
        }

        updateTextContentViewFrameIfNeeded(contentSize: nextContentSize)
    }

    func updateTextContentViewFrameIfNeeded(contentSize: CGSize) {
        let contentViewFrame = CGRect(
            x: textContainerInset.left,
            y: textContainerInset.top,
            width: max(container.size.width, contentSize.width - textContainerInset.left - textContainerInset.right),
            height: max(resolvedBaseFont().lineHeight, contentSize.height - textContainerInset.top - textContainerInset.bottom)
        )

        guard !textContentView.frame.isNearlyEqual(to: contentViewFrame) else { return }
        textContentView.frame = contentViewFrame
    }

    func estimatedDocumentLayoutSize() -> CGSize {
        if !lastAppliedLineWrappingEnabled {
            let horizontalInset = textContainerInset.left + textContainerInset.right
            return CGSize(
                width: max(0, measuredHorizontalDocumentLayoutWidth() - horizontalInset),
                height: CGFloat(lineMetrics.lineCount) * resolvedBaseFont().lineHeight
            )
        }

        let measuredSize = layoutManager.usageBoundsForTextContainer.size
        let font = resolvedBaseFont()
        let estimatedColumnWidth = Self.estimatedMonospacedColumnWidth(for: font)
        let availableLineWidth = max(1, container.size.width - container.lineFragmentPadding * 2)
        let estimatedHeight = CGFloat(lineMetrics.estimatedWrappedLineCount(
            maxColumnsPerLine: Int(floor(availableLineWidth / estimatedColumnWidth))
        )) * font.lineHeight
        return CGSize(
            width: max(measuredSize.width, adjustedVisibleContentSize.width),
            height: max(measuredSize.height, estimatedHeight)
        )
    }

    func textRange(for layoutFragment: NSTextLayoutFragment) -> NSRange {
        textSystem.utf16Range(for: layoutFragment)
    }

    static func optionalColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true
        case let (.some(lhs), .some(rhs)):
            CFEqual(lhs, rhs)
        default:
            false
        }
    }

    func textHighlightRects(in layoutFragmentFrame: CGRect, ranges: [NSRange]) -> [CGRect] {
        guard !ranges.isEmpty else { return [] }

        let fragmentLocalBounds = CGRect(origin: .zero, size: layoutFragmentFrame.size)
        return TextLayoutGeometry.standardRects(
            layoutManager: layoutManager,
            rangeConverter: textSystem.rangeConverter,
            ranges: ranges,
            offsetBy: layoutFragmentFrame.origin
        )
        .filter { $0.intersects(fragmentLocalBounds) }
    }
    func measuredHorizontalDocumentLayoutWidth() -> CGFloat {
        let visibleWidth = adjustedVisibleContentSize.width
        guard !text.isEmpty else {
            return visibleWidth
        }

        return max(
            visibleWidth,
            lineMetrics.horizontalDocumentWidth(
                columnWidth: Self.estimatedMonospacedColumnWidth(for: resolvedBaseFont()),
                textContainerInset: textContainerInset.left + textContainerInset.right,
                lineFragmentPadding: container.lineFragmentPadding
            )
        )
    }

    static func estimatedMonospacedColumnWidth(for font: UIFont) -> CGFloat {
        font.pointSize * 0.65
    }

    func invalidateTextLayout() {
        invalidateLayoutManagerLayout()
        setNeedsDisplayForVisibleTextFragments()
        setNeedsLayout()
    }

    func invalidateLayoutManagerLayout() {
        layoutManager.invalidateLayout(for: textContentStorage.documentRange)
        layoutManager.textSelectionNavigation.flushLayoutCache()
    }

    func invalidateHorizontalMeasurement() {
        setNeedsLayout()
    }

    func setNeedsTextLayout() {
        if isLayingOutText {
            needsTextRelayout = true
        } else {
            setNeedsLayout()
        }
    }

    func setNeedsDisplayForVisibleTextFragments() {
        for case let fragmentView as SyntaxEditorView.TextLayoutFragmentView in textContentView.subviews {
            fragmentView.setNeedsDisplay()
        }
    }

    func invalidateSyntaxRenderingAttributes(for ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }

        var invalidatedRanges: [NSRange] = []
        invalidatedRanges.reserveCapacity(ranges.count)
        for range in ranges {
            let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
            guard clamped.length > 0,
                  let textRange = textRange(forUTF16Range: clamped)
            else {
                continue
            }
            layoutManager.invalidateRenderingAttributes(for: textRange)
            invalidatedRanges.append(clamped)
        }

        guard !invalidatedRanges.isEmpty else { return }
        // Revalidate already-laid-out fragments before redrawing: their line
        // fragments cache the rendering attributes captured at layout time, so
        // a bare setNeedsDisplay repaints the stale colors. Applies that arrive
        // without an accompanying layout pass (progressive reset chunks,
        // background drain results) otherwise never recolor the current
        // viewport — only freshly scrolled-in fragments would run the
        // validator. Mirrors the AppKit input view.
        var didInvalidateFragment = false
        for case let fragmentView as SyntaxEditorView.TextLayoutFragmentView in textContentView.subviews {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            guard !TextLayoutGeometry.ranges(invalidatedRanges, intersecting: fragmentRange).isEmpty else {
                continue
            }
            validateSyntaxRenderingAttributes(in: fragmentView.layoutFragment, using: layoutManager)
            fragmentView.setNeedsDisplay()
            didInvalidateFragment = true
        }
        if !didInvalidateFragment {
            setNeedsDisplay()
        }
    }

    func setNeedsDisplayForTextRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }

        var didInvalidateFragment = false
        for case let fragmentView as SyntaxEditorView.TextLayoutFragmentView in textContentView.subviews {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            guard !TextLayoutGeometry.ranges(ranges, intersecting: fragmentRange).isEmpty else {
                continue
            }
            fragmentView.setNeedsDisplay()
            didInvalidateFragment = true
        }
        if !didInvalidateFragment {
            setNeedsDisplay()
        }
    }

    func invalidateTextFragmentViews(intersecting rect: CGRect) {
        for case let fragmentView as SyntaxEditorView.TextLayoutFragmentView in textContentView.subviews {
            guard fragmentView.frame.intersects(rect) else { continue }
            fragmentView.setNeedsDisplay(rect.offsetBy(dx: -fragmentView.frame.minX, dy: -fragmentView.frame.minY))
        }
    }

    func resetHorizontalContentOffset() {
        let targetX = -adjustedContentInset.left
        guard !contentOffset.x.isNearlyEqual(to: targetX) else { return }

        performEditorOwnedScroll {
            setContentOffset(CGPoint(x: targetX, y: contentOffset.y), animated: false)
        }
    }

    public func scrollRangeToVisible(_ range: NSRange) {
        layoutTextIfNeeded()
        let clampedRange = clampedTextRange(range)
        guard let targetRect = withTextInteractionHorizontalOffsetPreservationDisabled({
            contentRectForScrollRange(clampedRange)
        }) else {
            return
        }
        ensureContentSizeContains(targetRect)

        let visibleRect = adjustedVisibleContentRect
        if targetRect.intersects(visibleRect.insetBy(dx: -container.lineFragmentPadding, dy: -4)) {
            return
        }

        scrollContentRectToVisible(targetRect)
    }

    func scheduleScrollSelectionToVisibleIfNeeded() {
        postLayoutAction = { [weak self] in
            self?.scrollSelectionToVisibleIfNeeded()
        }
        setNeedsLayout()
    }

    func layoutAndScrollSelectionForTextInputGeometry() {
        guard bounds.width > 0, bounds.height > 0 else {
            scheduleScrollSelectionToVisibleIfNeeded()
            return
        }

        layoutTextIfNeeded()
        scrollSelectionToVisibleIfNeeded()
    }

    func scrollSelectionToVisibleIfNeeded() {
        guard let targetRect = withTextInteractionHorizontalOffsetPreservationDisabled({
            contentRectForScrollRange(selectedRange)
        }) else { return }
        ensureContentSizeContains(targetRect)
        let visibleRect = adjustedVisibleContentRect
        if targetRect.intersects(visibleRect.insetBy(dx: -container.lineFragmentPadding, dy: -4)) {
            return
        }
        scrollContentRectToVisible(targetRect)
    }

    func contentRectForScrollRange(_ range: NSRange) -> CGRect? {
        if range.length > 0 {
            let firstTextRect = firstRect(for: SyntaxEditorView.TextRange(nsRange: range))
            if firstTextRect.origin.x.isFinite,
               firstTextRect.origin.y.isFinite,
               firstTextRect.size.width.isFinite,
               firstTextRect.size.height.isFinite,
               !firstTextRect.isNull,
               !firstTextRect.isEmpty {
                return firstTextRect
            }
        }

        return contentCaretRectForTextLocation(range.location + range.length)
    }

    func contentCaretRectForTextLocation(_ location: Int) -> CGRect? {
        var targetRect = caretRect(for: SyntaxEditorView.TextPosition(offset: location))
        guard targetRect.origin.x.isFinite,
              targetRect.origin.y.isFinite,
              targetRect.size.width.isFinite,
              targetRect.size.height.isFinite else {
            return nil
        }

        if targetRect.width.isZero {
            targetRect = targetRect.insetBy(dx: -container.lineFragmentPadding, dy: 0)
        }
        targetRect.size.width = max(targetRect.size.width, 2)
        return targetRect
    }

    var adjustedVisibleContentRect: CGRect {
        let insets = adjustedContentInset
        return CGRect(
            origin: CGPoint(
                x: contentOffset.x + insets.left,
                y: contentOffset.y + insets.top
            ),
            size: adjustedVisibleContentSize
        )
    }

    var adjustedVisibleContentSize: CGSize {
        let insets = adjustedContentInset
        return CGSize(
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
    }

    func scrollContentRectToVisible(_ rect: CGRect) {
        ensureContentSizeContains(rect)
        let insets = adjustedContentInset
        let maximumOffset = CGPoint(
            x: max(-insets.left, contentSize.width - bounds.width + insets.right),
            y: max(-insets.top, contentSize.height - bounds.height + insets.bottom)
        )
        var nextOffset = contentOffset
        let visibleRect = adjustedVisibleContentRect

        if rect.minX < visibleRect.minX {
            nextOffset.x = rect.minX - insets.left
        } else if rect.maxX > visibleRect.maxX {
            nextOffset.x = rect.maxX - visibleRect.width - insets.left
        }

        if rect.minY < visibleRect.minY {
            nextOffset.y = rect.minY - insets.top
        } else if rect.maxY > visibleRect.maxY {
            nextOffset.y = rect.maxY - visibleRect.height - insets.top
        }

        nextOffset.x = min(max(nextOffset.x, -insets.left), maximumOffset.x)
        nextOffset.y = min(max(nextOffset.y, -insets.top), maximumOffset.y)
        guard !nextOffset.x.isNearlyEqual(to: contentOffset.x)
                || !nextOffset.y.isNearlyEqual(to: contentOffset.y) else {
            return
        }

        performEditorOwnedScroll {
            setContentOffset(nextOffset, animated: false)
        }
    }

    func ensureContentSizeContains(_ rect: CGRect) {
        let minimumContentSize = adjustedVisibleContentSize
        let nextContentSize = CGSize(
            width: max(contentSize.width, minimumContentSize.width, ceil(rect.maxX)),
            height: max(contentSize.height, minimumContentSize.height, ceil(rect.maxY))
        )
        guard !contentSize.isNearlyEqual(to: nextContentSize) else { return }

        contentSize = nextContentSize
        updateTextContentViewFrameIfNeeded(contentSize: nextContentSize)
    }

    func performEditorOwnedScroll(_ scroll: () -> Void) {
        textInteractionHorizontalOffsetLockGeneration += 1
        preservedTextInteractionHorizontalOffset = nil
        isApplyingEditorOwnedScroll = true
        defer {
            isApplyingEditorOwnedScroll = false
        }
        scroll()
    }

    func withTextInteractionHorizontalOffsetPreservationDisabled<T>(_ work: () -> T) -> T {
        let wasIgnoring = isIgnoringTextInteractionHorizontalOffsetPreservation
        isIgnoringTextInteractionHorizontalOffsetPreservation = true
        defer {
            isIgnoringTextInteractionHorizontalOffsetPreservation = wasIgnoring
        }
        return work()
    }

    func preserveTextInteractionHorizontalOffsetForCurrentTurn() {
        guard !lastAppliedLineWrappingEnabled,
              !isIgnoringTextInteractionHorizontalOffsetPreservation else {
            return
        }

        textInteractionHorizontalOffsetLockGeneration += 1
        let generation = textInteractionHorizontalOffsetLockGeneration
        preservedTextInteractionHorizontalOffset = contentOffset.x

        Task { @MainActor [weak self] in
            guard let self,
                  self.textInteractionHorizontalOffsetLockGeneration == generation else {
                return
            }
            self.preservedTextInteractionHorizontalOffset = nil
        }
    }

    func contentOffsetConstrainedForTextInteraction(_ proposedOffset: CGPoint) -> CGPoint {
        guard !isApplyingEditorOwnedScroll,
              !lastAppliedLineWrappingEnabled,
              !isTracking,
              !isDragging,
              !isDecelerating,
              let preservedX = preservedTextInteractionHorizontalOffset else {
            return proposedOffset
        }

        return CGPoint(x: preservedX, y: proposedOffset.y)
    }

    var shouldPreserveHorizontalOffsetForImplicitTextInteractionScroll: Bool {
        !isApplyingEditorOwnedScroll
            && !lastAppliedLineWrappingEnabled
            && !isTracking
            && !isDragging
            && !isDecelerating
            && preservedTextInteractionHorizontalOffset != nil
    }

    public func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let scrollInsets = adjustedContentInset
        return CGRect(
            x: bounds.origin.x - scrollInsets.left - textContainerInset.left,
            y: bounds.origin.y - scrollInsets.top - textContainerInset.top,
            width: bounds.width
                + scrollInsets.left
                + scrollInsets.right
                + textContainerInset.left
                + textContainerInset.right,
            height: bounds.height
                + scrollInsets.top
                + scrollInsets.bottom
                + textContainerInset.top
                + textContainerInset.bottom
        )
    }

    public func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        lastUsedFragmentViews = Set(
            fragmentViewMap.objectEnumerator()?.allObjects as? [SyntaxEditorView.TextLayoutFragmentView] ?? []
        )
    }

    public func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        let layoutFragmentFrame = textLayoutFragment.layoutFragmentFrame
        let fragmentView: SyntaxEditorView.TextLayoutFragmentView
        if let cachedFragmentView = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cachedFragmentView
            lastUsedFragmentViews.remove(cachedFragmentView)
        } else {
            fragmentView = SyntaxEditorView.TextLayoutFragmentView(
                layoutFragment: textLayoutFragment,
                frame: layoutFragmentFrame
            )
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }
        configureFindHighlights(for: fragmentView, layoutFragmentFrame: layoutFragmentFrame)
        configureBracketHighlights(for: fragmentView, layoutFragmentFrame: layoutFragmentFrame)

        if !fragmentView.frame.isNearlyEqual(to: layoutFragmentFrame) {
            fragmentView.frame = layoutFragmentFrame
            fragmentView.setNeedsDisplay()
        }

        if fragmentView.superview != textContentView {
            textContentView.addSubview(fragmentView)
        }
    }

    public func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()

        if !isLayingOutText {
            updateContentSizeIfNeeded()
        }
    }

    /// Currently laid-out viewport as a UTF-16 range, or nil before first
    /// layout — used as the highlighter's drain-ordering hint.
    func visibleCharacterRangeForHighlightHint() -> NSRange? {
        guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
            return nil
        }
        let range = utf16Range(for: viewportRange)
        return range.length > 0 ? range : nil
    }

    func textLocation(forUTF16Offset offset: Int) -> NSTextLocation? {
        textSystem.textLocation(forUTF16Offset: offset)
    }

    func utf16Offset(for textLocation: NSTextLocation) -> Int {
        textSystem.utf16Offset(for: textLocation)
    }

    func textRange(forUTF16Range range: NSRange) -> NSTextRange? {
        textSystem.textRange(forUTF16Range: range)
    }

    func utf16Range(for textRange: NSTextRange) -> NSRange {
        textSystem.utf16Range(for: textRange)
    }

    func clampedTextRange(_ range: NSRange) -> NSRange {
        clampedTextRange(range, utf16Length: storage.length)
    }

    func clampedTextRange(_ range: NSRange, in source: String) -> NSRange {
        clampedTextRange(range, utf16Length: source.utf16.count)
    }

    func clampedTextRange(_ range: NSRange, utf16Length: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Length)
        let length = min(max(0, range.length), utf16Length - location)
        return NSRange(location: location, length: length)
    }

    func string(in range: NSRange) -> String? {
        let clamped = clampedTextRange(range)
        guard clamped.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: clamped)
    }

    func offset(for position: UITextPosition) -> Int? {
        guard let position = position as? SyntaxEditorView.TextPosition else { return nil }
        return min(max(0, position.offset), text.utf16.count)
    }
}
#endif
