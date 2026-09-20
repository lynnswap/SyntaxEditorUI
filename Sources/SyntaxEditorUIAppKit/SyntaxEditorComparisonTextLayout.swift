#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorComparisonTextLayout {
    typealias Change = EditorComparisonEngine.Change
    typealias Side = EditorComparisonGeometry.Side

    weak var comparison: SyntaxEditorComparisonView?
    private weak var editor: SyntaxEditorView?
    let side: Side
    private(set) var changes: [Change] = []
    private var presentation: SyntaxEditorComparisonModel.Presentation = .changeMarkers
    private var selectedChangeIndex: Int?
    private var blocks: [Int: DeletedBlock] = [:]
    private var topBlocks: [Int: [DeletedBlock]] = [:]
    private var footerBlocks: [DeletedBlock] = []
    private let marginFragments = NSHashTable<SyntaxEditorTextInputView.TextLayoutFragment>.weakObjects()
    private var isLayingOut = false
    private var settingsWidth: CGFloat = -1
    private var settingsFont: NSFont?
    private var settingsWrapping = false
    private var referenceStyleGeneration = -1
    private var ruler: ComparisonRuler?

    var lineOffsets: LineOffsetTable { editor!.textView.lineMetrics.lineOffsets }
    var additionalHeight: CGFloat { blocks.values.reduce(0) { $0 + $1.height } }
    private(set) var minimumTextWidth: CGFloat = 0
    var deletedViews: [Int: SyntaxEditorComparisonDeletedTextView] {
        blocks.compactMapValues(\.view)
    }

    init(editor: SyntaxEditorView, side: Side) {
        self.editor = editor
        self.side = side
        editor.textView.comparisonLayout = self
        let ruler = ComparisonRuler(editor: editor, layout: self)
        self.ruler = ruler
        editor.hasVerticalRuler = true
        editor.verticalRulerView = ruler
        editor.rulersVisible = true
    }

    func update(changes: [Change], presentation: SyntaxEditorComparisonModel.Presentation, selectedChangeIndex: Int?) {
        guard let editor else { return }
        let anchor = captureScrollAnchor()
        for block in blocks.values { block.view?.removeFromSuperview() }
        blocks.removeAll()
        self.changes = changes
        self.presentation = presentation
        self.selectedChangeIndex = selectedChangeIndex
        if side == .modified, presentation == .inline, let comparison {
            let source = comparison.model.originalText as NSString
            for (index, change) in changes.enumerated() where change.originalRange.length > 0 {
                let text = source.substring(with: change.originalRange)
                blocks[index] = DeletedBlock(
                    index: index,
                    range: change.originalRange,
                    firstLine: change.originalLines.lowerBound,
                    anchor: change.modifiedRange.location,
                    isFooter: change.modifiedRange.location == editor.textStorage.length,
                    text: text
                )
            }
        }
        settingsWidth = -1
        referenceStyleGeneration = -1
        refreshTextSettings()
        layoutDidComplete()
        restoreScrollAnchor(anchor)
        updateSelectedChange(selectedChangeIndex)
    }

    func updateSelectedChange(_ index: Int?) {
        selectedChangeIndex = index
        let value = index.map { "Change \($0 + 1) of \(changes.count)" } ?? "\(changes.count) changes"
        ruler?.setAccessibilityValue(value)
        ruler?.needsDisplay = true
        editor?.textView.setNeedsDisplayForVisibleTextFragments()
        for (blockIndex, block) in blocks {
            block.view?.layer?.borderWidth = blockIndex == index ? 1 : 0
            block.view?.layer?.borderColor = NSColor.selectedControlColor.cgColor
        }
    }

    func refreshTextSettings() {
        guard let editor else { return }
        let wraps = editor.model.lineWrappingEnabled
        let containerWidth = wraps ? editor.textContainer.size.width : editor.contentSize.width
        let width = max(1, containerWidth - editor.textContainer.lineFragmentPadding * 2)
        let font = editor.resolvedBaseFont()
        let geometryChanged = settingsWidth != width || settingsFont != font || settingsWrapping != wraps
        if geometryChanged {
            settingsWidth = width
            settingsFont = font
            settingsWrapping = wraps
            let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
            for block in blocks.values {
                block.estimatedSize = block.metrics.estimatedDocumentSize(
                    minimumSize: NSSize(width: width, height: 0),
                    lineWrappingEnabled: wraps,
                    lineHeight: lineHeight,
                    columnWidth: max(1, font.pointSize * 0.65),
                    lineFragmentPadding: 0
                )
                block.size = block.estimatedSize
            }
        }
        var stylesChanged = false
        if let comparison {
            let generation = comparison.originalEditor.textSystem.styleStore.generation
            if geometryChanged || generation != referenceStyleGeneration {
                stylesChanged = true
                referenceStyleGeneration = generation
                for block in blocks.values {
                    block.view?.install(attributedDeletedText(for: block, comparison: comparison))
                }
            }
        }
        minimumTextWidth = wraps ? 0 : (blocks.values.map(\.size.width).max() ?? 0) + editor.textContainer.lineFragmentPadding * 2
        if geometryChanged {
            rebuildMargins()
            editor.textView.invalidateTextLayout()
        } else if stylesChanged {
            editor.textView.needsLayout = true
        }
        ruler?.needsDisplay = true
    }

    func configureMargins(for fragment: SyntaxEditorTextInputView.TextLayoutFragment) {
        guard let editor else { return }
        let range = editor.textSystem.utf16Range(for: fragment)
        fragment.comparisonTopMargin = topBlocks[range.location, default: []].reduce(0) { $0 + $1.height }
        fragment.comparisonBottomMargin = range.upperBound == editor.textStorage.length
            ? footerBlocks.reduce(0) { $0 + $1.height } : 0
        if fragment.comparisonTopMargin > 0 || fragment.comparisonBottomMargin > 0 {
            marginFragments.add(fragment)
        }
    }

    private func rebuildMargins() {
        guard let editor else { return }
        for fragment in marginFragments.allObjects {
            fragment.comparisonTopMargin = 0
            fragment.comparisonBottomMargin = 0
            fragment.invalidateLayout()
        }
        marginFragments.removeAllObjects()
        topBlocks = Dictionary(grouping: blocks.values.filter { !$0.isFooter }, by: \.anchor)
        footerBlocks = blocks.values.filter(\.isFooter).sorted { $0.index < $1.index }
        for block in blocks.values {
            let offset = block.isFooter ? max(0, editor.textStorage.length - 1) : block.anchor
            guard let location = editor.textSystem.textLocation(forUTF16Offset: offset),
                  let fragment = editor.layoutManager.textLayoutFragment(for: location)
                    as? SyntaxEditorTextInputView.TextLayoutFragment else { continue }
            configureMargins(for: fragment)
            fragment.invalidateLayout()
        }
        editor.layoutManager.invalidateLayout(for: editor.textSystem.textContentStorage.documentRange)
    }

    func layoutDidComplete() {
        guard let editor, !isLayingOut,
              editor.contentView.bounds.width > 0, editor.contentView.bounds.height > 0 else { return }
        guard !blocks.isEmpty else {
            ruler?.needsDisplay = true
            return
        }
        isLayingOut = true
        defer { isLayingOut = false }
        refreshTextSettings()
        let anchor = captureScrollAnchor()
        let viewport = editor.textView.convert(editor.contentView.bounds, from: editor.contentView).insetBy(dx: 0, dy: -100)
        var visible: Set<Int> = []
        var changedSize = false
        if editor.textStorage.length == 0,
           let caret = frame(forUTF16Range: NSRange(location: 0, length: 0)) {
            // The empty-document fragment has no comparison margins, so it need
            // not intersect a viewport scrolled into its deleted reference.
            var y = caret.maxY
            for block in footerBlocks {
                changedSize = place(block, at: y, viewport: viewport, visible: &visible) || changedSize
                y += block.height
            }
        }
        for fragmentView in visibleFragmentViews() where editor.textStorage.length > 0 {
            let fragment = fragmentView.layoutFragment
            let range = editor.textSystem.utf16Range(for: fragment)
            let frame = fragment.layoutFragmentFrame
            var y = frame.minY
            for block in topBlocks[range.location, default: []].sorted(by: { $0.index < $1.index }) {
                changedSize = place(block, at: y, viewport: viewport, visible: &visible) || changedSize
                y += block.height
            }
            if range.upperBound == editor.textStorage.length {
                y = frame.maxY - footerBlocks.reduce(0) { $0 + $1.height }
                for block in footerBlocks {
                    changedSize = place(block, at: y, viewport: viewport, visible: &visible) || changedSize
                    y += block.height
                }
            }
        }
        for block in blocks.values where !visible.contains(block.index) {
            guard let view = block.view else { continue }
            if unsafe view.window?.firstResponder !== view {
                view.removeFromSuperview()
                block.view = nil
            }
        }
        if changedSize {
            minimumTextWidth = settingsWrapping ? 0 : (blocks.values.map(\.size.width).max() ?? 0) + editor.textContainer.lineFragmentPadding * 2
            rebuildMargins()
            editor.textView.invalidateTextLayout()
            restoreScrollAnchor(anchor)
            editor.textView.needsLayout = true
        }
        ruler?.needsDisplay = true
    }

    private func place(_ block: DeletedBlock, at y: CGFloat, viewport: CGRect, visible: inout Set<Int>) -> Bool {
        guard let editor, let comparison else { return false }
        let frame = CGRect(x: 0, y: y, width: max(editor.textView.bounds.width, block.size.width + editor.textContainer.lineFragmentPadding * 2), height: block.height)
        block.frame = frame
        guard frame.intersects(viewport) else { return false }
        visible.insert(block.index)
        let view: SyntaxEditorComparisonDeletedTextView
        if let existing = block.view {
            view = existing
        } else {
            view = SyntaxEditorComparisonDeletedTextView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
            view.setAccessibilityLabel("Deleted reference text, line \(block.firstLine + 1)")
            view.install(attributedDeletedText(for: block, comparison: comparison))
            let originalOffset = block.range.location
            view.onSelectionChange = { [weak comparison] localRange in
                comparison?.model.original.selectedRange = NSRange(
                    location: originalOffset + localRange.location,
                    length: localRange.length
                )
            }
            view.onFind = { [weak comparison] sender in comparison?.findInOriginal(sender) }
            editor.textView.textContentView.addSubview(view)
            block.view = view
        }
        view.frame = frame.insetBy(dx: editor.textContainer.lineFragmentPadding, dy: 4)
        let measured = view.measure(
            width: settingsWidth,
            lineWrappingEnabled: settingsWrapping,
            estimatedSize: block.estimatedSize
        )
        let changed = abs(block.size.height - measured.height) > 0.5
            || abs(block.size.width - measured.width) > 0.5
        block.size = measured
        block.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: block.height)
        view.frame.origin = CGPoint(x: editor.textContainer.lineFragmentPadding, y: y + 4)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
        }
        view.layer?.borderWidth = block.index == selectedChangeIndex ? 1 : 0
        view.layer?.borderColor = NSColor.selectedControlColor.cgColor
        return changed
    }

    private func attributedDeletedText(
        for block: DeletedBlock,
        comparison: SyntaxEditorComparisonView
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: comparison.referenceAttributedString(in: block.range))
        let availableRange = NSRange(location: block.range.location, length: text.length)
        for inline in changes[block.index].inlineChanges {
            let range = NSIntersectionRange(inline.originalRange, availableRange)
            guard range.length > 0 else { continue }
            text.addAttribute(
                .backgroundColor,
                value: NSColor.systemRed.withAlphaComponent(0.22),
                range: NSRange(location: range.location - block.range.location, length: range.length)
            )
        }
        return text
    }

    func drawBackground(for fragment: NSTextLayoutFragment, surfaceOrigin: CGPoint, in bounds: CGRect, dirtyRect: CGRect) {
        guard let editor else { return }
        let start = editor.textSystem.utf16Range(for: fragment).location
        for line in fragment.textLineFragments {
            let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
            guard let index = changeIndex(at: range.location) else { continue }
            if presentation != .changeMarkers || index == selectedChangeIndex {
                let color = index == selectedChangeIndex ? NSColor.selectedControlColor : changeColor(at: index)
                color.withAlphaComponent(index == selectedChangeIndex ? 0.16 : 0.09).setFill()
                let rect = CGRect(x: 0, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY - surfaceOrigin.y, width: bounds.width, height: line.typographicBounds.height)
                if rect.intersects(dirtyRect) { rect.fill() }
            }
        }
        guard presentation != .changeMarkers else { return }
        let fragmentRange = editor.textSystem.utf16Range(for: fragment)
        for index in changeIndices(intersecting: fragmentRange) {
            for inline in changes[index].inlineChanges {
                let range = side == .original ? inline.originalRange : inline.modifiedRange
                let intersection = NSIntersectionRange(range, fragmentRange)
                guard intersection.length > 0 else { continue }
                changeColor(at: index).withAlphaComponent(0.22).setFill()
                for rect in TextLayoutGeometry.standardRects(
                    layoutManager: editor.layoutManager,
                    rangeConverter: editor.textSystem.rangeConverter,
                    ranges: [intersection],
                    offsetBy: surfaceOrigin
                ) {
                    if rect.intersects(dirtyRect) { rect.fill() }
                }
            }
        }
    }

    func frame(forUTF16Range range: NSRange) -> CGRect? {
        guard let editor else { return nil }
        let range = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: editor.textStorage.length)
        if range.length == 0 {
            return editor.textView.rectsForCharacterRange(range).first
        }
        guard let first = editor.textView.rectsForCharacterRange(NSRange(location: range.location, length: 1)).first,
              let last = editor.textView.rectsForCharacterRange(NSRange(location: range.upperBound - 1, length: 1)).last
        else { return nil }
        return first.union(last)
    }

    func lineFrame(_ index: Int) -> CGRect? {
        guard editor != nil else { return nil }
        let line = min(max(0, index), lineOffsets.lineCount - 1)
        let start = lineOffsets.lineStartOffset(at: line)
        let end = lineOffsets.lineEndOffset(at: line)
        return frame(forUTF16Range: NSRange(location: start, length: end - start))
    }

    func logicalPosition(atY y: CGFloat) -> CGFloat? {
        guard let editor else { return nil }
        let offset = editor.textView.characterIndex(at: CGPoint(x: 0, y: y))
        let line = lineOffsets.lineIndex(containingUTF16Offset: offset)
        guard let frame = lineFrame(line) else { return nil }
        return CGFloat(line) + min(1, max(0, (y - frame.minY) / max(1, frame.height)))
    }

    func revealChange(at index: Int) {
        guard let editor, changes.indices.contains(index) else { return }
        let range = sourceRange(changes[index])
        let offset = min(range.location, max(0, editor.textStorage.length - 1))
        if let location = editor.textSystem.textLocation(forUTF16Offset: offset) {
            let y = editor.layoutManager.textViewportLayoutController.relocateViewport(to: location)
            scroll(to: y)
            editor.textView.layoutVisibleViewport()
        }
        if let block = blocks[index], let rect = block.frame {
            editor.textView.scrollToVisible(CGRect(x: rect.minX, y: rect.minY, width: 1, height: min(rect.height, 80)))
        } else if let rect = frame(forUTF16Range: range) {
            editor.textView.scrollToVisible(CGRect(x: rect.minX, y: rect.minY, width: 1, height: min(rect.height, 80)))
        }
    }

    private func sourceRange(_ change: Change) -> NSRange {
        side == .original ? change.originalRange : change.modifiedRange
    }

    private func changeIndex(at offset: Int) -> Int? {
        var lower = 0
        var upper = changes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sourceRange(changes[middle]).location <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let index = lower - 1
        let range = sourceRange(changes[index])
        return offset < range.upperBound || (range.length == 0 && offset == range.location) ? index : nil
    }

    private func changeIndices(intersecting range: NSRange) -> Range<Int> {
        var lower = 0
        var upper = changes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sourceRange(changes[middle]).upperBound < range.location { lower = middle + 1 } else { upper = middle }
        }
        let start = lower
        while lower < changes.count && sourceRange(changes[lower]).location <= range.upperBound { lower += 1 }
        return start..<lower
    }

    private func changeColor(at index: Int) -> NSColor {
        if changes[index].originalRange.length == 0 { return .systemGreen }
        if presentation == .changeMarkers, changes[index].modifiedRange.length > 0 { return .systemOrange }
        return side == .original || changes[index].modifiedRange.length == 0 ? .systemRed : .systemGreen
    }

    private func visibleFragmentViews() -> [SyntaxEditorTextInputView.TextLayoutFragmentView] {
        guard let editor else { return [] }
        return editor.textView.textContentView.subviews.compactMap {
            $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView
        }.filter { $0.layoutFragment.layoutFragmentFrame.intersects(editor.textView.currentViewportBounds) }
            .sorted { $0.layoutFragment.layoutFragmentFrame.minY < $1.layoutFragment.layoutFragmentFrame.minY }
    }

    private enum ScrollAnchor {
        case top
        case document(Int, CGFloat)
        case deleted(Int, Int, CGFloat)
        case bottom
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard let editor, editor.contentView.bounds.width > 0, editor.contentView.bounds.height > 0 else { return nil }
        let visible = editor.textView.visibleViewportBounds
        if visible.minY <= 0 { return .top }
        if abs(visible.maxY - editor.textView.bounds.maxY) < 1 { return .bottom }
        for block in blocks.values {
            guard let frame = block.frame, let view = block.view,
                  visible.minY >= frame.minY, visible.minY < frame.maxY else { continue }
            let point = view.convert(CGPoint(x: visible.minX + 1, y: visible.minY), from: editor.textView)
            let offset = view.characterIndexForInsertion(at: point)
            if let rect = auxiliaryCaretFrame(view, offset: offset) {
                return .deleted(block.index, offset, point.y - rect.minY)
            }
        }
        let offset = editor.textView.characterIndex(at: CGPoint(x: visible.minX + 1, y: visible.minY))
        guard let frame = frame(forUTF16Range: NSRange(location: offset, length: 0)) else { return nil }
        return .document(offset, visible.minY - frame.minY)
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let editor, let anchor else { return }
        switch anchor {
        case .top:
            scroll(to: -max(0, editor.contentView.contentInsets.top))
        case .bottom:
            scroll(to: max(0, editor.textView.bounds.height - editor.contentView.bounds.height))
        case let .document(offset, delta):
            if let frame = frame(forUTF16Range: NSRange(location: min(offset, editor.textStorage.length), length: 0)) {
                scroll(to: frame.minY + delta)
            }
        case let .deleted(index, offset, delta):
            if let block = blocks[index], let view = block.view,
               let frame = block.frame, let local = view.reveal(NSRange(location: offset, length: 0)) {
                scroll(to: frame.minY + 4 + local.minY + delta)
            }
        }
    }

    private func scroll(to y: CGFloat) {
        guard let editor else { return }
        var proposed = editor.contentView.bounds
        proposed.origin.y = y
        editor.contentView.scroll(to: editor.contentView.constrainBoundsRect(proposed).origin)
        editor.reflectScrolledClipView(editor.contentView)
    }

    private func auxiliaryCaretFrame(_ view: NSTextView, offset: Int) -> CGRect? {
        guard let manager = view.textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset)
        else { return nil }
        var result: CGRect?
        manager.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
            result = rect
            return false
        }
        return result
    }

    private final class DeletedBlock {
        let index: Int
        let range: NSRange
        let firstLine: Int
        let anchor: Int
        let isFooter: Bool
        let metrics: DocumentLineMetrics
        var estimatedSize = NSSize.zero
        var size = NSSize.zero
        var height: CGFloat { max(1, size.height) + 8 }
        var frame: CGRect?
        var view: SyntaxEditorComparisonDeletedTextView?

        init(index: Int, range: NSRange, firstLine: Int, anchor: Int, isFooter: Bool, text: String) {
            self.index = index
            self.range = range
            self.firstLine = firstLine
            self.anchor = anchor
            self.isFooter = isFooter
            self.metrics = DocumentLineMetrics(source: text, tabWidth: 4)
        }
    }

    private final class ComparisonRuler: NSRulerView {
        weak var comparisonLayout: SyntaxEditorComparisonTextLayout?

        init(editor: SyntaxEditorView, layout: SyntaxEditorComparisonTextLayout) {
            comparisonLayout = layout
            super.init(scrollView: editor, orientation: .verticalRuler)
            ruleThickness = 58
            clipsToBounds = true
            clientView = editor.textView
            setAccessibilityLabel(layout.side == .original ? "Reference line numbers and changes" : "Modified line numbers and changes")
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Next change") { [weak layout] in
                    layout?.comparison?.model.selectNextChange() ?? false
                },
                NSAccessibilityCustomAction(name: "Previous change") { [weak layout] in
                    layout?.comparison?.model.selectPreviousChange() ?? false
                },
            ])
        }

        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }

        override func drawHashMarksAndLabels(in rect: NSRect) {
            comparisonLayout?.drawRuler(self, dirtyRect: rect)
        }

        override func mouseDown(with event: NSEvent) {
            guard let layout = comparisonLayout, let editor = layout.editor else { return }
            let point = editor.textView.convert(event.locationInWindow, from: nil)
            if let block = layout.blocks.values.first(where: { $0.frame.map { point.y >= $0.minY && point.y < $0.maxY } ?? false }) {
                _ = layout.comparison?.model.selectChange(at: block.index)
            } else if let index = layout.changeIndex(at: editor.textView.characterIndex(at: point)) {
                _ = layout.comparison?.model.selectChange(at: index)
            }
        }
    }

    private func drawRuler(_ ruler: ComparisonRuler, dirtyRect: CGRect) {
        guard let editor else { return }
        editor.backgroundColor.setFill()
        dirtyRect.fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func draw(_ number: Int, at point: CGPoint, change: Int?, deleted: Bool = false) {
            let y = ruler.convert(point, from: editor.textView).y
            guard y + 20 >= dirtyRect.minY, y <= dirtyRect.maxY else { return }
            let color = deleted && change != nil ? NSColor.systemRed
                : change.map { changeColor(at: $0) } ?? NSColor.secondaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let value = "\(number)" as NSString
            let size = value.size(withAttributes: attributes)
            value.draw(at: CGPoint(x: ruler.ruleThickness - size.width - 10, y: y), withAttributes: attributes)
            if let change {
                color.setFill()
                CGRect(x: ruler.ruleThickness - 5, y: y, width: 3, height: 14).fill()
                if change == selectedChangeIndex {
                    NSColor.selectedControlColor.setFill()
                    CGRect(x: 0, y: y, width: 2, height: 14).fill()
                }
                let isDeletion = deleted && changes[change].originalRange.length > 0
                    || changes[change].modifiedRange.length == 0
                let isModification = presentation == .changeMarkers
                    && changes[change].originalRange.length > 0 && changes[change].modifiedRange.length > 0
                let symbol = (isModification ? "~" : isDeletion ? "−" : "+") as NSString
                symbol.draw(at: CGPoint(x: 4, y: y), withAttributes: attributes)
            }
        }
        var seen: Set<Int> = []
        for view in visibleFragmentViews() {
            let fragment = view.layoutFragment
            let start = editor.textSystem.utf16Range(for: fragment).location
            for line in fragment.textLineFragments {
                let offset = start + line.characterRange.location
                let number = lineOffsets.lineIndex(containingUTF16Offset: offset)
                guard seen.insert(number).inserted else { continue }
                draw(number + 1,
                     at: CGPoint(x: 0, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY),
                     change: changeIndex(at: offset),
                     deleted: side == .original)
            }
        }
        for block in blocks.values {
            guard let view = block.view, let manager = view.textLayoutManager,
                  let content = manager.textContentManager,
                  let viewportRange = manager.textViewportLayoutController.viewportRange else { continue }
            var seen: Set<Int> = []
            manager.enumerateTextLayoutFragments(from: viewportRange.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedAscending else { return false }
                let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    let offset = start + line.characterRange.location
                    let number = block.metrics.lineOffsets.lineIndex(containingUTF16Offset: offset)
                    guard seen.insert(number).inserted else { continue }
                    let point = editor.textView.convert(
                        CGPoint(x: 0, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY),
                        from: view
                    )
                    draw(block.firstLine + number + 1, at: point, change: block.index, deleted: true)
                }
                return true
            }
        }
    }
}
#endif
