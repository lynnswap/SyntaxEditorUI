#if canImport(AppKit)
import AppKit
import ObservationBridge
import Testing
@testable import SyntaxEditorModel
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit

extension SyntaxEditorUITests {
    @Test("An edit below an inline deletion preserves its viewed reference line after comparison")
    @MainActor
    func macComparisonPreservesReferenceAnchorAcrossPendingResult() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let before = try #require(pendingAnchorVisibleReferenceLine(fixture.view))
        let replacement = fixture.initialModified + "new final line\n"
        try await holdPendingAnchorEdit(fixture, replacement: replacement)
        #expect(fixture.view.model.changeCount == nil)
        #expect(fixture.view.modifiedLayout.changes.isEmpty)
        #expect(fixture.view.inlineLayout.deletedViews.isEmpty)
        #expect(fixture.view.modifiedEditor.text == replacement)

        await fixture.gate.release(original: fixture.original, modified: replacement)
        try await finishPendingAnchorComparison(fixture.view)

        #expect(pendingAnchorVisibleReferenceLine(fixture.view) == before)
        #expect(fixture.view.modifiedEditor.text == replacement)
    }

    @Test("Pending inline restoration locates reference text after earlier changes renumber groups")
    @MainActor
    func macComparisonRestoresPendingAnchorAfterGroupRenumbering() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let before = try #require(pendingAnchorVisibleReferenceLine(fixture.view))
        #expect(fixture.view.model.changes?.count == 1)
        let replacement = fixture.initialModified.replacingOccurrences(of: "header 5\n", with: "changed header 5\n")
        try await holdPendingAnchorEdit(fixture, replacement: replacement)

        await fixture.gate.release(original: fixture.original, modified: replacement)
        try await finishPendingAnchorComparison(fixture.view)

        let changes = try #require(fixture.view.model.changes)
        let index = try #require(changes.firstIndex { NSLocationInRange(before, $0.originalRange) })
        #expect(index == 1)
        #expect(pendingAnchorVisibleReferenceLine(fixture.view) == before)
    }

    @Test("Scrolling during a pending comparison supersedes its saved reference position")
    @MainActor
    func macComparisonDiscardsPendingAnchorAfterScroll() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let replacement = fixture.initialModified + "new final line\n"
        try await holdPendingAnchorEdit(fixture, replacement: replacement)
        let editor = fixture.view.modifiedEditor
        editor.contentView.scroll(to: CGPoint(x: editor.contentView.bounds.minX, y: 0))
        editor.reflectScrolledClipView(editor.contentView)
        layoutPendingAnchorComparison(fixture.view)

        await fixture.gate.release(original: fixture.original, modified: replacement)
        try await finishPendingAnchorComparison(fixture.view)

        #expect(abs(editor.contentView.bounds.minY) < 1)
        #expect(pendingAnchorVisibleReferenceLine(fixture.view) == nil)
    }

    @Test("Reference changes and model rebinding invalidate a pending inline reference anchor")
    @MainActor
    func macComparisonDiscardsPendingAnchorAfterIdentityChange() async throws {
        for changesModel in [false, true] {
            let fixture = try await makePendingAnchorFixture()
            defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
            let before = try #require(pendingAnchorVisibleReferenceLine(fixture.view))
            let replacement = fixture.initialModified + "new final line\n"
            try await holdPendingAnchorEdit(fixture, replacement: replacement)

            if changesModel {
                // Identical reference contents/revision intentionally make the
                // comparison-model identity the only invalidation boundary.
                let next = SyntaxEditorComparisonModel(
                    originalText: fixture.original,
                    modified: SyntaxEditorModel(text: fixture.initialModified, language: .plainText)
                )
                await next.calculation?.value
                fixture.view.update(model: next)
                try await finishPendingAnchorComparison(fixture.view)
                #expect(fixture.view.model === next)
            } else {
                fixture.view.model.originalText = "different reference heading\n" + fixture.original
                try await finishPendingAnchorComparison(fixture.view)
            }

            await fixture.gate.release(original: fixture.original, modified: replacement)
            await fixture.comparison.calculation?.value
            await fixture.view.waitForPendingComparisonRefreshForTesting()
            layoutPendingAnchorComparison(fixture.view)
            #expect(pendingAnchorVisibleReferenceLine(fixture.view) != before)
        }
    }

    @Test("Successive pending edits keep the same reference position across cancelled calculations")
    @MainActor
    func macComparisonPreservesAnchorAcrossSuccessivePendingEdits() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let before = try #require(pendingAnchorVisibleReferenceLine(fixture.view))
        let first = fixture.initialModified + "new final line\n"
        try await holdPendingAnchorEdit(fixture, replacement: first)
        let second = first.replacingOccurrences(of: "header 5\n", with: "changed header 5\n")
        try await holdPendingAnchorEdit(fixture, replacement: second)
        await fixture.gate.release(original: fixture.original, modified: second)
        try await finishPendingAnchorComparison(fixture.view)
        #expect(pendingAnchorVisibleReferenceLine(fixture.view) == before)
        await fixture.gate.release(original: fixture.original, modified: first)
        await fixture.view.waitForPendingComparisonRefreshForTesting()
        #expect(pendingAnchorVisibleReferenceLine(fixture.view) == before)
    }

    @Test("A coalesced ready-to-ready delivery preserves the viewed reference line")
    @MainActor
    func macComparisonPreservesAnchorWithoutPendingDelivery() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let view = fixture.view
        let before = try #require(pendingAnchorVisibleReferenceLine(view))
        // Omit the intermediate delivery to reproduce observation coalescing.
        view.comparisonDeliveryForTesting?.cancel()
        let replacement = fixture.initialModified + "new final line\n"
        await fixture.gate.hold(original: fixture.original, modified: replacement)
        fixture.comparison.modified.text = replacement
        await fixture.gate.waitUntilSuspended(original: fixture.original, modified: replacement)
        view.modifiedEditor.synchronizeDocumentForTesting()
        #expect(!view.inlineLayout.deletedViews.isEmpty)
        await fixture.gate.release(original: fixture.original, modified: replacement)
        await fixture.comparison.calculation?.value
        #expect(view.model.changes != nil)
        view.viewDidChangeEffectiveAppearance()
        try await finishPendingAnchorComparison(view)
        #expect(pendingAnchorVisibleReferenceLine(view) == before)
    }

    @Test("Pending and completed comparisons preserve a current line below a tall deletion")
    @MainActor
    func macComparisonPreservesCurrentLineAcrossPendingResult() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let view = fixture.view
        let editor = view.modifiedEditor
        let line = try #require(view.viewport.lineFrame(150, in: editor))
        editor.contentView.scroll(to: CGPoint(x: 0, y: line.minY))
        editor.reflectScrolledClipView(editor.contentView)
        layoutPendingAnchorComparison(view)
        let before = try #require(view.viewport.logicalLine(at: editor.contentView.bounds.minY, in: editor))
        let first = "inserted heading\n" + fixture.initialModified
        try await holdPendingAnchorEdit(fixture, replacement: first)
        let pending = try #require(view.viewport.logicalLine(at: editor.contentView.bounds.minY, in: editor))
        #expect(abs(pending - before - 1) < 0.2)
        let second = first + "new final line\n"
        try await holdPendingAnchorEdit(fixture, replacement: second)
        await fixture.gate.release(original: fixture.original, modified: second)
        try await finishPendingAnchorComparison(view)
        let ready = try #require(view.viewport.logicalLine(at: editor.contentView.bounds.minY, in: editor))
        #expect(abs(ready - before - 1) < 0.2)
    }

    @Test("Switching between inline and side-by-side retains the viewed reference line")
    @MainActor
    func macComparisonPreservesReferenceLineAcrossPresentationChanges() async throws {
        let fixture = try await makePendingAnchorFixture()
        defer { fixture.window.orderOut(nil); Task { await fixture.gate.releaseAll() } }
        let view = fixture.view
        let before = try #require(pendingAnchorVisibleReferenceLine(view))
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let presentations = await delivery.values { view.model.presentation }
        view.model.presentation = .sideBySide
        #expect(await presentations.waitUntilValue(.sideBySide))
        await view.waitForPendingComparisonRefreshForTesting()
        let reference = view.originalEditor
        let y = reference.textView.convert(reference.contentView.bounds.origin, from: reference.contentView).y
        let offset = reference.textView.characterIndex(at: CGPoint(x: reference.textContainer.lineFragmentPadding + 1, y: y))
        let visible = (reference.text as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
        #expect(visible == before)

        view.model.presentation = .inline
        #expect(await presentations.waitUntilValue(.inline))
        await view.waitForPendingComparisonRefreshForTesting()
        layoutPendingAnchorComparison(view)
        #expect(pendingAnchorVisibleReferenceLine(view) == before)
    }

    @MainActor
    private func makePendingAnchorFixture() async throws -> PendingAnchorFixture {
        let prefix = (0..<20).map { "header \($0)\n" }.joined()
        let deleted = (0..<240).map { "deleted reference \($0)\n" }.joined()
        let suffix = (0..<240).map { "current tail \($0)\n" }.joined()
        let modified = prefix + suffix
        let original = prefix + deleted + suffix
        let gate = InlineAnchorComparisonGate()
        let document = SyntaxEditorModel(text: modified, language: .plainText)
        let comparison = SyntaxEditorComparisonModel(originalText: original, modified: document) { original, modified in
            await gate.waitIfHeld(original: original, modified: modified)
            return try await EditorComparisonEngine.compare(original: original, modified: modified)
        }
        let calculation = try #require(comparison.calculation)
        await calculation.value
        #expect(comparison.changeCount == 1)
        let view = SyntaxEditorComparisonView(model: comparison)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        layoutPendingAnchorComparison(view)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        view.viewport.selectionDidChange(0)
        layoutPendingAnchorComparison(view)
        let reference = try #require(view.inlineLayout.deletedViews[0])
        let frame = reference.convert(reference.bounds, to: view.modifiedEditor.textView)
        let editor = view.modifiedEditor
        editor.contentView.scroll(to: CGPoint(x: 0, y: frame.minY + 1_200))
        editor.reflectScrolledClipView(editor.contentView)
        layoutPendingAnchorComparison(view)
        return PendingAnchorFixture(
            comparison: comparison, view: view, window: window, gate: gate,
            original: original, initialModified: modified
        )
    }

    @MainActor
    private func holdPendingAnchorEdit(_ fixture: PendingAnchorFixture, replacement: String) async throws {
        await fixture.gate.hold(original: fixture.original, modified: replacement)
        let editorDelivery = try #require(fixture.view.modifiedEditor.modelDeliveryForTesting)
        let renderedText = await editorDelivery.values { fixture.view.modifiedEditor.text }
        fixture.comparison.modified.text = replacement
        await fixture.gate.waitUntilSuspended(original: fixture.original, modified: replacement)
        #expect(await renderedText.waitUntilValue(replacement))
        await fixture.view.waitForPendingComparisonRefreshForTesting {
            fixture.view.modifiedLayout.changes.isEmpty && fixture.view.inlineLayout.deletedViews.isEmpty
        }
        layoutPendingAnchorComparison(fixture.view)
    }

    @MainActor
    private func finishPendingAnchorComparison(_ view: SyntaxEditorComparisonView) async throws {
        let comparison = view.model
        let observation = withPortableContinuousObservation { _ in _ = comparison.changes }
        defer { observation.cancel() }
        let results = await observation.values { comparison.changes }
        let result = try #require(await results.waitUntil { $0 != nil })
        let changes = try #require(result)
        await view.waitForPendingComparisonRefreshForTesting {
            view.modifiedLayout.changes == changes
        }
        layoutPendingAnchorComparison(view)
    }

    @MainActor
    private func pendingAnchorVisibleReferenceLine(_ view: SyntaxEditorComparisonView) -> Int? {
        guard let changes = view.model.changes else { return nil }
        let clip = view.modifiedEditor.contentView
        for (index, native) in view.inlineLayout.deletedViews {
            guard changes.indices.contains(index) else { continue }
            var point = native.convert(clip.bounds.origin, from: clip)
            guard point.y >= native.bounds.minY, point.y < native.bounds.maxY else { continue }
            point.x = native.textContainerOrigin.x + 1
            let offset = native.characterIndexForInsertion(at: point)
            let line = (native.string as NSString).lineRange(for: NSRange(location: offset, length: 0))
            return changes[index].originalRange.location + line.location
        }
        return nil
    }

    @MainActor
    private func layoutPendingAnchorComparison(_ view: SyntaxEditorComparisonView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.modifiedEditor.textView.layoutVisibleViewport()
    }
}

@MainActor
private struct PendingAnchorFixture {
    let comparison: SyntaxEditorComparisonModel
    let view: SyntaxEditorComparisonView
    let window: NSWindow
    let gate: InlineAnchorComparisonGate
    let original: String
    let initialModified: String
}

private actor InlineAnchorComparisonGate {
    private struct Input: Hashable, Sendable {
        let original: String
        let modified: String
    }
    private var held: Set<Input> = []
    private var suspended: [Input: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [Input: CheckedContinuation<Void, Never>] = [:]

    func hold(original: String, modified: String) {
        held.insert(Input(original: original, modified: modified))
    }

    func waitIfHeld(original: String, modified: String) async {
        let input = Input(original: original, modified: modified)
        guard held.contains(input) else { return }
        await withCheckedContinuation { continuation in
            suspended[input] = continuation
            arrivals.removeValue(forKey: input)?.resume()
        }
    }

    func waitUntilSuspended(original: String, modified: String) async {
        let input = Input(original: original, modified: modified)
        guard suspended[input] == nil else { return }
        await withCheckedContinuation { arrivals[input] = $0 }
    }

    func release(original: String, modified: String) {
        let input = Input(original: original, modified: modified)
        held.remove(input)
        suspended.removeValue(forKey: input)?.resume()
    }

    func releaseAll() {
        held.removeAll()
        let continuations = Array(suspended.values)
        suspended.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
#endif
