#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorComparisonViewport: NSObject {
    typealias Side = EditorComparisonGeometry.Side
    private weak var comparison: SyntaxEditorComparisonView?
    private var isAdjusting = false
    private var driver: Side = .modified
    private var previousBounds: [Side: CGRect] = [:]
    private var pendingReveal: Int?

    init(comparison: SyntaxEditorComparisonView) {
        self.comparison = comparison
        super.init()
        for side: Side in [.modified, .original] {
            guard let editor = editor(for: side) else { continue }
            previousBounds[side] = editor.contentView.bounds
            editor.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: editor.contentView)
        }
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    func reset() {
        driver = .modified
        pendingReveal = nil
    }

    func performUpdate(_ update: () -> Void) {
        let wasAdjusting = isAdjusting
        isAdjusting = true
        update()
        isAdjusting = wasAdjusting
        if comparison?.model.presentation != .sideBySide { driver = .modified }
    }

    func selectionDidChange(_ index: Int?) {
        pendingReveal = index
        layoutDidComplete()
    }

    func layoutDidComplete() {
        guard !isAdjusting, let comparison,
              comparison.modifiedEditor.contentView.bounds.width > 0,
              comparison.modifiedEditor.contentView.bounds.height > 0 else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        if let index = pendingReveal, let changes = comparison.model.changes, changes.indices.contains(index) {
            pendingReveal = nil
            let change = changes[index]
            let movedModified = reveal(change.modifiedRange, index: index, in: comparison.modifiedEditor, isModified: true)
            let movedOriginal = comparison.model.presentation == .sideBySide
                && reveal(change.originalRange, index: index, in: comparison.originalEditor, isModified: false)
            if movedOriginal, !movedModified || change.modifiedRange.length == 0 { driver = .original }
            else if movedModified { driver = .modified }
            return
        }
        if comparison.model.presentation == .sideBySide { synchronize(from: driver) }
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let comparison, let clip = notification.object as? NSClipView else { return }
        let side: Side
        if clip === comparison.modifiedEditor.contentView { side = .modified }
        else if clip === comparison.originalEditor.contentView { side = .original }
        else { return }
        let oldBounds = previousBounds[side]
        previousBounds[side] = clip.bounds
        guard !isAdjusting, comparison.model.presentation == .sideBySide,
              oldBounds?.size == clip.bounds.size,
              oldBounds?.minY != clip.bounds.minY else { return }
        driver = side
        isAdjusting = true
        defer { isAdjusting = false }
        editor(for: side)?.textView.layoutVisibleViewport()
        synchronize(from: side)
    }

    private func editor(for side: Side) -> SyntaxEditorView? {
        side == .modified ? comparison?.modifiedEditor : comparison?.originalEditor
    }

    private func synchronize(from side: Side) {
        guard let comparison, let changes = comparison.model.changes,
              let source = editor(for: side), let destination = editor(for: side == .modified ? .original : .modified),
              source.lastAppliedDocumentRevision == source.model.textRevision,
              destination.lastAppliedDocumentRevision == destination.model.textRevision else { return }
        let y = source.textView.convert(source.contentView.bounds.origin, from: source.contentView).y
        if y < 0 { scroll(destination, to: y); return }
        guard let line = logicalLine(at: y, in: source) else { return }
        let counterpart = EditorComparisonGeometry.counterpartLine(line, from: side, changes: changes)
        let targetY: CGFloat?
        if let change = changes.first(where: {
            let span = side == .modified ? $0.modifiedLines : $0.originalLines
            return line >= CGFloat(span.lowerBound) && line < CGFloat(span.upperBound)
        }), let from = frame(side == .modified ? change.modifiedRange : change.originalRange, in: source),
           let to = frame(side == .modified ? change.originalRange : change.modifiedRange, in: destination) {
            let sourceRange = side == .modified ? change.modifiedRange : change.originalRange
            let destinationRange = side == .modified ? change.originalRange : change.modifiedRange
            let height = sourceRange.length == 0 ? 0 : from.height
            let progress = height > 0 ? min(max((y - from.minY) / height, 0), 1) : 0
            targetY = to.minY + progress * (destinationRange.length == 0 ? 0 : to.height)
        } else if let target = lineFrame(Int(floor(counterpart)), in: destination) {
            targetY = target.minY + min(max(counterpart - floor(counterpart), 0), 1) * target.height
        } else { targetY = nil }
        if let targetY { scroll(destination, to: targetY) }
    }

    @discardableResult
    private func reveal(_ range: NSRange, index: Int, in editor: SyntaxEditorView, isModified: Bool) -> Bool {
        let before = editor.contentView.bounds.origin
        func displayedFrame() -> CGRect? {
            let inlineFrame = isModified && comparison?.model.presentation == .inline
                ? comparison?.inlineLayout.frame(forChangeAt: index) : nil
            if range.length == 0, isModified, comparison?.model.presentation == .inline {
                return inlineFrame
            }
            guard let text = frame(range, in: editor) else { return inlineFrame }
            return inlineFrame.map { $0.union(text) } ?? text
        }
        let visible = editor.textView.convert(editor.contentView.bounds, from: editor.contentView)
        if let displayed = displayedFrame(), displayed.minY < visible.maxY, displayed.maxY > visible.minY { return false }
        let offset = min(range.location, max(0, editor.textStorage.length - 1))
        if let location = editor.textView.textLocation(forUTF16Offset: offset) {
            let estimate = editor.layoutManager.textViewportLayoutController.relocateViewport(to: location)
            scroll(editor, to: estimate)
            editor.textView.layoutVisibleViewport()
        }
        if let target = displayedFrame() {
            editor.textView.scrollToVisible(CGRect(x: target.minX, y: target.minY, width: 1,
                                                   height: min(target.height, visible.height)))
            editor.textView.layoutVisibleViewport()
        }
        return before != editor.contentView.bounds.origin
    }

    func frame(_ range: NSRange, in editor: SyntaxEditorView) -> CGRect? {
        let range = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: editor.textStorage.length)
        if range.length == 0 { return editor.textView.caretRect(forUTF16Location: range.location) }
        guard let first = editor.textView.rectsForCharacterRange(NSRange(location: range.location, length: 1)).first,
              let last = editor.textView.rectsForCharacterRange(NSRange(location: range.upperBound - 1, length: 1)).last else { return nil }
        return first.union(last)
    }

    func lineFrame(_ index: Int, in editor: SyntaxEditorView) -> CGRect? {
        let offsets = editor.textView.lineMetrics.lineOffsets
        let line = min(max(0, index), offsets.lineCount - 1)
        let start = offsets.lineStartOffset(at: line)
        return frame(NSRange(location: start, length: offsets.lineEndOffset(at: line) - start), in: editor)
    }

    func logicalLine(at y: CGFloat, in editor: SyntaxEditorView) -> CGFloat? {
        let offset = editor.textView.characterIndex(at: CGPoint(x: editor.textContainer.lineFragmentPadding + 1, y: y))
        let index = editor.textView.lineMetrics.lineOffsets.lineIndex(containingUTF16Offset: offset)
        guard let row = lineFrame(index, in: editor) else { return nil }
        return CGFloat(index) + min(max((y - row.minY) / max(1, row.height), 0), 1)
    }

    private func scroll(_ editor: SyntaxEditorView, to y: CGFloat) {
        let clip = editor.contentView
        var proposed = clip.bounds
        proposed.origin.y = clip.convert(CGPoint(x: 0, y: y), from: editor.textView).y
        let constrained = clip.constrainBoundsRect(proposed)
        guard abs(constrained.minY - clip.bounds.minY) > 0.25 else { return }
        clip.scroll(to: constrained.origin)
        editor.reflectScrolledClipView(clip)
        editor.textView.layoutVisibleViewport()
    }
}
#endif
