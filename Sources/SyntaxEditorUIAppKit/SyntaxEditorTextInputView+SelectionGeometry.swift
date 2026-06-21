#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
    func moveSelection(
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination,
        extending: Bool,
        confined: Bool
    ) {
        guard isSelectable else { return }

        let currentSelections = textLayoutManager.textSelections.isEmpty
            ? textSelections(for: selectedRangeStorage)
            : textLayoutManager.textSelections
        let nextSelections = currentSelections.compactMap { selection in
            textLayoutManager.textSelectionNavigation.destinationSelection(
                for: selection,
                direction: direction,
                destination: destination,
                extending: extending,
                confined: confined
            )
        }
        guard !nextSelections.isEmpty else { return }

        applyTextSelections(nextSelections)
    }

    func updateTextSelection(
        interactingAt point: NSPoint,
        inContainerAt location: NSTextLocation? = nil,
        anchors: [NSTextSelection] = [],
        extending: Bool = false,
        isDragging: Bool = false,
        visual: Bool = false
    ) {
        guard isSelectable else { return }

        var modifiers: NSTextSelectionNavigation.Modifier = []
        if extending {
            modifiers.insert(.extend)
        }
        if visual {
            modifiers.insert(.visual)
        }

        let selections = textLayoutManager.textSelectionNavigation.textSelections(
            interactingAt: point,
            inContainerAt: location ?? textContentStorage.documentRange.location,
            anchors: anchors,
            modifiers: modifiers,
            selecting: isDragging,
            bounds: textLayoutManager.usageBoundsForTextContainer
        )
        guard !selections.isEmpty else { return }

        applyTextSelections(selections)
    }

    func selectGranularity(_ granularity: NSTextSelection.Granularity) {
        guard isSelectable,
              let selection = textLayoutManager.textSelections.last
        else {
            return
        }

        applyTextSelections([
            textLayoutManager.textSelectionNavigation.textSelection(
                for: granularity,
                enclosing: selection
            ),
        ])
    }


    func syncTextLayoutSelection() {
        guard let textRange = textRange(forUTF16Range: selectedRangeStorage) else { return }
        let affinity: NSTextSelection.Affinity = selectedRangeStorage.length == 0
            && isHardLineBreakCaretLocation(selectedRangeStorage.location)
            ? .upstream
            : .downstream
        textLayoutManager.textSelections = [NSTextSelection(range: textRange, affinity: affinity, granularity: .character)]
    }

    func characterIndex(at point: NSPoint) -> Int {
        if let location = caretTextLocation(interactingAt: point) {
            return utf16Offset(for: location)
        }

        let selections = textLayoutManager.textSelectionNavigation.textSelections(
            interactingAt: point,
            inContainerAt: textContentStorage.documentRange.location,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: textLayoutManager.usageBoundsForTextContainer
        )
        if let location = selections.first?.textRanges.first?.location {
            return utf16Offset(for: location)
        }

        return point.y >= bounds.maxY ? storage.length : 0
    }

    private func caretTextLocation(interactingAt point: NSPoint) -> NSTextLocation? {
        guard let lineFragmentRange = textLayoutManager.lineFragmentRange(
            for: point,
            inContainerAt: textContentStorage.documentRange.location
        ) else {
            return nil
        }

        if let layoutFragment = textLayoutManager.textLayoutFragment(for: point) {
            let frame = layoutFragment.layoutFragmentFrame
            if point.y < frame.minY || point.y > frame.maxY {
                return nil
            }
        }

        var closestDistance = CGFloat.greatestFiniteMagnitude
        var closestLocation: NSTextLocation?
        var maximumCaretOffset = -CGFloat.greatestFiniteMagnitude
        let lineEndLocation = caretLineEndLocation(for: lineFragmentRange)
        let lineEndOffset = utf16Offset(for: lineEndLocation)
        unsafe textLayoutManager.enumerateCaretOffsetsInLineFragment(at: lineFragmentRange.location) { caretOffset, location, leadingEdge, stop in
            maximumCaretOffset = max(maximumCaretOffset, caretOffset)
            let distance = abs(caretOffset - point.x)
            let locationOffset = utf16Offset(for: location)
            let isLineEndTrailingEdge = !leadingEdge && isTrailingCaretOffsetAtLineEnd(
                locationOffset,
                lineEndOffset: lineEndOffset
            )
            guard leadingEdge || isLineEndTrailingEdge else { return }

            if distance < closestDistance {
                closestDistance = distance
                closestLocation = isLineEndTrailingEdge ? lineEndLocation : location
            } else if distance > closestDistance {
                unsafe stop.pointee = true
            }
        }

        if point.x > maximumCaretOffset {
            return lineEndLocation
        }

        return closestLocation
    }

    private func caretLineEndLocation(for lineFragmentRange: NSTextRange) -> NSTextLocation {
        let endOffset = utf16Offset(for: lineFragmentRange.endLocation)
        if let lineBreakOffset = lineBreakCaretOffset(endingAt: endOffset),
           let lineBreakLocation = textLocation(forUTF16Offset: lineBreakOffset) {
            return lineBreakLocation
        }
        return lineFragmentRange.endLocation
    }

    private func lineBreakCaretOffset(endingAt endOffset: Int) -> Int? {
        let lineBreakOffset = endOffset - 1
        guard isHardLineBreakCaretLocation(lineBreakOffset) else { return nil }

        let source = string as NSString
        let character = source.character(at: lineBreakOffset)
        if character == 0x0A, lineBreakOffset > 0 {
            let previousCharacter = source.character(at: lineBreakOffset - 1)
            if previousCharacter == 0x0D {
                return lineBreakOffset - 1
            }
        }

        return lineBreakOffset
    }

    private func isHardLineBreakCaretLocation(_ location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        let character = (string as NSString).character(at: location)
        return character == 0x0A || character == 0x0D
    }

    private func isTrailingCaretOffsetAtLineEnd(_ locationOffset: Int, lineEndOffset: Int) -> Bool {
        if locationOffset == lineEndOffset {
            return true
        }

        guard locationOffset >= 0,
              locationOffset < lineEndOffset,
              lineEndOffset <= storage.length
        else {
            return false
        }

        let characterRange = (string as NSString).rangeOfComposedCharacterSequence(at: locationOffset)
        return characterRange.upperBound == lineEndOffset
    }

    private func textSelections(for range: NSRange) -> [NSTextSelection] {
        guard let textRange = textRange(forUTF16Range: range) else { return [] }
        return [NSTextSelection(range: textRange, affinity: .downstream, granularity: .character)]
    }

    private func applyTextSelections(_ selections: [NSTextSelection]) {
        guard !selections.isEmpty else { return }

        textLayoutManager.textSelections = selections
        guard let range = nsRange(for: selections.first) else { return }
        updateSelectedRangeStorage(range)
        updateSelectionRendering()
        needsDisplay = true
    }

    private func nsRange(for selection: NSTextSelection?) -> NSRange? {
        guard let selection,
              let firstRange = selection.textRanges.first
        else {
            return nil
        }

        var lowerBound = utf16Offset(for: firstRange.location)
        var upperBound = utf16Offset(for: firstRange.endLocation)
        for textRange in selection.textRanges.dropFirst() {
            lowerBound = min(lowerBound, utf16Offset(for: textRange.location))
            upperBound = max(upperBound, utf16Offset(for: textRange.endLocation))
        }
        return SyntaxEditorRangeUtilities.clampedRange(
            NSRange(location: lowerBound, length: max(0, upperBound - lowerBound)),
            utf16Length: storage.length
        )
    }

    func updateSelectedRangeStorage(_ range: NSRange) {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
        guard clamped != selectedRangeStorage else { return }

        selectedRangeStorage = clamped
        didChangeSelection?()
    }

    func rectForCharacterRange(_ range: NSRange) -> NSRect {
        let rects = rectsForCharacterRange(range)
        guard !rects.isEmpty else { return bounds }
        return rects.reduce(NSRect.zero) { partialResult, rect in
            partialResult == .zero ? rect : partialResult.union(rect)
        }
    }

    func rectsForCharacterRange(_ range: NSRange) -> [NSRect] {
        TextLayoutGeometry.standardRects(
            layoutManager: textLayoutManager,
            rangeConverter: textSystem.rangeConverter,
            ranges: [range]
        )
    }

    func updateSelectionRendering() {
        layoutVisibleViewport()
        updateDecorationRenderingForVisibleFragments()
    }

    func updateDecorationRenderingForVisibleFragments() {
        for case let fragmentView as SyntaxEditorTextInputView.TextLayoutFragmentView in textContentView.subviews {
            configureFindHighlights(for: fragmentView)
            configureSelectionHighlights(for: fragmentView)
        }
        updateInsertionIndicator()
    }

    func updateInsertionIndicator() {
        guard unsafe window?.firstResponder === self,
              isEditable,
              selectedRangeStorage.length == 0,
              isCaretVisibleInCurrentViewport(selectedRangeStorage.location),
              let caretRect = caretRect(forUTF16Location: selectedRangeStorage.location)
        else {
            insertionIndicator.displayMode = .hidden
            insertionIndicator.isHidden = true
            return
        }

        insertionIndicator.frame = caretRect
        insertionIndicator.isHidden = false
        insertionIndicator.displayMode = .automatic
    }

    private func isCaretVisibleInCurrentViewport(_ location: Int) -> Bool {
        let visibleRange = viewportCharacterRange() ?? visibleCharacterRangeFromFragments()
        guard let visibleRange else { return false }
        return location >= visibleRange.location && location <= visibleRange.upperBound
    }

    private func caretRect(forUTF16Location location: Int) -> CGRect? {
        caretGeometryQueryCountForTesting += 1
        guard let textLocation = textLocation(forUTF16Offset: location) else { return nil }
        let textRange = NSTextRange(location: textLocation)

        textLayoutManager.ensureLayout(for: textRange)
        let lineLookupOffset = textLineFragmentLookupUTF16Location(forUTF16Location: location)
        let lineLookupLocation = self.textLocation(forUTF16Offset: lineLookupOffset) ?? textLocation
        if let caretRect = textLayoutLineCaretRect(
            forUTF16Location: location,
            lineLookupUTF16Location: lineLookupOffset,
            textLocation: lineLookupLocation
        ) {
            return caretRect
        }

        var options: NSTextLayoutManager.SegmentOptions = [.rangeNotRequired]
        if isHardLineBreakCaretLocation(location) {
            options.insert(.upstreamAffinity)
        }
        var caretRect: CGRect?
        textLayoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: options
        ) { _, rect, _, _ in
            caretRect = rect
            return false
        }
        return caretRect
    }

    private func textLineFragmentLookupUTF16Location(forUTF16Location location: Int) -> Int {
        let textLength = storage.length
        let clampedLocation = min(max(0, location), textLength)

        if isHardLineBreakCaretLocation(clampedLocation),
           clampedLocation > 0,
           !isHardLineBreakCaretLocation(clampedLocation - 1) {
            return clampedLocation - 1
        }

        if clampedLocation == textLength,
           textLength > 0,
           !isHardLineBreakCaretLocation(textLength - 1) {
            return textLength - 1
        }

        return clampedLocation
    }

    private func textLayoutLineCaretRect(
        forUTF16Location location: Int,
        lineLookupUTF16Location: Int,
        textLocation: NSTextLocation
    ) -> CGRect? {
        guard let (layoutFragment, lineFragment) = textLayoutLineFragment(
                containingUTF16Offset: lineLookupUTF16Location,
                preferredTextLocation: textLocation
              ),
              let lineStartLocation = textContentStorage.location(
                layoutFragment.rangeInElement.location,
                offsetBy: lineFragment.characterRange.location
              )
        else {
            return nil
        }

        let clampedLocation = min(max(0, location), storage.length)
        var lineEndCaretX: CGFloat?
        var exactCaretX: CGFloat?
        var resolvedCaretX: CGFloat?
        var closestDistance = Int.max
        unsafe textLayoutManager.enumerateCaretOffsetsInLineFragment(at: lineStartLocation) { caretOffset, caretLocation, _, stop in
            lineEndCaretX = max(lineEndCaretX ?? caretOffset, caretOffset)
            let caretUTF16Offset = utf16Offset(for: caretLocation)
            let distance = abs(caretUTF16Offset - clampedLocation)
            if distance < closestDistance {
                closestDistance = distance
                resolvedCaretX = caretOffset
            }

            if caretUTF16Offset == clampedLocation {
                exactCaretX = caretOffset
                if !usesLineEndCaretX(forUTF16Location: clampedLocation) {
                    unsafe stop.pointee = true
                }
            }
        }

        let caretX = usesLineEndCaretX(forUTF16Location: clampedLocation)
            ? lineEndCaretX
            : exactCaretX ?? resolvedCaretX
        guard let caretX,
              caretX.isFinite
        else {
            return nil
        }
        let lineFrame = lineFragment.typographicBounds.offsetBy(
            dx: layoutFragment.layoutFragmentFrame.minX,
            dy: layoutFragment.layoutFragmentFrame.minY
        )
        let lineHeight = font.map { max(1, ceil($0.ascender - $0.descender + $0.leading)) } ?? lineFrame.height
        let indicatorWidth = max(2, 1 / max(unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1))
        return CGRect(
            x: caretX,
            y: lineFrame.minY,
            width: indicatorWidth,
            height: max(lineHeight, lineFrame.height)
        )
    }

    private func textLayoutLineFragment(
        containingUTF16Offset offset: Int,
        preferredTextLocation: NSTextLocation
    ) -> (NSTextLayoutFragment, NSTextLineFragment)? {
        if let layoutFragment = textLayoutManager.textLayoutFragment(for: preferredTextLocation),
           let lineFragment = textLineFragment(containingUTF16Offset: offset, in: layoutFragment) {
            return (layoutFragment, lineFragment)
        }

        var result: (NSTextLayoutFragment, NSTextLineFragment)?
        textLayoutManager.enumerateTextLayoutFragments(
            from: textContentStorage.documentRange.location,
            options: [.ensuresLayout]
        ) { layoutFragment in
            let fragmentStart = utf16Offset(for: layoutFragment.rangeInElement.location)
            guard fragmentStart <= offset else {
                return false
            }

            let fragmentEnd = utf16Offset(for: layoutFragment.rangeInElement.endLocation)
            guard offset <= fragmentEnd else {
                return true
            }

            if let lineFragment = textLineFragment(containingUTF16Offset: offset, in: layoutFragment) {
                result = (layoutFragment, lineFragment)
                return false
            }
            return true
        }

        return result
    }

    private func usesLineEndCaretX(forUTF16Location location: Int) -> Bool {
        if isHardLineBreakCaretLocation(location) {
            return true
        }

        let textLength = storage.length
        return location == textLength
            && textLength > 0
            && !isHardLineBreakCaretLocation(textLength - 1)
    }

    private func textLineFragment(
        containingUTF16Offset offset: Int,
        in layoutFragment: NSTextLayoutFragment
    ) -> NSTextLineFragment? {
        let fragmentStart = utf16Offset(for: layoutFragment.rangeInElement.location)
        let textLength = storage.length
        let clampedOffset = min(max(0, offset), textLength)
        var documentEndLineFragment: NSTextLineFragment?

        for lineFragment in layoutFragment.textLineFragments {
            let lineStart = fragmentStart + lineFragment.characterRange.location
            let lineEnd = lineStart + lineFragment.characterRange.length

            if lineFragment.characterRange.length == 0 {
                if clampedOffset == lineStart {
                    return lineFragment
                }
                continue
            }

            if clampedOffset >= lineStart && clampedOffset < lineEnd {
                return lineFragment
            }

            if clampedOffset == lineEnd {
                if clampedOffset < textLength && isHardLineBreakCaretLocation(clampedOffset) {
                    return lineFragment
                }
                if clampedOffset == textLength {
                    documentEndLineFragment = lineFragment
                }
            }
        }

        return documentEndLineFragment
    }

    func configureSelectionHighlights(for fragmentView: SyntaxEditorTextInputView.TextLayoutFragmentView) {
        guard selectedRangeStorage.length > 0 else {
            fragmentView.setSelectionHighlights(rects: [], color: nil)
            return
        }

        let fragmentRange = textRange(for: fragmentView.layoutFragment)
        guard let intersection = TextLayoutGeometry
            .ranges([selectedRangeStorage], intersecting: fragmentRange)
            .first
        else {
            fragmentView.setSelectionHighlights(rects: [], color: nil)
            return
        }

        let rects = TextLayoutGeometry.selectionRects(
            layoutManager: textLayoutManager,
            rangeConverter: textSystem.rangeConverter,
            ranges: [intersection],
            offsetBy: fragmentView.frame.origin
        )

        fragmentView.setSelectionHighlights(rects: rects, color: .selectedTextBackgroundColor)
    }

    func configureBracketHighlights(for fragmentView: SyntaxEditorTextInputView.TextLayoutFragmentView) {
        guard !bracketHighlightRanges.isEmpty,
              let bracketHighlightColor
        else {
            fragmentView.setBracketHighlights(rects: [], color: nil)
            return
        }

        let fragmentRange = textRange(for: fragmentView.layoutFragment)
        let ranges = TextLayoutGeometry.ranges(bracketHighlightRanges, intersecting: fragmentRange)
        guard !ranges.isEmpty else {
            fragmentView.setBracketHighlights(rects: [], color: nil)
            return
        }

        let rects = ranges.map(rectForCharacterRange).map {
            $0.offsetBy(dx: -fragmentView.frame.minX, dy: -fragmentView.frame.minY)
        }
        fragmentView.setBracketHighlights(rects: rects, color: bracketHighlightColor)
    }
}
#endif
