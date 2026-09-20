#if canImport(UIKit)
import Foundation
import ObservationBridge
import Testing
import UIKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIUIKit
@testable import SyntaxEditorModel

extension SyntaxEditorUITests {
    @Test("An iOS zero-length deletion boundary does not fill the following common row")
    @MainActor
    func iosComparisonDoesNotFillCommonRowsAtDeletionBoundaries() async throws {
        let context = SyntaxEditorTestContext(text: "keep\n", language: .plainText)
        let (view, window) = try await makeIOSIntegrationComparison(original: "old\nkeep\n", context: context)
        defer { closeIOSIntegrationComparison(window) }
        let change = try #require(view.model.changes?.first)
        #expect(change.modifiedRange == NSRange(location: 0, length: 0))
        #expect(try iosComparisonBackgroundPixel(view) == [255, 255, 255, 255])
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selection = await delivery.values { view.model.selectedChangeIndex }
        #expect(view.model.selectNextChange())
        #expect(await selection.waitUntilValue(0))
        await settleIOSIntegrationComparison(view)
        #expect(try iosComparisonBackgroundPixel(view) == [255, 255, 255, 255])
    }

    @Test("iOS comparison font and width changes retain the visible common line", arguments: ["font", "width"])
    @MainActor
    func iosComparisonPreservesCommonAnchor(setting: String) async throws {
        let common = (0..<120).map { "common \($0)\n" }.joined()
        let source = "start\n" + common
        let original = "start\n" + String(repeating: "deleted text ", count: 100) + "\n" + common
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSIntegrationComparison(original: original, context: context)
        defer { closeIOSIntegrationComparison(window) }
        let editor = view.modifiedEditor
        let line = try #require(view.viewport.lineFrame(50, in: view.modifiedEditor))
        setIOSIntegrationComparisonViewport(editor, top: line.minY)
        layoutIOSIntegrationComparison(view)
        let before = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: view.modifiedEditor))
        if setting == "font" {
            try await changeIOSIntegrationComparisonFont(view, to: 4)
        } else {
            view.frame.size.width = 360
            layoutIOSIntegrationComparison(view)
        }
        let after = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: view.modifiedEditor))
        #expect(abs(before - after) < 0.2)
        #expect(context.model.text == source)
    }

    @Test("An iOS font change inside deleted text preserves the original line and selection")
    @MainActor
    func iosComparisonPreservesDeletedAnchorAcrossFontChange() async throws {
        let prefix = "start\n"
        let removed = (0..<300).map { "removed line \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + "end\n", language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSIntegrationComparison(original: prefix + removed + "end\n", context: context)
        defer { closeIOSIntegrationComparison(window) }
        let editor = view.modifiedEditor
        let first = try #require(view.viewport.lineFrame(0, in: view.modifiedEditor))
        setIOSIntegrationComparisonViewport(editor, top: first.maxY + view.inlineLayout.additionalHeight * 0.5)
        layoutIOSIntegrationComparison(view)
        let deleted = try #require(view.inlineLayout.deletedViews[0])
        let local = try visibleIOSDeletedLine(in: deleted, editor: editor)
        let global = NSRange(location: prefix.utf16.count + local + 2, length: 5)
        try await setIOSIntegrationComparisonReferenceSelection(view, to: global)
        #expect(deleted.becomeFirstResponder())
        let before = try visibleIOSDeletedLine(in: deleted, editor: editor)
        let selection = deleted.selectedRange
        try await changeIOSIntegrationComparisonFont(view, to: 4)
        let updated = try #require(view.inlineLayout.deletedViews[0])
        let after = try visibleIOSDeletedLine(in: updated, editor: editor)
        #expect(after == before)
        #expect(updated === deleted)
        #expect(updated.selectedRange == selection)
        #expect(view.model.original.selectedRange == global)
        #expect(updated.isFirstResponder)
    }

    @Test("Font changes at the native iOS bottom retain trailing content insets")
    @MainActor
    func iosComparisonPreservesBottomAnchorWithInsets() async throws {
        let common = (0..<150).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: common, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSIntegrationComparison(original: "deleted\n" + common, context: context)
        defer { closeIOSIntegrationComparison(window) }
        let editor = view.modifiedEditor
        editor.contentInsetAdjustmentBehavior = .never
        editor.contentInset = UIEdgeInsets(top: 24, left: 0, bottom: 80, right: 0)
        layoutIOSIntegrationComparison(view)
        editor.setContentOffset(iOSMaximumContentOffset(editor), animated: false)
        layoutIOSIntegrationComparison(view)
        #expect(abs(editor.contentOffset.y - iOSMaximumContentOffset(editor).y) <= 1)
        try await changeIOSIntegrationComparisonFont(view, to: 4)
        #expect(abs(editor.contentOffset.y - iOSMaximumContentOffset(editor).y) <= 1)
        #expect(editor.contentInset.bottom == 80)
    }

    @Test("iOS side-by-side common-line synchronization follows either active pane")
    @MainActor
    func iosComparisonSynchronizesCommonLinesBothDirections() async throws {
        let lines = (0..<140).map { "common \($0)" }
        let source = lines.joined(separator: "\n")
        var reference = lines
        reference.insert(contentsOf: ["removed one", "removed two", "removed three"], at: 5)
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeIOSIntegrationComparison(original: reference.joined(separator: "\n"), context: context)
        defer { closeIOSIntegrationComparison(window) }
        try await changeIOSIntegrationComparison(view, to: .sideBySide)
        let currentLine = try #require(view.viewport.lineFrame(50, in: view.modifiedEditor))
        setIOSIntegrationComparisonViewport(view.modifiedEditor, top: currentLine.minY + currentLine.height * 0.35)
        layoutIOSIntegrationComparison(view)
        let current = try #require(view.viewport.logicalLine(at: view.modifiedEditor.adjustedVisibleContentRect.minY, in: view.modifiedEditor))
        let original = try #require(view.viewport.logicalLine(at: view.originalEditor.adjustedVisibleContentRect.minY, in: view.originalEditor))
        #expect(abs(original - current - 3) < 0.2)
        let referenceLine = try #require(view.viewport.lineFrame(80, in: view.originalEditor))
        setIOSIntegrationComparisonViewport(view.originalEditor, top: referenceLine.minY + referenceLine.height * 0.4)
        let active = try #require(view.viewport.logicalLine(at: view.originalEditor.adjustedVisibleContentRect.minY, in: view.originalEditor))
        layoutIOSIntegrationComparison(view)
        let retained = try #require(view.viewport.logicalLine(at: view.originalEditor.adjustedVisibleContentRect.minY, in: view.originalEditor))
        let following = try #require(view.viewport.logicalLine(at: view.modifiedEditor.adjustedVisibleContentRect.minY, in: view.modifiedEditor))
        #expect(abs(retained - active) < 0.2)
        #expect(abs(retained - following - 3) < 0.2)
    }

    @Test("iOS side-by-side changed blocks synchronize their laid-out heights")
    @MainActor
    func iosComparisonSynchronizesWrappedChangedBlock() async throws {
        let prefix = (0..<30).map { "prefix \($0)\n" }.joined()
        let suffix = (0..<100).map { "suffix \($0)\n" }.joined()
        let source = prefix + "new content\n" + suffix
        let original = prefix + String(repeating: "old content ", count: 350) + "\n" + suffix
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSIntegrationComparison(original: original, context: context)
        defer { closeIOSIntegrationComparison(window) }
        try await changeIOSIntegrationComparison(view, to: .sideBySide)
        let change = try #require(view.model.changes?.first)
        let current = try #require(view.viewport.frame(change.modifiedRange, in: view.modifiedEditor))
        let reference = try #require(view.viewport.frame(change.originalRange, in: view.originalEditor))
        #expect(reference.height > current.height)
        setIOSIntegrationComparisonViewport(view.modifiedEditor, top: current.midY)
        layoutIOSIntegrationComparison(view)
        let updatedReference = try #require(view.viewport.frame(change.originalRange, in: view.originalEditor))
        let actualCurrent = view.modifiedEditor.adjustedVisibleContentRect.minY
        let currentFrame = try #require(view.viewport.frame(change.modifiedRange, in: view.modifiedEditor))
        #expect(abs(actualCurrent - current.midY) <= 1 / view.traitCollection.displayScale)
        let expected = updatedReference.minY + (actualCurrent - currentFrame.minY) / currentFrame.height * updatedReference.height
        #expect(abs(view.originalEditor.adjustedVisibleContentRect.minY - expected) <= 2)
    }

    @Test("Find from iOS deleted text targets the full reference without replacing the current editor")
    @MainActor
    func iosComparisonFindTargetsFullReference() async throws {
        let source = "before\nafter\n"
        let original = "before\nremoved words\nafter\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeIOSIntegrationComparison(original: original, context: context)
        defer { closeIOSIntegrationComparison(window) }
        let editor = view.modifiedEditor
        editor.selectedRange = NSRange(location: 1, length: 3)
        let global = (original as NSString).range(of: "removed")
        try await setIOSIntegrationComparisonReferenceSelection(view, to: global)
        let deleted = try #require(view.inlineLayout.deletedViews[0])
        #expect(deleted.becomeFirstResponder())
        deleted.find(nil)
        layoutIOSIntegrationComparison(view)
        #expect(view.model.presentation == .sideBySide)
        #expect(!view.originalEditor.isHidden)
        #expect(!deleted.isFirstResponder)
        #expect(!editor.isFirstResponder)
        #expect(view.originalEditor.text == original)
        #expect(view.originalEditor.selectedRange == global)
        #expect(view.originalEditor.findInteraction?.isFindNavigatorVisible == true)
        #expect(view.modifiedEditor === editor)
        #expect(editor.selectedRange == NSRange(location: 1, length: 3))
        #expect(context.model.text == source)
        try await changeIOSIntegrationComparison(view, to: .inline)
        #expect(view.originalEditor.findInteraction?.isFindNavigatorVisible != true)
        #expect(editor.isFirstResponder)
    }

    @Test("Selecting an iOS inline replacement already visible on its modified side does not jump")
    @MainActor
    func iosComparisonKeepsVisibleReplacementPosition() async throws {
        let original = "start\n" + (0..<300).map { "old \($0)\n" }.joined() + "end\n"
        let source = "start\n" + (0..<300).map { "new \($0)\n" }.joined() + "end\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSIntegrationComparison(original: original, context: context)
        defer { closeIOSIntegrationComparison(window) }
        #expect(view.model.changeCount == 1)
        let editor = view.modifiedEditor
        let line = try #require(view.viewport.lineFrame(121, in: view.modifiedEditor))
        setIOSIntegrationComparisonViewport(editor, top: line.minY)
        layoutIOSIntegrationComparison(view)
        let before = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: view.modifiedEditor))
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selection = await delivery.values { view.model.selectedChangeIndex }
        #expect(view.model.selectNextChange())
        #expect(await selection.waitUntilValue(0))
        await settleIOSIntegrationComparison(view)
        let after = try #require(view.viewport.logicalLine(at: editor.adjustedVisibleContentRect.minY, in: view.modifiedEditor))
        #expect(abs(after - before) < 0.2)
    }

    @Test("Model text refresh preserves an unchanged selection's reading viewport on UIKit")
    @MainActor
    func iosModelTextRefreshPreservesReadingViewport() async throws {
        let source = (0..<200).map { "line \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let editor = SyntaxEditorView(testContext: context)
        layoutIOSEditorView(editor)
        editor.contentOffset = CGPoint(x: 0, y: 900)
        editor.layoutIfNeeded()
        let before = editor.contentOffset.y
        let delivery = try #require(editor.modelDeliveryForTesting)
        let revisions = await delivery.values { editor.lastAppliedDocumentRevision }
        context.model.text = source + "final line\n"
        #expect(await revisions.waitUntilValue(context.model.textRevision))
        editor.layoutIfNeeded()
        #expect(editor.selectedRange == NSRange(location: 0, length: 0))
        #expect(abs(editor.contentOffset.y - before) <= 1)
        let selections = await delivery.values { editor.selectedRange }
        let end = NSRange(location: context.model.text.utf16.count, length: 0)
        context.model.selectedRange = end
        #expect(await selections.waitUntilValue(end))
        editor.layoutIfNeeded()
        #expect(editor.contentOffset.y > before)
    }

    @Test("UIKit accessibility change actions reveal offscreen changes without changing text selection")
    @MainActor
    func iosComparisonAccessibilityRevealsChanges() async throws {
        let lines = (0..<180).map { "common \($0)\n" }
        var original = lines
        original[5] = "old first\n"
        original[160] = "old last\n"
        let context = SyntaxEditorTestContext(text: lines.joined(), language: .plainText)
        let (view, window) = try await makeIOSIntegrationComparison(original: original.joined(), context: context)
        defer { closeIOSIntegrationComparison(window) }
        let actions = try #require(view.modifiedLayout.rulerView.accessibilityCustomActions)
        #expect(actions.map(\.name) == ["Next change", "Previous change"])
        let next = try #require(actions[0].actionHandler)
        let previous = try #require(actions[1].actionHandler)
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selected = await delivery.values { view.model.selectedChangeIndex }
        let textSelection = view.modifiedEditor.selectedRange
        #expect(next(actions[0]))
        #expect(await selected.waitUntilValue(0))
        await settleIOSIntegrationComparison(view)
        #expect(next(actions[0]))
        #expect(await selected.waitUntilValue(1))
        await settleIOSIntegrationComparison(view)
        let change = try #require(view.model.changes?.last)
        let target = try #require(view.viewport.frame(change.modifiedRange, in: view.modifiedEditor))
        let visible = view.modifiedEditor.adjustedVisibleContentRect
        #expect(target.minY < visible.maxY && target.maxY > visible.minY)
        #expect(view.modifiedLayout.rulerView.accessibilityValue == "Change 2 of 2")
        #expect(view.modifiedEditor.selectedRange == textSelection)
        #expect(previous(actions[1]))
        #expect(await selected.waitUntilValue(0))
        await settleIOSIntegrationComparison(view)
        #expect(view.modifiedEditor.contentOffset.y < visible.minY)
        #expect(context.model.text == lines.joined())
    }

    @Test("UIKit comparison layout does not suppress explicit horizontal scroll requests")
    @MainActor
    func iosComparisonAllowsExplicitHorizontalScrolling() async throws {
        let source = (0..<120).map { "line \($0) " + String(repeating: "long content ", count: 20) + "\n" }.joined()
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: false)
        let (view, window) = try await makeIOSIntegrationComparison(original: source, context: context)
        defer { closeIOSIntegrationComparison(window) }
        let editor = view.modifiedEditor
        for presentation: SyntaxEditorComparisonModel.Presentation in [.changeMarkers, .inline, .sideBySide] {
            try await changeIOSIntegrationComparison(view, to: presentation)
            editor.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            layoutIOSIntegrationComparison(view)
            editor.setContentOffset(CGPoint(x: 240, y: editor.contentOffset.y), animated: false)
            #expect(abs(editor.contentOffset.x - 240) <= 1, "presentation: \(presentation)")
            layoutIOSIntegrationComparison(view)
            editor.contentOffset = CGPoint(x: 320, y: editor.contentOffset.y)
            #expect(abs(editor.contentOffset.x - 320) <= 1, "presentation: \(presentation)")
        }
    }

    @MainActor
    private func makeIOSIntegrationComparison(original: String, context: SyntaxEditorTestContext) async throws -> (SyntaxEditorComparisonView, UIWindow) {
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model)
        let calculation = try #require(model.calculation)
        await calculation.value
        _ = try #require(model.changeCount)
        let view = SyntaxEditorComparisonView(model: model)
        let window = attachIOSIntegrationComparison(view)
        await settleIOSIntegrationComparison(view)
        return (view, window)
    }

    @MainActor
    private func attachIOSIntegrationComparison(_ view: SyntaxEditorComparisonView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 720, height: 420))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        view.frame = controller.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        window.updateTraitsIfNeeded()
        layoutIOSIntegrationComparison(view)
        return window
    }

    @MainActor
    private func closeIOSIntegrationComparison(_ window: UIWindow) {
        window.rootViewController?.view.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private func layoutIOSIntegrationComparison(_ view: SyntaxEditorComparisonView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.modifiedEditor.setNeedsLayout()
        view.modifiedEditor.layoutIfNeeded()
        if !view.originalEditor.isHidden {
            view.originalEditor.setNeedsLayout()
            view.originalEditor.layoutIfNeeded()
        }
    }

    @MainActor
    private func settleIOSIntegrationComparison(_ view: SyntaxEditorComparisonView) async {
        _ = await view.originalEditor.waitForPendingHighlightForTesting()
        _ = await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutIOSIntegrationComparison(view)
    }

    @MainActor
    private func changeIOSIntegrationComparison(_ view: SyntaxEditorComparisonView, to presentation: SyntaxEditorComparisonModel.Presentation) async throws {
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let values = await delivery.values { view.model.presentation }
        view.model.presentation = presentation
        #expect(await values.waitUntilValue(presentation))
        await view.waitForPendingComparisonRefreshForTesting {
            view.displayedPresentationForTesting == presentation
        }
        await settleIOSIntegrationComparison(view)
    }

    @MainActor
    private func setIOSIntegrationComparisonReferenceSelection(_ view: SyntaxEditorComparisonView, to range: NSRange) async throws {
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let values = await delivery.values { view.model.original.selectedRange }
        view.model.original.selectedRange = range
        #expect(await values.waitUntilValue(range))
        await settleIOSIntegrationComparison(view)
    }

    @MainActor
    private func changeIOSIntegrationComparisonFont(_ view: SyntaxEditorComparisonView, to delta: Int) async throws {
        let editor = view.modifiedEditor
        let currentDelivery = try #require(editor.modelConfigurationDeliveryForTesting)
        let referenceDelivery = try #require(view.originalEditor.modelConfigurationDeliveryForTesting)
        let comparisonDelivery = try #require(view.comparisonConfigurationDeliveryForTesting)
        let expected = editor.resolvedBaseFont(fontSizeDelta: delta).pointSize
        let currentFont = await currentDelivery.values { (editor.typingAttributes[.font] as? UIFont)?.pointSize }
        let referenceFont = await referenceDelivery.values { (view.originalEditor.typingAttributes[.font] as? UIFont)?.pointSize }
        let configuration = await comparisonDelivery.values { view.model.modified.fontSizeDelta }
        view.model.modified.fontSizeDelta = delta
        #expect(await currentFont.waitUntilValue(expected))
        #expect(await referenceFont.waitUntilValue(expected))
        #expect(await configuration.waitUntilValue(delta))
        await settleIOSIntegrationComparison(view)
    }

    @MainActor
    private func setIOSIntegrationComparisonViewport(_ editor: SyntaxEditorView, top y: CGFloat) {
        editor.setContentOffset(CGPoint(x: editor.contentOffset.x, y: y - editor.adjustedContentInset.top), animated: false)
    }

    @MainActor
    private func visibleIOSDeletedLine(in view: UITextView, editor: SyntaxEditorView) throws -> Int {
        let point = view.textInputView.convert(
            CGPoint(x: view.frame.minX + 1, y: editor.adjustedVisibleContentRect.minY), from: editor
        )
        let position = try #require(view.closestPosition(to: point))
        let offset = view.offset(from: view.beginningOfDocument, to: position)
        return (view.text as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
    }

    @MainActor
    private func iosComparisonBackgroundPixel(_ view: SyntaxEditorComparisonView) throws -> [UInt8] {
        let fragments = view.modifiedEditor.textContentView.subviews.compactMap {
            ($0 as? SyntaxEditorView.TextLayoutFragmentView)?.layoutFragment
        }
        let fragment = try #require(fragments.first)
        let line = try #require(fragment.textLineFragments.first)
        let origin = CGPoint(x: fragment.layoutFragmentFrame.minX, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var pixel: [UInt8] = [255, 255, 255, 255]
        try pixel.withUnsafeMutableBytes { bytes in
            let bitmap = unsafe CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            let graphics = try #require(bitmap)
            UIGraphicsPushContext(graphics)
            defer { UIGraphicsPopContext() }
            view.modifiedLayout.drawBackground(for: fragment, surfaceOrigin: origin, in: rect, dirtyRect: rect)
        }
        return pixel
    }
}
#endif
