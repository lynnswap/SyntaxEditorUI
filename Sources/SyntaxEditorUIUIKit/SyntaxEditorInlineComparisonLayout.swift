#if canImport(UIKit)
import UIKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorInlineComparisonLayout {
    struct LineMark {
        /// The zero-based line in the complete reference document.
        let originalLine: Int
        let changeIndex: Int
        /// The line origin in modified text-input-view coordinates.
        let origin: CGPoint
    }

    private struct Settings: Equatable {
        let width: CGFloat
        let font: UIFont
        let wraps: Bool
    }

    private weak var editor: SyntaxEditorView?
    private weak var originalEditor: SyntaxEditorView?
    private var blocks: [Block] = []
    private var topBlocks: [Int: [Block]] = [:]
    private var footerBlocks: [Block] = []
    private var settings: Settings?
    private var needsMarginUpdate = false
    private var selectedChangeIndex: Int?
    var onFind: ((Selector, Any?) -> Void)?

    var deletedViews: [Int: SyntaxEditorComparisonDeletedTextView] {
        Dictionary(uniqueKeysWithValues: blocks.compactMap { block in
            block.view.map { (block.index, $0) }
        })
    }

    init(editor: SyntaxEditorView, originalEditor: SyntaxEditorView) {
        self.editor = editor
        self.originalEditor = originalEditor
    }

    func update(changes: [EditorComparisonEngine.Change]) {
        let hadBlocks = !blocks.isEmpty
        for block in blocks {
            if let view = block.view { detach(view) }
        }
        blocks.removeAll()
        topBlocks.removeAll()
        footerBlocks.removeAll()
        settings = nil
        guard let editor, let originalEditor else {
            needsMarginUpdate = hadBlocks
            return
        }

        let source = originalEditor.model.text as NSString
        let modifiedLength = editor.model.text.utf16.count
        for (index, change) in changes.enumerated() where change.originalRange.length > 0 {
            blocks.append(Block(
                index: index,
                change: change,
                isFooter: change.modifiedRange.location == modifiedLength,
                text: source.substring(with: change.originalRange)
            ))
        }
        topBlocks = Dictionary(grouping: blocks.filter { !$0.isFooter }, by: { $0.change.modifiedRange.location })
        footerBlocks = blocks.filter(\.isFooter)
        needsMarginUpdate = hadBlocks || !blocks.isEmpty
    }

    func updateSelectedChange(_ index: Int?) {
        selectedChangeIndex = index
        for block in blocks { block.view?.isChangeSelected = block.index == index }
    }

    func containsDeletedText(at point: CGPoint) -> Bool {
        blocks.contains { $0.view?.frame.contains(point) == true }
    }

    func updateReferenceSelection(_ originalRange: NSRange) {
        for block in blocks {
            block.view?.setSelection(originalRange)
        }
    }

    @discardableResult
    func invalidateReferenceStyles(in ranges: [NSRange]) -> Bool {
        var affectedVisibleBlock = false
        for block in blocks where block.view != nil {
            if ranges.contains(where: { NSIntersectionRange($0, block.change.originalRange).length > 0 }) {
                block.needsStyleUpdate = true
                affectedVisibleBlock = true
            }
        }
        return affectedVisibleBlock
    }

    @discardableResult
    func prepareForLayout() -> Bool {
        guard let editor else { return false }
        let wraps = editor.lastAppliedLineWrappingEnabled
        let containerWidth = wraps ? editor.container.size.width
            : editor.adjustedVisibleContentSize.width - editor.textContainerInset.left - editor.textContainerInset.right
        let next = Settings(
            width: max(1, containerWidth - editor.container.lineFragmentPadding * 2),
            font: editor.font,
            wraps: wraps
        )
        let geometryChanged = settings != next
        settings = next
        if geometryChanged {
            let lineHeight = max(1, ceil(next.font.lineHeight))
            for block in blocks {
                block.estimatedSize = block.metrics.estimatedDocumentSize(
                    minimumSize: CGSize(width: next.width, height: 0),
                    lineWrappingEnabled: next.wraps,
                    lineHeight: lineHeight,
                    columnWidth: max(1, next.font.pointSize * 0.65),
                    lineFragmentPadding: 0
                )
                block.size = block.estimatedSize
            }
        }
        for block in blocks where block.needsStyleUpdate {
            if let view = block.view, let attributed = attributedText(for: block) {
                view.install(attributed, originalLocation: block.change.originalRange.location)
            }
            block.needsStyleUpdate = false
        }
        let changed = needsMarginUpdate || (geometryChanged && !blocks.isEmpty)
        needsMarginUpdate = false
        return changed
    }

    func margins(for paragraphRange: NSRange) -> (top: CGFloat, bottom: CGFloat) {
        guard let editor, editor.storage.length > 0 else { return (0, 0) }
        let top = topBlocks[paragraphRange.location, default: []].reduce(0) { $0 + $1.height }
        let ownsLastCharacter = NSLocationInRange(editor.storage.length - 1, paragraphRange)
        return (top, ownsLastCharacter ? footerBlocks.reduce(0) { $0 + $1.height } : 0)
    }

    var marginAnchorOffsets: [Int] {
        guard let editor, editor.storage.length > 0 else { return [] }
        var offsets = Set(topBlocks.keys)
        if !footerBlocks.isEmpty { offsets.insert(editor.storage.length - 1) }
        return offsets.sorted()
    }

    var focusedAnchorOffsets: [Int] {
        guard let editor, editor.storage.length > 0 else { return [] }
        return blocks.filter { hasFocus($0) }.map {
            $0.isFooter ? editor.storage.length - 1 : $0.change.modifiedRange.location
        }
    }

    var additionalHeight: CGFloat { blocks.reduce(0) { $0 + $1.height } }

    var minimumTextWidth: CGFloat {
        guard let editor, settings?.wraps == false, !blocks.isEmpty else { return 0 }
        return (blocks.map(\.size.width).max() ?? 0) + editor.container.lineFragmentPadding * 2
    }

    @discardableResult
    func layoutDeletedViews(
        in fragments: [NSTextLayoutFragment],
        viewport: CGRect,
        emptyDocumentCaretFrame: CGRect?
    ) -> Bool {
        guard let editor, settings != nil, viewport.width > 0, viewport.height > 0 else { return false }
        var visible: Set<Int> = []
        var changedSize = false
        if editor.storage.length == 0 {
            if let caret = emptyDocumentCaretFrame {
                var y = caret.maxY
                for block in footerBlocks {
                    changedSize = place(block, at: y, viewport: viewport, visible: &visible) || changedSize
                    y += block.height
                }
            }
        } else {
            let lastCharacter = editor.storage.length - 1
            for fragment in fragments {
                let range = editor.textSystem.utf16Range(for: fragment)
                var y = editor.textContentView.frame.minY + fragment.layoutFragmentFrame.minY
                for block in topBlocks[range.location, default: []] {
                    changedSize = place(block, at: y, viewport: viewport, visible: &visible) || changedSize
                    y += block.height
                }
                if NSLocationInRange(lastCharacter, range) {
                    y = editor.textContentView.frame.minY + fragment.layoutFragmentFrame.maxY - footerBlocks.reduce(0) { $0 + $1.height }
                    for block in footerBlocks {
                        changedSize = place(block, at: y, viewport: viewport, visible: &visible) || changedSize
                        y += block.height
                    }
                }
            }
        }
        for block in blocks where !visible.contains(block.index) {
            guard let view = block.view, !hasFocus(block) else { continue }
            detach(view)
            block.view = nil
        }
        return changedSize
    }

    var visibleLineMarks: [LineMark] {
        guard let editor else { return [] }
        var marks: [LineMark] = []
        for block in blocks {
            guard let view = block.view, let manager = view.textLayoutManager,
                  let content = manager.textContentManager,
                  let viewportRange = manager.textViewportLayoutController.viewportRange else { continue }
            var seen: Set<Int> = []
            manager.enumerateTextLayoutFragments(from: viewportRange.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedAscending else { return false }
                let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    let number = block.metrics.lineOffsets.lineIndex(containingUTF16Offset: start + line.characterRange.location)
                    guard seen.insert(number).inserted else { continue }
                    let point = editor.convert(
                        CGPoint(x: 0, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY),
                        from: view
                    )
                    marks.append(LineMark(originalLine: block.change.originalLines.lowerBound + number,
                                          changeIndex: block.index, origin: point))
                }
                return true
            }
        }
        return marks.sorted { $0.origin.y < $1.origin.y }
    }

    private func place(_ block: Block, at y: CGFloat, viewport: CGRect, visible: inout Set<Int>) -> Bool {
        guard let editor, let originalEditor, let settings else { return false }
        let padding = editor.container.lineFragmentPadding
        let frame = CGRect(x: editor.textContentView.frame.minX, y: y,
                           width: (settings.wraps ? settings.width : max(settings.width, block.size.width)) + padding * 2, height: block.height)
        guard frame.intersects(viewport) || hasFocus(block) else { return false }
        visible.insert(block.index)
        let view: SyntaxEditorComparisonDeletedTextView
        if let existing = block.view {
            view = existing
        } else {
            guard let attributed = attributedText(for: block) else { return false }
            view = SyntaxEditorComparisonDeletedTextView()
            view.accessibilityLabel = "Deleted reference text, line \(block.change.originalLines.lowerBound + 1)"
            view.install(attributed, originalLocation: block.change.originalRange.location)
            view.setSelection(originalEditor.model.selectedRange)
            view.onSelectionChange = { [weak originalEditor] range in originalEditor?.model.selectedRange = range }
            view.onFind = { [weak self] action, sender in self?.onFind?(action, sender) }
            view.onScroll = { [weak self, weak block] offset in
                guard let self, let block else { return }
                self.deletedViewDidScroll(block, to: offset)
            }
            editor.addSubview(view)
            block.view = view
        }
        let measured = view.updateLayout(blockFrame: frame.insetBy(dx: padding, dy: 4),
                                         viewport: viewport, lineWrappingEnabled: settings.wraps)
        block.appliedNativeOffset = view.contentOffset
        let changed = abs(block.size.height - measured.height) > 0.5 || abs(block.size.width - measured.width) > 0.5
        block.size = measured
        view.isChangeSelected = block.index == selectedChangeIndex
        return changed
    }

    private func deletedViewDidScroll(_ block: Block, to offset: CGPoint) {
        guard let editor else { return }
        let delta = CGPoint(x: offset.x - block.appliedNativeOffset.x, y: offset.y - block.appliedNativeOffset.y)
        block.appliedNativeOffset = offset
        let insets = editor.adjustedContentInset
        let x = min(max(-insets.left, editor.contentOffset.x + delta.x),
                    max(-insets.left, editor.contentSize.width - editor.bounds.width + insets.right))
        let y = min(max(-insets.top, editor.contentOffset.y + delta.y),
                    max(-insets.top, editor.contentSize.height - editor.bounds.height + insets.bottom))
        editor.setContentOffset(CGPoint(x: x, y: y), animated: false)
        editor.setNeedsTextLayout()
    }

    private func attributedText(for block: Block) -> NSAttributedString? {
        guard let originalEditor else { return nil }
        var base = originalEditor.typingAttributes
        base[.paragraphStyle] = originalEditor.baseParagraphStyle()
        base[.font] = originalEditor.font
        if let foreground = originalEditor.textSystem.styleStore.baseForeground { base[.foregroundColor] = foreground }
        let result = NSMutableAttributedString(string: block.text, attributes: base)
        let range = block.change.originalRange
        let runs = originalEditor.textSystem.styleStore.resolveVisibleRuns(in: range)
        for run in runs.colorRuns {
            let clipped = NSIntersectionRange(run.range, range)
            guard clipped.length > 0 else { continue }
            result.addAttribute(.foregroundColor, value: run.color,
                                range: NSRange(location: clipped.location - range.location, length: clipped.length))
        }
        for run in runs.fontRuns {
            let clipped = NSIntersectionRange(run.range, range)
            guard clipped.length > 0 else { continue }
            result.addAttribute(.font, value: run.font,
                                range: NSRange(location: clipped.location - range.location, length: clipped.length))
        }
        for inline in block.change.inlineChanges {
            let clipped = NSIntersectionRange(inline.originalRange, range)
            guard clipped.length > 0 else { continue }
            result.addAttribute(.backgroundColor, value: UIColor.systemRed.withAlphaComponent(0.22),
                                range: NSRange(location: clipped.location - range.location, length: clipped.length))
        }
        return result
    }

    private func hasFocus(_ block: Block) -> Bool {
        guard let view = block.view else { return false }
        return view.isFirstResponder
    }

    private func detach(_ view: SyntaxEditorComparisonDeletedTextView) {
        if view.isFirstResponder { editor?.becomeFirstResponder() }
        view.onSelectionChange = nil
        view.removeFromSuperview()
    }

    private final class Block {
        let index: Int
        let change: EditorComparisonEngine.Change
        let isFooter: Bool
        let text: String
        let metrics: DocumentLineMetrics
        var estimatedSize = CGSize.zero
        var size = CGSize.zero
        var height: CGFloat { max(1, size.height) + 8 }
        var view: SyntaxEditorComparisonDeletedTextView?
        var needsStyleUpdate = false
        var appliedNativeOffset = CGPoint.zero

        init(index: Int, change: EditorComparisonEngine.Change, isFooter: Bool, text: String) {
            self.index = index
            self.change = change
            self.isFooter = isFooter
            self.text = text
            metrics = DocumentLineMetrics(source: text, tabWidth: 4)
        }
    }
}
#endif
