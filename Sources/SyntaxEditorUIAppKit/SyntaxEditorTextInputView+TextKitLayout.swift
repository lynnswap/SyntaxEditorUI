#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
    var viewportPreparationExpansion: CGFloat {
        min(max(64, bounds.height * 0.25), 240)
    }
    var visibleViewportBounds: CGRect {
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        var result = visible
        if result.minX < 0 {
            result.size.width += result.minX
            result.origin.x = 0
        }
        if result.minY < 0 {
            result.size.height += result.minY
            result.origin.y = 0
        }
        result.size.width = max(result.width, bounds.width)
        return result
    }
    var currentViewportBounds: CGRect {
        let visible = visibleViewportBounds
        let prepared = preparedContentRect
        guard !prepared.isEmpty, prepared.intersects(visible) else {
            return visible
        }

        let minY = max(0, min(prepared.minY, visible.minY))
        let maxY = max(prepared.maxY, visible.maxY)
        return CGRect(
            x: 0,
            y: minY,
            width: max(bounds.width, visible.width),
            height: max(visible.height, maxY - minY)
        )
    }
    var syntaxRenderingViewportBounds: CGRect {
        let visible = visibleViewportBounds
        let expansion = viewportPreparationExpansion
        let minY = max(0, visible.minY - expansion)
        let maxY = visible.maxY + expansion
        return CGRect(
            x: 0,
            y: minY,
            width: max(bounds.width, visible.width),
            height: max(visible.height, maxY - minY)
        )
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

    func textRange(for layoutFragment: NSTextLayoutFragment) -> NSRange {
        textSystem.utf16Range(for: layoutFragment)
    }

    func invalidateTextLayout() {
        updateDocumentFrameForCurrentText()
        textLayoutManager.invalidateLayout(for: textContentStorage.documentRange)
        textLayoutManager.textSelectionNavigation.flushLayoutCache()
        layoutVisibleViewport()
        updateDecorationRenderingForVisibleFragments()
        setNeedsDisplayForVisibleTextFragments()
    }

    func updateDocumentFrameForCurrentText() {
        updateDocumentFrameForCurrentText(
            minimumContentSize: effectiveScrollContentSize,
            lineWrappingEnabled: lineWrappingStateProvider?() ?? !isHorizontallyResizable
        )
    }

    func updateDocumentFrameForCurrentText(
        minimumContentSize: NSSize,
        lineWrappingEnabled: Bool
    ) {
        let estimatedDocumentSize = estimatedDocumentSize(
            minimumContentSize: minimumContentSize,
            lineWrappingEnabled: lineWrappingEnabled
        )
        let nextSize = if lineWrappingEnabled {
            NSSize(width: max(0, minimumContentSize.width), height: estimatedDocumentSize.height)
        } else {
            estimatedDocumentSize
        }

        guard !frame.size.isNearlyEqual(to: nextSize) else { return }

        setFrameSize(nextSize)
        textContentView.frame = bounds
        needsLayout = true
    }

    private var effectiveScrollContentSize: NSSize {
        guard let scrollView = enclosingScrollView else {
            return bounds.size
        }

        let contentSize = scrollView.contentSize
        let contentInsets = scrollView.contentView.contentInsets
        let width = contentSize.width > 0 ? contentSize.width : bounds.width
        let height = contentSize.height > 0 ? contentSize.height : bounds.height
        return NSSize(
            width: max(0, width - max(0, contentInsets.left) - max(0, contentInsets.right)),
            height: max(0, height - max(0, contentInsets.top) - max(0, contentInsets.bottom))
        )
    }

    private func estimatedDocumentSize(
        minimumContentSize: NSSize,
        lineWrappingEnabled: Bool
    ) -> NSSize {
        let baseFont = font ?? (typingAttributes[.font] as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = max(1, ceil(baseFont.ascender - baseFont.descender + baseFont.leading))
        let estimatedColumnWidth = max(1, baseFont.pointSize * 0.65)
        return lineMetrics.estimatedDocumentSize(
            minimumSize: minimumContentSize,
            lineWrappingEnabled: lineWrappingEnabled,
            lineHeight: lineHeight,
            columnWidth: estimatedColumnWidth,
            lineFragmentPadding: textContainer?.lineFragmentPadding ?? 0
        )
    }

    func layoutVisibleViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        textLayoutManager.textViewportLayoutController.layoutViewport()
    }

    func layoutVisibleViewportIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let viewportBounds = textLayoutManager.textViewportLayoutController.viewportBounds
        if viewportBounds.contains(visibleViewportBounds) {
            return
        }
        layoutVisibleViewport()
    }

    func setNeedsDisplayForTextRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }

        layoutVisibleViewportIfNeeded()
        var didInvalidateFragment = false
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            guard !TextLayoutGeometry.ranges(ranges, intersecting: fragmentRange).isEmpty else {
                continue
            }
            fragmentView.needsDisplay = true
            fragmentDisplayInvalidationCount += 1
            didInvalidateFragment = true
        }
        if !didInvalidateFragment {
            needsDisplay = true
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
            textLayoutManager.invalidateRenderingAttributes(for: textRange)
            invalidatedRanges.append(clamped)
        }

        guard !invalidatedRanges.isEmpty else { return }

        layoutVisibleViewportIfNeeded()
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            guard !TextLayoutGeometry.ranges(invalidatedRanges, intersecting: fragmentRange).isEmpty else {
                continue
            }
            validateSyntaxRenderingAttributes(
                in: fragmentView.layoutFragment,
                using: textLayoutManager
            )
            fragmentView.needsDisplay = true
        }
    }

    func setNeedsDisplayForVisibleTextFragments() {
        layoutVisibleViewportIfNeeded()
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            guard fragmentView.frame.intersects(currentViewportBounds) else { continue }
            fragmentView.needsDisplay = true
            fragmentDisplayInvalidationCount += 1
        }
    }

    func visibleCharacterRange() -> NSRange? {
        layoutVisibleViewportIfNeeded()
        if let range = viewportCharacterRange() {
            return range
        }
        return visibleCharacterRangeFromFragments()
    }

    /// Passive variant for the highlighter's drain-ordering hint: reads the
    /// current viewport state without forcing layout. Safe to call from text
    /// mutation processing, where triggering TextKit layout is not.
    func visibleCharacterRangeWithoutLayout() -> NSRange? {
        viewportCharacterRange() ?? visibleCharacterRangeFromFragments()
    }

    func viewportCharacterRange() -> NSRange? {
        guard let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange else {
            return nil
        }
        let range = utf16Range(for: viewportRange)
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
        return clamped.length > 0 ? clamped : nil
    }

    func visibleCharacterRangeFromFragments() -> NSRange? {
        var visibleRange: NSRange?
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            guard fragmentView.frame.intersects(currentViewportBounds) else { continue }
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            if let current = visibleRange {
                let lowerBound = min(current.location, fragmentRange.location)
                let upperBound = max(current.upperBound, fragmentRange.upperBound)
                visibleRange = NSRange(location: lowerBound, length: upperBound - lowerBound)
            } else {
                visibleRange = fragmentRange
            }
        }
        return visibleRange
    }

    func updateBracketHighlights(ranges: [NSRange], color: NSColor?) {
        bracketHighlightRanges = ranges
        bracketHighlightColor = color
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            configureBracketHighlights(for: fragmentView)
        }
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        SyntaxEditorTextInputView.TextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    func setNeedsDisplayForContentRect(_ rect: NSRect) {
        guard !rect.isEmpty else { return }

        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            guard fragmentView.frame.intersects(rect) else { continue }
            fragmentView.setNeedsDisplay(rect.offsetBy(dx: -fragmentView.frame.minX, dy: -fragmentView.frame.minY))
            fragmentDisplayInvalidationCount += 1
        }
    }

    func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        currentViewportBounds
    }

    func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        lastUsedFragmentViews = Set(
            fragmentViewMap.objectEnumerator()?.allObjects as? [SyntaxEditorTextInputView.TextLayoutFragmentView] ?? []
        )
    }

    func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        let layoutFragmentFrame = textLayoutFragment.layoutFragmentFrame
        let fragmentView: SyntaxEditorTextInputView.TextLayoutFragmentView
        if let cached = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cached
            lastUsedFragmentViews.remove(cached)
        } else {
            fragmentView = SyntaxEditorTextInputView.TextLayoutFragmentView(
                layoutFragment: textLayoutFragment,
                frame: layoutFragmentFrame
            )
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }
        fragmentView.textInputView = self

        if fragmentView.frame != layoutFragmentFrame {
            fragmentView.frame = layoutFragmentFrame
            fragmentView.needsDisplay = true
        }
        if unsafe fragmentView.superview != textContentView {
            textContentView.addSubview(fragmentView)
        }
        configureFindHighlights(for: fragmentView)
        configureSelectionHighlights(for: fragmentView)
        configureBracketHighlights(for: fragmentView)
    }

    func configureSyntaxRenderingAttributesValidator() {
        textLayoutManager.renderingAttributesValidator = { [weak self] textLayoutManager, textLayoutFragment in
            MainActor.assumeIsolated {
                self?.validateSyntaxRenderingAttributes(
                    in: textLayoutFragment,
                    using: textLayoutManager
                )
            }
        }
    }

    private func validateSyntaxRenderingAttributes(
        in textLayoutFragment: NSTextLayoutFragment,
        using textLayoutManager: NSTextLayoutManager,
        targetBounds: CGRect? = nil
    ) {
        let fragmentRange = textRange(for: textLayoutFragment)
        guard fragmentRange.length > 0 else { return }

        let targetRanges = syntaxRenderingAttributeTargetRanges(
            in: textLayoutFragment,
            fragmentRange: fragmentRange,
            targetBounds: targetBounds
        )
        guard !targetRanges.isEmpty else { return }

        let baseForeground = typingAttributes[.foregroundColor] as? NSColor
        for targetRange in targetRanges {
            let displayRanges = syntaxRenderingAttributeDisplayRanges(for: targetRange)
            for displayRange in displayRanges {
                guard let targetTextRange = textRange(forUTF16Range: displayRange) else { continue }
                syntaxRenderingAttributeUTF16LengthForTesting += displayRange.length

                if let baseForeground {
                    textLayoutManager.addRenderingAttribute(
                        .foregroundColor,
                        value: baseForeground,
                        for: targetTextRange
                    )
                }

                let resolvedRuns = textSystem.styleStore.resolveVisibleRuns(in: displayRange)
                for colorRun in resolvedRuns.colorRuns {
                    guard let textRange = textRange(forUTF16Range: colorRun.range) else { continue }
                    syntaxRenderingAttributeColorRunCountForTesting += 1
                    textLayoutManager.addRenderingAttribute(
                        .foregroundColor,
                        value: colorRun.color,
                        for: textRange
                    )
                }

                for fontRun in resolvedRuns.fontRuns {
                    guard let textRange = textRange(forUTF16Range: fontRun.range) else { continue }
                    textLayoutManager.addRenderingAttribute(
                        .font,
                        value: fontRun.font,
                        for: textRange
                    )
                }
            }
        }
        syntaxRenderingAttributeApplicationCountForTesting += 1
    }

    private func syntaxRenderingAttributeDisplayRanges(for targetRange: NSRange) -> [NSRange] {
        guard let markedRange = markedTextRangeStorage else {
            return [targetRange]
        }
        let markedIntersection = NSIntersectionRange(targetRange, markedRange)
        guard markedIntersection.length > 0 else {
            return [targetRange]
        }

        var ranges: [NSRange] = []
        if targetRange.location < markedIntersection.location {
            ranges.append(NSRange(
                location: targetRange.location,
                length: markedIntersection.location - targetRange.location
            ))
        }
        if markedIntersection.upperBound < targetRange.upperBound {
            ranges.append(NSRange(
                location: markedIntersection.upperBound,
                length: targetRange.upperBound - markedIntersection.upperBound
            ))
        }
        return ranges
    }

    private func syntaxRenderingAttributeTargetRanges(
        in textLayoutFragment: NSTextLayoutFragment,
        fragmentRange: NSRange,
        targetBounds: CGRect? = nil
    ) -> [NSRange] {
        let lineFragments = textLayoutFragment.textLineFragments
        guard !lineFragments.isEmpty else {
            return fallbackSyntaxRenderingAttributeTargetRanges(for: fragmentRange)
        }

        let viewportBounds = targetBounds ?? syntaxRenderingViewportBounds
        let fragmentStart = utf16Offset(for: textLayoutFragment.rangeInElement.location)
        let fragmentOrigin = textLayoutFragment.layoutFragmentFrame.origin
        var ranges: [NSRange] = []
        ranges.reserveCapacity(min(lineFragments.count, 64))

        for lineFragment in lineFragments {
            let lineFrame = lineFragment.typographicBounds.offsetBy(
                dx: fragmentOrigin.x,
                dy: fragmentOrigin.y
            )
            guard lineFrame.insetBy(dx: 0, dy: -2).intersects(viewportBounds) else {
                continue
            }

            let absoluteRange = NSRange(
                location: fragmentStart + lineFragment.characterRange.location,
                length: lineFragment.characterRange.length
            )
            let clampedRange = SyntaxEditorRangeUtilities.clampedRange(
                absoluteRange,
                utf16Length: storage.length
            )
            let targetRange = NSIntersectionRange(clampedRange, fragmentRange)
            guard targetRange.length > 0 else { continue }
            ranges.append(targetRange)
        }

        return Self.mergedSyntaxRenderingAttributeRanges(ranges)
    }

    private func fallbackSyntaxRenderingAttributeTargetRanges(for fragmentRange: NSRange) -> [NSRange] {
        if let viewportRange = viewportCharacterRange() {
            let targetRange = NSIntersectionRange(fragmentRange, viewportRange)
            if targetRange.length > 0 {
                return [targetRange]
            }
        }

        return [fragmentRange]
    }

    private static func mergedSyntaxRenderingAttributeRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }

        let sortedRanges = ranges.sorted {
            if $0.location == $1.location {
                return $0.upperBound < $1.upperBound
            }
            return $0.location < $1.location
        }

        var mergedRanges: [NSRange] = []
        mergedRanges.reserveCapacity(sortedRanges.count)
        for range in sortedRanges {
            guard range.length > 0 else { continue }
            guard let lastRange = mergedRanges.last else {
                mergedRanges.append(range)
                continue
            }

            if range.location <= lastRange.upperBound {
                let mergedUpperBound = max(lastRange.upperBound, range.upperBound)
                mergedRanges[mergedRanges.count - 1] = NSRange(
                    location: lastRange.location,
                    length: mergedUpperBound - lastRange.location
                )
            } else {
                mergedRanges.append(range)
            }
        }
        return mergedRanges
    }

    func validateSyntaxRenderingAttributesForDisplay(
        in textLayoutFragment: NSTextLayoutFragment,
        dirtyRectInFragment: CGRect
    ) {
        guard !dirtyRectInFragment.isEmpty else { return }

        let fragmentOrigin = textLayoutFragment.layoutFragmentFrame.origin
        let dirtyBounds = dirtyRectInFragment.offsetBy(dx: fragmentOrigin.x, dy: fragmentOrigin.y)
        let targetBounds = dirtyBounds.intersection(syntaxRenderingViewportBounds)
        guard !targetBounds.isNull, !targetBounds.isEmpty else { return }

        validateSyntaxRenderingAttributes(
            in: textLayoutFragment,
            using: textLayoutManager,
            targetBounds: targetBounds
        )
    }

    func resetSyntaxRenderingAttributeCountersForTesting() {
        syntaxRenderingAttributeApplicationCountForTesting = 0
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

    func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()
        updateInsertionIndicator()
    }
}

private extension CGFloat {
    func isNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}

private extension NSSize {
    func isNearlyEqual(to other: NSSize, tolerance: CGFloat = 0.5) -> Bool {
        width.isNearlyEqual(to: other.width, tolerance: tolerance)
            && height.isNearlyEqual(to: other.height, tolerance: tolerance)
    }
}
#endif
