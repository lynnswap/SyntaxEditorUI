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
    private enum Anchor {
        case top
        case bottom
        case document(offset: Int, delta: CGFloat, revision: Int, source: String)
        case reference(SyntaxEditorInlineComparisonLayout.ReferencePosition)
    }
    private struct Snapshot {
        let y: CGFloat
        let anchor: Anchor
    }
    private struct Geometry: Equatable {
        let font: NSFont?
        let width: CGFloat
        let wraps: Bool
        let documentSize: CGSize
        let viewportSize: CGSize
    }
    private var snapshots: [Side: Snapshot] = [:]
    private var geometries: [Side: Geometry] = [:]
    private var layoutAnchors: [Side: Anchor] = [:]
    private var pendingComparisonAnchor: Anchor?

    init(comparison: SyntaxEditorComparisonView) {
        self.comparison = comparison
        super.init()
        for side: Side in [.modified, .original] {
            guard let editor = editor(for: side) else { continue }
            previousBounds[side] = editor.contentView.bounds
            editor.textView.comparisonWillLayout = { [weak self] in self?.willLayout(side) }
            editor.textView.comparisonDidLayout = { [weak self] changed in self?.didLayout(side, changed: changed) }
            editor.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: editor.contentView)
        }
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    func reset() {
        driver = .modified
        pendingReveal = nil
        pendingComparisonAnchor = nil
        snapshots.removeAll()
        geometries.removeAll()
        layoutAnchors.removeAll()
    }

    func performUpdate(appliesComparison: Bool = false, _ update: () -> Void) {
        guard !isAdjusting, let comparison else { update(); return }
        isAdjusting = true
        defer { isAdjusting = false }
        let model = comparison.model
        let priorPresentation = comparison.displayedPresentation
        var modified = pendingComparisonAnchor ?? preferredAnchor(.modified)
        let original = preferredAnchor(.original)
        if appliesComparison, model.presentation == .inline, priorPresentation == .sideBySide, driver == .original,
           case let .document(offset, delta, revision, _) = original,
           model.changes?.contains(where: { NSLocationInRange(offset, $0.originalRange) }) == true {
            modified = .reference(.init(offset: offset, delta: delta, revision: revision))
        }
        if priorPresentation == .inline, model.changes == nil, pendingComparisonAnchor == nil {
            pendingComparisonAnchor = modified
        }
        update()
        guard comparison.model === model else { recordAll(); return }
        let presentation = comparison.displayedPresentation
        if presentation != .sideBySide { driver = .modified }
        comparison.modifiedEditor.textView.layoutVisibleViewport()
        if presentation == .sideBySide { comparison.originalEditor.textView.layoutVisibleViewport() }
        if presentation == .sideBySide, let original { restore(original, in: .original) }
        if let modified {
            let current = rebased(modified, in: comparison.modifiedEditor)
            restore(current, in: .modified)
            if pendingComparisonAnchor != nil { pendingComparisonAnchor = current }
        }
        if (appliesComparison && model.changes != nil) || presentation != .inline { pendingComparisonAnchor = nil }
        recordAll()
    }

    func selectionDidChange(_ index: Int?) {
        if index != nil { pendingComparisonAnchor = nil }
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
            let movedOriginal = comparison.displayedPresentation == .sideBySide
                && reveal(change.originalRange, index: index, in: comparison.originalEditor, isModified: false)
            if movedOriginal, !movedModified || change.modifiedRange.length == 0 { driver = .original }
            else if movedModified { driver = .modified }
            recordAll()
            return
        }
        if comparison.displayedPresentation == .sideBySide { synchronize(from: driver) }
        recordAll()
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let comparison, let clip = notification.object as? NSClipView else { return }
        let side: Side
        if clip === comparison.modifiedEditor.contentView { side = .modified }
        else if clip === comparison.originalEditor.contentView { side = .original }
        else { return }
        let oldBounds = previousBounds[side]
        previousBounds[side] = clip.bounds
        guard !isAdjusting, oldBounds?.minY != clip.bounds.minY, let editor = editor(for: side) else { return }
        if editor.textView.isLayingOutViewport || editor.isApplyingModel || editor.isApplyingUndoRedo
            || editor.pendingHighlightEdit != nil { return }
        if let prior = geometries[side], prior != geometry(editor) { return }
        snapshots[side] = nil
        if side == .modified { pendingComparisonAnchor = nil }
        if comparison.displayedPresentation == .sideBySide {
            driver = side
            isAdjusting = true
            defer { isAdjusting = false }
            editor.textView.layoutVisibleViewport()
            synchronize(from: side)
            recordAll()
        }
    }

    private func geometry(_ editor: SyntaxEditorView) -> Geometry {
        Geometry(font: editor.textView.font, width: editor.textContainer.size.width,
                 wraps: !editor.textView.isHorizontallyResizable,
                 documentSize: editor.textView.bounds.size, viewportSize: editor.contentView.bounds.size)
    }

    private func willLayout(_ side: Side) {
        guard !isAdjusting else { return }
        isAdjusting = true
        let anchor = side == .modified ? pendingComparisonAnchor ?? preferredAnchor(side) : preferredAnchor(side)
        if side == .modified, comparison?.displayedPresentation == .inline,
           comparison?.hasUnappliedComparisonContent == true, pendingComparisonAnchor == nil {
            pendingComparisonAnchor = anchor
        }
        layoutAnchors[side] = anchor
        isAdjusting = false
    }

    private func didLayout(_ side: Side, changed: Bool) {
        guard let editor = editor(for: side) else { return }
        let previous = geometries[side]
        geometries[side] = geometry(editor)
        guard !isAdjusting else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        let anchor = layoutAnchors.removeValue(forKey: side)
        if changed || (previous != nil && previous != geometries[side]), let anchor {
            restore(anchor, in: side)
        }
        record(side)
    }

    private func preferredAnchor(_ side: Side) -> Anchor? {
        guard let editor = editor(for: side), !editor.contentView.bounds.isEmpty else { return nil }
        if let snapshot = snapshots[side], snapshot.y == editor.contentView.bounds.minY {
            return snapshot.anchor
        }
        return capture(side)
    }

    private func capture(_ side: Side) -> Anchor? {
        guard let comparison, let editor = editor(for: side), !editor.contentView.bounds.isEmpty,
              editor.lastAppliedDocumentRevision == editor.model.textRevision,
              !editor.isApplyingModel, !editor.isApplyingUndoRedo, editor.pendingHighlightEdit == nil else { return nil }
        let clip = editor.contentView
        let visible = editor.textView.convert(clip.bounds, from: clip)
        if clip.bounds.minY <= -max(0, clip.contentInsets.top) { return .top }
        var bottom = clip.bounds
        bottom.origin.y = editor.textView.bounds.maxY + clip.contentInsets.bottom
        if abs(clip.bounds.minY - clip.constrainBoundsRect(bottom).minY) < 0.5 { return .bottom }
        if side == .modified, let reference = comparison.inlineLayout.referencePosition(atY: visible.minY) {
            guard reference.revision == comparison.model.original.textRevision else { return nil }
            return .reference(reference)
        }
        let offset = editor.textView.characterIndex(at: CGPoint(x: editor.textContainer.lineFragmentPadding + 1, y: visible.minY))
        guard let caret = frame(NSRange(location: offset, length: 0), in: editor) else { return nil }
        return .document(offset: offset, delta: visible.minY - caret.minY,
                         revision: editor.model.textRevision, source: editor.model.text)
    }

    private func record(_ side: Side) {
        guard let editor = editor(for: side), let anchor = capture(side) else { return }
        snapshots[side] = Snapshot(y: editor.contentView.bounds.minY, anchor: anchor)
        geometries[side] = geometry(editor)
    }

    private func recordAll() {
        record(.modified)
        if comparison?.displayedPresentation == .sideBySide { record(.original) }
    }

    private func restore(_ anchor: Anchor, in side: Side) {
        guard let comparison, let editor = editor(for: side), !editor.contentView.bounds.isEmpty else { return }
        for _ in 0..<3 {
            let y: CGFloat?
            switch anchor {
            case .top:
                y = -max(0, editor.contentView.contentInsets.top)
            case .bottom:
                y = editor.textView.bounds.maxY + editor.contentView.contentInsets.bottom
            case let .document(offset, delta, revision, source):
                let projected = projectedOffset(offset, revision: revision, source: source, in: editor)
                y = frame(NSRange(location: projected, length: 0), in: editor).map { $0.minY + delta }
            case let .reference(position):
                guard position.revision == comparison.model.original.textRevision else { return }
                if comparison.displayedPresentation == .sideBySide {
                    restore(.document(offset: position.offset, delta: position.delta,
                                      revision: position.revision, source: comparison.model.originalText), in: .original)
                    driver = .original
                    return
                }
                guard comparison.displayedPresentation == .inline else { return }
                if comparison.inlineLayout.referenceY(for: position) == nil,
                   let index = comparison.inlineLayout.changeIndex(containingOriginalOffset: position.offset),
                   let changes = comparison.model.changes, changes.indices.contains(index) {
                    _ = reveal(changes[index].modifiedRange, index: index, in: editor, isModified: true)
                }
                y = comparison.inlineLayout.referenceY(for: position)
            }
            guard let y else { return }
            let before = editor.contentView.bounds.minY
            // Avoid crossing the preceding line through roundoff without rounding fractional scroll positions.
            scroll(editor, to: y.nextUp)
            if abs(before - editor.contentView.bounds.minY) < 0.25 { break }
        }
    }

    private func projectedOffset(_ offset: Int, revision: Int, source: String, in editor: SyntaxEditorView) -> Int {
        let projected: Int
        if revision == editor.lastAppliedDocumentRevision { projected = offset }
        else if let change = editor.model.latestTextChange, change.textRevision == revision + 1,
                change.kind == .incremental {
            projected = Self.project(offset, through: change.replacements)
        } else if let replacement = SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: editor.textView.string) {
            projected = Self.project(offset, through: [replacement])
        } else { projected = offset }
        return projected
    }

    private func rebased(_ anchor: Anchor, in editor: SyntaxEditorView) -> Anchor {
        guard case let .document(offset, delta, revision, source) = anchor,
              editor.lastAppliedDocumentRevision == editor.model.textRevision,
              !editor.isApplyingModel, !editor.isApplyingUndoRedo else { return anchor }
        return .document(offset: projectedOffset(offset, revision: revision, source: source, in: editor),
                         delta: delta, revision: editor.lastAppliedDocumentRevision, source: editor.textView.string)
    }

    private static func project(_ offset: Int, through edits: [SyntaxEditorTextChange.Replacement]) -> Int {
        var delta = 0
        for edit in edits.sorted(by: { $0.location < $1.location }) {
            if offset < edit.range.location { break }
            let inserted = edit.replacement.utf16.count
            if offset < edit.range.upperBound {
                return edit.range.location + delta + min(offset - edit.range.location, inserted)
            }
            delta += inserted - edit.range.length
        }
        return offset + delta
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
            let inlineFrame = isModified && comparison?.displayedPresentation == .inline
                ? comparison?.inlineLayout.frame(forChangeAt: index) : nil
            if range.length == 0, isModified, comparison?.displayedPresentation == .inline {
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
