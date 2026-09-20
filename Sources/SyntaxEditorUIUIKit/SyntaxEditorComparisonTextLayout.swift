#if canImport(UIKit)
import UIKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorComparisonTextLayout {
    typealias Change = EditorComparisonEngine.Change
    enum Side { case original, modified }

    private weak var editor: SyntaxEditorView?
    let side: Side
    let rulerWidth: CGFloat = 58
    var rulerView: UIView { ruler }
    private lazy var ruler = ComparisonRuler(layout: self)
    private(set) var changes: [Change] = []
    private var inlineRangeIndexes: [TextRangeIntersectionIndex] = []
    private var presentation: SyntaxEditorComparisonModel.Presentation = .changeMarkers
    private var selectedChangeIndex: Int?
    private var lineOffsets: LineOffsetTable { editor!.lineMetrics.lineOffsets }

    init(editor: SyntaxEditorView, side: Side) {
        self.editor = editor
        self.side = side
        editor.comparisonLayout = self
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
        ruler.accessibilityValue = index.map { "Change \($0 + 1) of \(changes.count)" } ?? "\(changes.count) changes"
        layoutDidComplete()
        editor?.setNeedsDisplayForVisibleTextFragments()
    }

    func layoutDidComplete() {
        ruler.setNeedsDisplay()
    }

    /// The surface origin is in text-container coordinates; drawing bounds are local.
    func drawBackground(for fragment: NSTextLayoutFragment, surfaceOrigin: CGPoint, in bounds: CGRect, dirtyRect: CGRect) {
        guard let editor, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let start = editor.textSystem.utf16Range(for: fragment).location
        for line in fragment.textLineFragments {
            let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
            // A zero-length change marks a boundary, not text in this row.
            guard let index = changeIndex(at: range.location), sourceRange(changes[index]).length > 0 else { continue }
            if presentation != .changeMarkers || index == selectedChangeIndex {
                let color = index == selectedChangeIndex ? editor.tintColor ?? .systemBlue : changeColor(at: index)
                context.setFillColor(color.withAlphaComponent(index == selectedChangeIndex ? 0.16 : 0.09).cgColor)
                let rect = CGRect(x: 0, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY - surfaceOrigin.y, width: bounds.width, height: line.typographicBounds.height)
                if rect.intersects(dirtyRect) { context.fill(rect.intersection(dirtyRect)) }
            }
        }
        guard presentation != .changeMarkers else { return }
        let fragmentRange = editor.textSystem.utf16Range(for: fragment)
        for index in changeIndices(intersecting: fragmentRange) {
            for intersection in inlineRangeIndexes[index].ranges(intersecting: fragmentRange) {
                context.setFillColor(changeColor(at: index).withAlphaComponent(0.22).cgColor)
                for rect in TextLayoutGeometry.standardRects(
                    layoutManager: editor.layoutManager,
                    rangeConverter: editor.textSystem.rangeConverter,
                    ranges: [intersection],
                    offsetBy: surfaceOrigin
                ) where rect.intersects(dirtyRect) {
                    context.fill(rect.intersection(dirtyRect))
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

    private func changeColor(at index: Int) -> UIColor {
        if changes[index].originalRange.length == 0 { return .systemGreen }
        if presentation == .changeMarkers, changes[index].modifiedRange.length > 0 { return .systemOrange }
        return side == .original || changes[index].modifiedRange.length == 0 ? .systemRed : .systemGreen
    }

    private func visibleFragmentViews() -> [SyntaxEditorView.TextLayoutFragmentView] {
        guard let editor else { return [] }
        let origin = editor.textContentView.frame.origin
        return editor.textContentView.subviews.compactMap {
            $0 as? SyntaxEditorView.TextLayoutFragmentView
        }.filter {
            $0.frame.offsetBy(dx: origin.x, dy: origin.y).intersects(editor.adjustedVisibleContentRect)
        }.sorted { $0.layoutFragment.layoutFragmentFrame.minY < $1.layoutFragment.layoutFragmentFrame.minY }
    }

    private final class ComparisonRuler: UIView {
        weak var comparisonLayout: SyntaxEditorComparisonTextLayout?

        init(layout: SyntaxEditorComparisonTextLayout) {
            comparisonLayout = layout
            super.init(frame: .zero)
            clipsToBounds = true
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = layout.side == .original ? "Reference line numbers and changes" : "Modified line numbers and changes"
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ rect: CGRect) {
            comparisonLayout?.drawRuler(self, dirtyRect: rect)
        }
    }

    private func drawRuler(_ ruler: ComparisonRuler, dirtyRect: CGRect) {
        guard let editor, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: ruler.bounds)
        context.setFillColor((editor.backgroundColor ?? .clear).resolvedColor(with: editor.traitCollection).cgColor)
        context.fill(ruler.bounds)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func draw(_ number: Int, at point: CGPoint, change: Int?, deleted: Bool = false) {
            let y = ruler.convert(point, from: editor).y
            guard y + font.lineHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { return }
            let isDeletion = change.map {
                (deleted && changes[$0].originalRange.length > 0) || changes[$0].modifiedRange.length == 0
            } ?? false
            let color = (isDeletion ? UIColor.systemRed
                : change.map { changeColor(at: $0) } ?? .secondaryLabel).resolvedColor(with: editor.traitCollection)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let value = "\(number)" as NSString
            let size = value.size(withAttributes: attributes)
            value.draw(at: CGPoint(x: rulerWidth - size.width - 10, y: y), withAttributes: attributes)
            if let change {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: rulerWidth - 5, y: y, width: 3, height: font.lineHeight))
                if change == selectedChangeIndex {
                    context.setFillColor((editor.tintColor ?? .systemBlue).resolvedColor(with: editor.traitCollection).cgColor)
                    context.fill(CGRect(x: 0, y: y, width: 2, height: font.lineHeight))
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
                draw(number + 1, at: CGPoint(
                    x: editor.textContentView.frame.minX,
                    y: editor.textContentView.frame.minY + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
                ), change: changeIndex(at: offset), deleted: side == .original)
            }
        }
        for mark in editor.inlineComparisonLayout?.visibleLineMarks ?? [] {
            draw(mark.originalLine + 1, at: mark.origin, change: mark.changeIndex, deleted: true)
        }
    }
}
#endif
