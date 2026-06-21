#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
    var textContainerOrigin: NSPoint { .zero }

    var allowsMultipleSelection: Bool { false }
    var selectedRanges: [NSValue] {
        get { [NSValue(range: selectedRangeStorage)] }
        set {
            guard let firstRange = newValue.first?.rangeValue else { return }
            setSelectedRange(firstRange)
        }
    }
    var firstSelectedRange: NSRange { selectedRangeStorage }
    var visibleCharacterRanges: [NSValue] {
        if let range = visibleCharacterRange() {
            return [NSValue(range: range)]
        }
        return [NSValue(range: NSRange(location: 0, length: storage.length))]
    }
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

    var textStorage: NSTextStorage? { storage }
    var storage: NSTextStorage { textSystem.textStorage }
    var layoutManager: NSLayoutManager? { nil }
    var textLayoutManager: NSTextLayoutManager { textSystem.layoutManager }
    var textContentStorage: NSTextContentStorage { textSystem.textContentStorage }
    var textContainer: NSTextContainer? { textSystem.container }

    var string: String {
        get { storage.string }
        set {
            textFinder.noteClientStringWillChange()
            lineMetrics.reset(source: newValue)
            textContentStorage.performEditingTransaction {
                storage.setAttributedString(NSAttributedString(string: newValue, attributes: typingAttributes))
            }
            setSelectedRange(NSRange(location: min(selectedRangeStorage.location, storage.length), length: 0))
            invalidateTextLayout()
            rebuildFindHighlightRangeIndex()
            updateFindHighlightsForVisibleFragments()
            didChangeText?()
        }
    }

    func setSelectedRange(_ range: NSRange) {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
        guard clamped != selectedRangeStorage else { return }
        updateSelectedRangeStorage(clamped)
        syncTextLayoutSelection()
        updateSelectionRendering()
        needsDisplay = true
    }

    func shouldChangeText(inRanges affectedRanges: [NSRange], replacementStrings: [String]) -> Bool {
        shouldChangeText?(affectedRanges, replacementStrings) ?? true
    }

    func didChangeTextNotification() {
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: self)
        didChangeText?()
    }

    func breakUndoCoalescing() {}

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        let replacement = (string as? NSAttributedString)?.string ?? "\(string)"
        let markedRange = markedTextRangeStorage
        let markedAttributedString = markedTextAttributedStringStorage
        let range = markedRange ?? effectiveReplacementRange(replacementRange)
        if let markedRange {
            markedTextRangeStorage = nil
            markedTextAttributedStringStorage = nil
            invalidateSyntaxRenderingAttributesForMarkedTextChange(from: markedRange, to: nil)
        }
        let didReplace = replaceText(
            in: range,
            with: replacement,
            selectedRange: NSRange(location: range.location + replacement.utf16.count, length: 0)
        )
        if !didReplace {
            markedTextRangeStorage = markedRange
            markedTextAttributedStringStorage = markedAttributedString
            if let markedRange {
                invalidateSyntaxRenderingAttributesForMarkedTextChange(from: nil, to: markedRange)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isEditable else { return }
        let attributedReplacement = markedTextAttributedReplacement(from: string)
        let replacement = attributedReplacement.string
        let previousMarkedRange = markedTextRangeStorage
        let range = markedTextRangeStorage ?? effectiveReplacementRange(replacementRange)
        let markedLength = replacement.utf16.count
        let didReplace = replaceText(
            in: range,
            with: attributedReplacement,
            selectedRange: NSRange(
                location: range.location + min(max(0, selectedRange.location), markedLength),
                length: min(max(0, selectedRange.length), markedLength)
            )
        )
        guard didReplace else { return }
        let markedRange = replacement.isEmpty ? nil : NSRange(location: range.location, length: markedLength)
        markedTextRangeStorage = markedRange
        markedTextAttributedStringStorage = replacement.isEmpty ? nil : attributedReplacement
        applyMarkedTextAttributes()
        invalidateSyntaxRenderingAttributesForMarkedTextChange(from: previousMarkedRange, to: markedRange)
    }

    func unmarkText() {
        let previousMarkedRange = markedTextRangeStorage
        markedTextRangeStorage = nil
        markedTextAttributedStringStorage = nil
        invalidateSyntaxRenderingAttributesForMarkedTextChange(from: previousMarkedRange, to: nil)
        updateSelectionRendering()
        needsDisplay = true
    }

    func selectedRange() -> NSRange { selectedRangeStorage }
    func markedRange() -> NSRange { markedTextRangeStorage ?? NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedTextRangeStorage != nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .underlineColor, .foregroundColor] }

    private func markedTextAttributedReplacement(from string: Any) -> NSAttributedString {
        guard let attributedString = string as? NSAttributedString else {
            return NSAttributedString(string: "\(string)", attributes: typingAttributes)
        }

        let replacement = NSMutableAttributedString(
            string: attributedString.string,
            attributes: typingAttributes
        )
        let validAttributes = Set(validAttributesForMarkedText())
        for location in 0..<attributedString.length {
            let range = NSRange(location: location, length: 1)
            let attributes = unsafe attributedString.attributes(at: location, effectiveRange: nil)
            for (key, value) in attributes where validAttributes.contains(key) {
                replacement.addAttribute(key, value: value, range: range)
            }
        }
        return replacement
    }

    func applyMarkedTextAttributes() {
        guard let markedRange = markedTextRangeStorage,
              let attributedString = markedTextAttributedStringStorage
        else {
            return
        }

        let targetRange = SyntaxEditorRangeUtilities.clampedRange(markedRange, utf16Length: storage.length)
        guard targetRange.length > 0 else { return }

        let length = min(targetRange.length, attributedString.length)
        guard length > 0 else { return }

        textContentStorage.performEditingTransaction {
            for offset in 0..<length {
                let sourceAttributes = unsafe attributedString.attributes(at: offset, effectiveRange: nil)
                let destinationRange = NSRange(location: targetRange.location + offset, length: 1)
                for key in validAttributesForMarkedText() {
                    if let value = sourceAttributes[key] {
                        storage.addAttribute(key, value: value, range: destinationRange)
                    }
                }
            }
        }
    }

    private func invalidateSyntaxRenderingAttributesForMarkedTextChange(
        from previousRange: NSRange?,
        to currentRange: NSRange?
    ) {
        didChangeMarkedTextRange?()
        let ranges = [previousRange, currentRange].compactMap { range -> NSRange? in
            guard let range,
                  range.location != NSNotFound,
                  range.length > 0 else {
                return nil
            }
            return range
        }
        invalidateSyntaxRenderingAttributes(for: ranges)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
        unsafe actualRange?.pointee = clamped
        guard clamped.length > 0 else { return NSAttributedString(string: "") }
        return storage.attributedSubstring(from: clamped)
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        unsafe outRange.pointee = NSRange(location: 0, length: storage.length)
        return textContentView
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        rectsForCharacterRange(range).map { NSValue(rect: $0) }
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard view === textContentView,
              let targetTextRange = textRange(forUTF16Range: range)
        else {
            return
        }
        textLayoutManager.ensureLayout(for: targetTextRange)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let drawsFindIndicator = view.isDrawingFindIndicator
        textLayoutManager.enumerateTextLayoutFragments(from: targetTextRange.location, options: []) { [self] fragment in
            guard !TextLayoutGeometry.ranges([range], intersecting: textRange(for: fragment)).isEmpty else {
                return true
            }
            if drawsFindIndicator {
                textLayoutManager.addRenderingAttribute(
                    .foregroundColor,
                    value: NSColor.black,
                    for: targetTextRange
                )
            }
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            if drawsFindIndicator {
                textLayoutManager.removeRenderingAttribute(.foregroundColor, for: targetTextRange)
            }
            return true
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        scrollToVisible(rectForCharacterRange(range).insetBy(dx: -4, dy: -4))
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        let affectedRanges = ranges.map(\.rangeValue)
        return shouldChangeText?(affectedRanges, strings) ?? true
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        let clampedRange = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
        replaceText(
            in: clampedRange,
            with: string,
            selectedRange: NSRange(location: clampedRange.location + string.utf16.count, length: 0)
        )
    }

    func didReplaceCharacters() {}

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
        unsafe actualRange?.pointee = clamped
        let localRect = rectForCharacterRange(clamped)
        guard let window = unsafe self.window else { return localRect }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        let windowPoint = unsafe window?.convertPoint(fromScreen: point) ?? point
        let localPoint = convert(windowPoint, from: nil)
        return characterIndex(at: localPoint)
    }

    func baselineDeltaForCharacter(at index: Int) -> CGFloat { 0 }
    func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat { 0 }
    func windowLevel() -> Int { unsafe window?.level.rawValue ?? 0 }
    func drawsVerticallyForCharacter(at charIndex: Int) -> Bool { false }

    @discardableResult
    func replaceText(in range: NSRange, with replacement: String, selectedRange: NSRange) -> Bool {
        replaceText(
            in: range,
            with: NSAttributedString(string: replacement, attributes: typingAttributes),
            selectedRange: selectedRange
        )
    }

    @discardableResult
    func replaceText(
        in range: NSRange,
        with attributedReplacement: NSAttributedString,
        selectedRange: NSRange
    ) -> Bool {
        let replacement = attributedReplacement.string
        guard shouldChangeText(inRanges: [range], replacementStrings: [replacement]) else { return false }
        let previousSource = storage.string
        textFinder.noteClientStringWillChange()
        textContentStorage.performEditingTransaction {
            storage.replaceCharacters(in: range, with: attributedReplacement)
        }
        lineMetrics.apply(
            edits: [SyntaxEditorTextChange.Replacement(range: range, replacement: replacement)],
            previousSource: previousSource
        )
        setSelectedRange(selectedRange)
        invalidateTextLayout()
        rebuildFindHighlightRangeIndex()
        updateFindHighlightsForVisibleFragments()
        didChangeTextNotification()
        return true
    }

    private func effectiveReplacementRange(_ range: NSRange) -> NSRange {
        if range.location == NSNotFound {
            return selectedRangeStorage
        }
        return SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: storage.length)
    }
}
#endif
