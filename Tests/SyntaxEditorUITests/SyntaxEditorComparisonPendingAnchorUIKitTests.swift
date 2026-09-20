#if canImport(UIKit)
import UIKit
import ObservationBridge
import Testing
@testable import SyntaxEditorModel
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIUIKit

extension SyntaxEditorUITests {
    @Test("An edit below an inline deletion preserves its viewed reference line after comparison")
    @MainActor
    func iosComparisonPreservesReferenceAnchorAcrossPendingResult() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
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
    func iosComparisonRestoresPendingAnchorAfterGroupRenumbering() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
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
    func iosComparisonDiscardsPendingAnchorAfterScroll() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
        let replacement = fixture.initialModified + "new final line\n"
        try await holdPendingAnchorEdit(fixture, replacement: replacement)
        let editor = fixture.view.modifiedEditor
        editor.setContentOffset(CGPoint(x: editor.contentOffset.x, y: -editor.adjustedContentInset.top), animated: false)
        layoutPendingAnchorComparison(fixture.view)

        await fixture.gate.release(original: fixture.original, modified: replacement)
        try await finishPendingAnchorComparison(fixture.view)

        #expect(abs(editor.contentOffset.y + editor.adjustedContentInset.top) < 1)
        #expect(pendingAnchorVisibleReferenceLine(fixture.view) == nil)
    }

    @Test("Reference changes and model rebinding invalidate a pending inline reference anchor")
    @MainActor
    func iosComparisonDiscardsPendingAnchorAfterIdentityChange() async throws {
        for changesModel in [false, true] {
            let fixture = try await makeIOSPendingAnchorFixture()
            defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
            let before = try #require(pendingAnchorVisibleReferenceLine(fixture.view))
            let replacement = fixture.initialModified + "new final line\n"
            try await holdPendingAnchorEdit(fixture, replacement: replacement)

            if changesModel {
                // Identical reference contents/revision intentionally make the
                // comparison-model identity the only invalidation boundary.
                let next = SyntaxEditorComparisonModel(
                    originalText: fixture.original,
                    modified: SyntaxEditorModel(text: String(repeating: "new current heading\n", count: 200) + fixture.initialModified, language: .plainText)
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
            #expect(pendingAnchorVisibleReferenceLine(fixture.view) != before, "rebind: \(changesModel)")
        }
    }

    @Test("Successive pending edits keep the same reference position across cancelled calculations")
    @MainActor
    func iosComparisonPreservesAnchorAcrossSuccessivePendingEdits() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
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
    func iosComparisonPreservesAnchorWithoutPendingDelivery() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
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
        view.tintColorDidChange()
        try await finishPendingAnchorComparison(view)
        #expect(pendingAnchorVisibleReferenceLine(view) == before)
    }

    @Test("Pending and completed comparisons preserve a current line below a tall deletion")
    @MainActor
    func iosComparisonPreservesCurrentLineAcrossPendingResult() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
        let view = fixture.view
        let editor = view.modifiedEditor
        let line = try #require(view.viewport.lineFrame(150, in: editor))
        editor.setContentOffset(CGPoint(x: editor.contentOffset.x, y: line.minY - editor.adjustedContentInset.top), animated: false)
        layoutPendingAnchorComparison(view)
        let before = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: editor))
        let first = "inserted heading\n" + fixture.initialModified
        try await holdPendingAnchorEdit(fixture, replacement: first)
        let pending = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: editor))
        #expect(abs(pending - before - 1) < 0.2)
        let second = first + "new final line\n"
        try await holdPendingAnchorEdit(fixture, replacement: second)
        await fixture.gate.release(original: fixture.original, modified: second)
        try await finishPendingAnchorComparison(view)
        let ready = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: editor))
        #expect(abs(ready - before - 1) < 0.2)
    }

    @Test("Switching between inline and side-by-side retains the viewed reference line")
    @MainActor
    func iosComparisonPreservesReferenceLineAcrossPresentationChanges() async throws {
        let fixture = try await makeIOSPendingAnchorFixture()
        defer { fixture.window.isHidden = true; fixture.window.rootViewController = nil; Task { await fixture.gate.releaseAll() } }
        let view = fixture.view
        let before = try #require(pendingAnchorVisibleReferenceLine(view))
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let presentations = await delivery.values { view.model.presentation }
        view.model.presentation = .sideBySide
        #expect(await presentations.waitUntilValue(.sideBySide))
        await view.waitForPendingComparisonRefreshForTesting()
        let reference = view.originalEditor
        let y = reference.adjustedVisibleContentRect.minY
        let position = try #require(reference.closestPosition(to: CGPoint(x: reference.textContainerInset.left + reference.container.lineFragmentPadding + 1, y: y)))
        let offset = reference.offset(from: reference.beginningOfDocument, to: position)
        let visible = (reference.text as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
        #expect(visible == before)

        view.model.presentation = .inline
        #expect(await presentations.waitUntilValue(.inline))
        await view.waitForPendingComparisonRefreshForTesting()
        layoutPendingAnchorComparison(view)
        #expect(pendingAnchorVisibleReferenceLine(view) == before)
    }

    @MainActor
    private func makeIOSPendingAnchorFixture() async throws -> IOSPendingAnchorFixture {
        let prefix = (0..<20).map { "header \($0)\n" }.joined()
        let deleted = (0..<240).map { "deleted reference \($0)\n" }.joined()
        let suffix = (0..<240).map { "current tail \($0)\n" }.joined()
        let modified = prefix + suffix
        let original = prefix + deleted + suffix
        let gate = IOSInlineAnchorComparisonGate()
        let document = SyntaxEditorModel(text: modified, language: .plainText)
        let comparison = SyntaxEditorComparisonModel(originalText: original, modified: document) { original, modified in
            await gate.waitIfHeld(original: original, modified: modified)
            return try await EditorComparisonEngine.compare(original: original, modified: modified)
        }
        let calculation = try #require(comparison.calculation)
        await calculation.value
        #expect(comparison.changeCount == 1)
        let view = SyntaxEditorComparisonView(model: comparison)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 420))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        view.frame = controller.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        layoutPendingAnchorComparison(view)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        view.viewport.selectionDidChange(0)
        layoutPendingAnchorComparison(view)
        let reference = try #require(view.inlineLayout.deletedViews[0])
        let frame = reference.frame
        let editor = view.modifiedEditor
        editor.setContentOffset(CGPoint(x: editor.contentOffset.x, y: frame.minY + 1_200 - editor.adjustedContentInset.top), animated: false)
        layoutPendingAnchorComparison(view)
        return IOSPendingAnchorFixture(
            comparison: comparison, view: view, window: window, gate: gate,
            original: original, initialModified: modified
        )
    }

    @MainActor
    private func holdPendingAnchorEdit(_ fixture: IOSPendingAnchorFixture, replacement: String) async throws {
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
        let editor = view.modifiedEditor
        for (index, native) in view.inlineLayout.deletedViews {
            guard changes.indices.contains(index) else { continue }
            let y = editor.adjustedVisibleContentRect.minY
            guard y >= native.frame.minY, y < native.frame.maxY else { continue }
            let point = native.textInputView.convert(CGPoint(x: native.frame.minX + 1, y: y), from: editor)
            guard let position = native.closestPosition(to: point) else { continue }
            let offset = native.offset(from: native.beginningOfDocument, to: position)
            let line = (native.text as NSString).lineRange(for: NSRange(location: offset, length: 0))
            return changes[index].originalRange.location + line.location
        }
        return nil
    }

    @MainActor
    private func layoutPendingAnchorComparison(_ view: SyntaxEditorComparisonView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.modifiedEditor.layoutTextIfNeeded()
    }
}

@MainActor
private struct IOSPendingAnchorFixture {
    let comparison: SyntaxEditorComparisonModel
    let view: SyntaxEditorComparisonView
    let window: UIWindow
    let gate: IOSInlineAnchorComparisonGate
    let original: String
    let initialModified: String
}

private actor IOSInlineAnchorComparisonGate {
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
