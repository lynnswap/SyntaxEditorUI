#if canImport(UIKit)
import UIKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorComparisonViewport {
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
        let font: UIFont
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
        for side: Side in [.modified, .original] {
            guard let editor = editor(for: side) else { continue }
            previousBounds[side] = editor.bounds
            editor.comparisonWillLayout = { [weak self] in self?.willLayout(side) }
            editor.comparisonDidLayout = { [weak self] changed in self?.didLayout(side, changed: changed) }
            let previous = editor.didChangeComparisonViewport
            editor.didChangeComparisonViewport = { [weak self] in
                previous?()
                self?.boundsDidChange(side)
            }
        }
    }

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
        comparison.modifiedEditor.layoutTextIfNeeded()
        if presentation == .sideBySide { comparison.originalEditor.layoutTextIfNeeded() }
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
              comparison.modifiedEditor.bounds.width > 0,
              comparison.modifiedEditor.bounds.height > 0 else { return }
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

    private func boundsDidChange(_ side: Side) {
        guard let comparison, let editor = editor(for: side) else { return }
        let oldBounds = previousBounds[side]
        previousBounds[side] = editor.bounds
        guard !isAdjusting, oldBounds?.minY != editor.bounds.minY else { return }
        if editor.isLayingOutText || editor.isApplyingModel || editor.isApplyingUndoRedo { return }
        if let prior = geometries[side], prior != geometry(editor) { return }
        snapshots[side] = nil
        if side == .modified { pendingComparisonAnchor = nil }
        if comparison.displayedPresentation == .sideBySide {
            driver = side
            isAdjusting = true
            defer { isAdjusting = false }
            editor.layoutTextIfNeeded()
            synchronize(from: side)
            recordAll()
        }
    }

    private func geometry(_ editor: SyntaxEditorView) -> Geometry {
        Geometry(font: editor.font, width: editor.textContainer.size.width,
                 wraps: editor.lastAppliedLineWrappingEnabled,
                 documentSize: editor.contentSize, viewportSize: editor.adjustedVisibleContentSize)
    }

    private func willLayout(_ side: Side) {
        guard !isAdjusting else { return }
        isAdjusting = true
        layoutAnchors[side] = preferredAnchor(side)
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
        guard let editor = editor(for: side), !editor.bounds.isEmpty else { return nil }
        if let snapshot = snapshots[side], snapshot.y == editor.contentOffset.y {
            return snapshot.anchor
        }
        return capture(side)
    }

    private func capture(_ side: Side) -> Anchor? {
        guard let comparison, let editor = editor(for: side), !editor.bounds.isEmpty,
              editor.lastAppliedDocumentRevision == editor.model.textRevision,
              !editor.isApplyingModel, !editor.isApplyingUndoRedo else { return nil }
        let visible = editor.adjustedVisibleContentRect
        let insets = editor.adjustedContentInset
        if editor.contentOffset.y <= -max(0, insets.top) { return .top }
        let bottom = max(-insets.top, editor.contentSize.height - editor.bounds.height + insets.bottom)
        if abs(editor.contentOffset.y - bottom) < 0.5 { return .bottom }
        if side == .modified, let reference = comparison.inlineLayout.referencePosition(atY: visible.minY) {
            guard reference.revision == comparison.model.original.textRevision else { return nil }
            return .reference(reference)
        }
        guard let offset = characterOffset(at: visible.minY, in: editor) else { return nil }
        guard let caret = frame(NSRange(location: offset, length: 0), in: editor) else { return nil }
        return .document(offset: offset, delta: visible.minY - caret.minY,
                         revision: editor.model.textRevision, source: editor.model.text)
    }

    private func record(_ side: Side) {
        guard let editor = editor(for: side), let anchor = capture(side) else { return }
        snapshots[side] = Snapshot(y: editor.contentOffset.y, anchor: anchor)
        geometries[side] = geometry(editor)
    }

    private func recordAll() {
        record(.modified)
        if comparison?.displayedPresentation == .sideBySide { record(.original) }
    }

    private func restore(_ anchor: Anchor, in side: Side) {
        guard let comparison, let editor = editor(for: side), !editor.bounds.isEmpty else { return }
        for _ in 0..<3 {
            let y: CGFloat?
            switch anchor {
            case .top:
                y = 0
            case .bottom:
                y = editor.contentSize.height + editor.adjustedContentInset.bottom
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
            let before = editor.contentOffset.y
            // Keep the restored line on the visible side of a fractional pixel boundary.
            let scale = max(1, editor.traitCollection.displayScale)
            scroll(editor, to: ceil(y * scale) / scale)
            if abs(before - editor.contentOffset.y) < 0.25 { break }
        }
    }

    private func projectedOffset(_ offset: Int, revision: Int, source: String, in editor: SyntaxEditorView) -> Int {
        let projected: Int
        if revision == editor.lastAppliedDocumentRevision { projected = offset }
        else if let change = editor.model.latestTextChange, change.textRevision == revision + 1,
                change.kind == .incremental {
            projected = Self.project(offset, through: change.replacements)
        } else if let replacement = SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: editor.storage.string) {
            projected = Self.project(offset, through: [replacement])
        } else { projected = offset }
        return projected
    }

    private func rebased(_ anchor: Anchor, in editor: SyntaxEditorView) -> Anchor {
        guard case let .document(offset, delta, revision, source) = anchor,
              editor.lastAppliedDocumentRevision == editor.model.textRevision,
              !editor.isApplyingModel, !editor.isApplyingUndoRedo else { return anchor }
        return .document(offset: projectedOffset(offset, revision: revision, source: source, in: editor),
                         delta: delta, revision: editor.lastAppliedDocumentRevision, source: editor.storage.string)
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
        let y = source.adjustedVisibleContentRect.minY
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
        let before = editor.contentOffset
        func displayedFrame() -> CGRect? {
            let inlineFrame = isModified && comparison?.displayedPresentation == .inline
                ? comparison?.inlineLayout.frame(forChangeAt: index) : nil
            if range.length == 0, isModified, comparison?.displayedPresentation == .inline {
                return inlineFrame
            }
            guard let text = frame(range, in: editor) else { return inlineFrame }
            return inlineFrame.map { $0.union(text) } ?? text
        }
        let visible = editor.adjustedVisibleContentRect
        if let displayed = displayedFrame(), displayed.minY < visible.maxY, displayed.maxY > visible.minY { return false }
        let offset = min(range.location, max(0, editor.storage.length - 1))
        if let location = editor.textLocation(forUTF16Offset: offset) {
            let estimate = editor.layoutManager.textViewportLayoutController.relocateViewport(to: location)
            scroll(editor, to: estimate + editor.textContentView.frame.minY)
            editor.layoutTextIfNeeded()
        }
        if let target = displayedFrame() {
            editor.scrollContentRectToVisible(CGRect(x: target.minX, y: target.minY, width: 1,
                                                   height: min(target.height, visible.height)))
            editor.layoutTextIfNeeded()
        }
        return before != editor.contentOffset
    }

    func frame(_ range: NSRange, in editor: SyntaxEditorView) -> CGRect? {
        let range = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: editor.storage.length)
        if range.length == 0 { return editor.caretRect(for: SyntaxEditorView.TextPosition(offset: range.location)) }
        let origin = CGPoint(x: -editor.textContentView.frame.minX, y: -editor.textContentView.frame.minY)
        let rects = TextLayoutGeometry.standardRects(
            layoutManager: editor.layoutManager, rangeConverter: editor.textSystem.rangeConverter,
            ranges: [NSRange(location: range.location, length: 1), NSRange(location: range.upperBound - 1, length: 1)],
            offsetBy: origin
        )
        guard let first = rects.first, let last = rects.last else { return nil }
        return first.union(last)
    }

    func lineFrame(_ index: Int, in editor: SyntaxEditorView) -> CGRect? {
        let offsets = editor.lineMetrics.lineOffsets
        let line = min(max(0, index), offsets.lineCount - 1)
        let start = offsets.lineStartOffset(at: line)
        return frame(NSRange(location: start, length: offsets.lineEndOffset(at: line) - start), in: editor)
    }

    func logicalLine(at y: CGFloat, in editor: SyntaxEditorView) -> CGFloat? {
        guard let offset = characterOffset(at: y, in: editor) else { return nil }
        let index = editor.lineMetrics.lineOffsets.lineIndex(containingUTF16Offset: offset)
        guard let row = lineFrame(index, in: editor) else { return nil }
        return CGFloat(index) + min(max((y - row.minY) / max(1, row.height), 0), 1)
    }

    private func characterOffset(at y: CGFloat, in editor: SyntaxEditorView) -> Int? {
        guard let position = editor.closestPosition(to: CGPoint(x: editor.textContentView.frame.minX + editor.container.lineFragmentPadding + 1, y: y)) else { return nil }
        return editor.offset(from: editor.beginningOfDocument, to: position)
    }

    private func scroll(_ editor: SyntaxEditorView, to y: CGFloat) {
        let insets = editor.adjustedContentInset
        let maximum = max(-insets.top, editor.contentSize.height - editor.bounds.height + insets.bottom)
        let target = min(max(-insets.top, y - insets.top), maximum)
        guard abs(target - editor.contentOffset.y) > 0.25 else { return }
        editor.setContentOffset(CGPoint(x: editor.contentOffset.x, y: target), animated: false)
        editor.layoutTextIfNeeded()
    }
}
#endif
