#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorComparisonTextLayout {
    typealias Change = EditorComparisonEngine.Change
    enum Side { case original, modified }

    private weak var editor: SyntaxEditorView?
    weak var comparison: SyntaxEditorComparisonView?
    let side: Side
    private(set) var changes: [Change] = []
    private var inlineRangeIndexes: [TextRangeIntersectionIndex] = []
    private var presentation: SyntaxEditorComparisonModel.Presentation = .changeMarkers
    private var selectedChangeIndex: Int?
    private var ruler: ComparisonRuler?
    private var lineOffsets: LineOffsetTable { editor!.textView.lineMetrics.lineOffsets }

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
        self.changes = changes
        inlineRangeIndexes = changes.map { change in
            TextRangeIntersectionIndex(
                ranges: change.inlineChanges.map { side == .original ? $0.originalRange : $0.modifiedRange },
                utf16Length: sourceRange(change).upperBound
            )
        }
        self.presentation = presentation
        updateSelectedChange(selectedChangeIndex)
    }

    func updateSelectedChange(_ index: Int?) {
        selectedChangeIndex = index
        let value: String
        if let count = comparison?.model.changeCount {
            value = index.map { "Change \($0 + 1) of \(count)" } ?? "\(count) changes"
        } else {
            value = "Comparing documents"
        }
        ruler?.setAccessibilityValue(value)
        layoutDidComplete()
        editor?.textView.setNeedsDisplayForVisibleTextFragments()
    }

    func layoutDidComplete() {
        ruler?.needsDisplay = true
    }

    func drawBackground(for fragment: NSTextLayoutFragment, surfaceOrigin: CGPoint, in bounds: CGRect, dirtyRect: CGRect) {
        guard let editor else { return }
        let start = editor.textSystem.utf16Range(for: fragment).location
        for line in fragment.textLineFragments {
            let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
            // A zero-length change marks a boundary, not text in this row.
            guard let index = changeIndex(at: range.location), sourceRange(changes[index]).length > 0 else { continue }
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
            for intersection in inlineRangeIndexes[index].ranges(intersecting: fragmentRange) {
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
        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            // NSRulerView's default drawing fills its own background first.
            drawHashMarksAndLabels(in: dirtyRect)
            drawMarkers(in: dirtyRect)
        }

        override func drawHashMarksAndLabels(in rect: NSRect) {
            comparisonLayout?.drawRuler(self, dirtyRect: rect)
        }

        override func mouseDown(with event: NSEvent) {
            guard let layout = comparisonLayout, let editor = layout.editor else { return }
            let point = editor.textView.convert(event.locationInWindow, from: nil)
            let index = editor.textView.inlineComparisonLayout?.changeIndex(atY: point.y)
                ?? layout.changeIndex(at: editor.textView.characterIndex(at: point))
            if let index {
                _ = layout.comparison?.model.selectChange(at: index)
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    private func drawRuler(_ ruler: ComparisonRuler, dirtyRect: CGRect) {
        guard let editor else { return }
        if editor.drawsBackground {
            editor.backgroundColor.setFill()
            dirtyRect.fill()
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func draw(_ number: Int, at point: CGPoint, change: Int?, deleted: Bool = false) {
            let y = ruler.convert(point, from: editor.textView).y
            guard y + 20 >= dirtyRect.minY, y <= dirtyRect.maxY else { return }
            let isDeletion = change.map {
                (deleted && changes[$0].originalRange.length > 0) || changes[$0].modifiedRange.length == 0
            } ?? false
            let color = isDeletion ? NSColor.systemRed
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
        for mark in editor.textView.inlineComparisonLayout?.visibleLineMarks ?? [] {
            draw(mark.originalLine + 1, at: mark.origin, change: mark.changeIndex, deleted: true)
        }
    }
}
#endif
