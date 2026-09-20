#if canImport(UIKit)
import Foundation
import ObservationBridge
import Testing
import UIKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIUIKit
@testable import SyntaxEditorModel

extension SyntaxEditorUITests {
    @Test("Original iOS selections project across recreated and multiple deletion views")
    @MainActor
    func iosComparisonProjectsOriginalSelectionAcrossPresentations() async throws {
        let original = "keep\nold A\nmiddle\nold B\nend\n"
        let context = SyntaxEditorTestContext(text: "keep\nmiddle\nend\n", language: .plainText)
        let (view, window) = try await makeIOSInlineComparison(original: original, context: context)
        defer { closeIOSInlineComparison(window) }
        let firstRange = (original as NSString).range(of: "old A")
        let secondRange = (original as NSString).range(of: "old B")
        try await setIOSInlineComparisonReferenceSelection(view, to: firstRange)
        let first = try #require(view.inlineLayout.deletedViews[0])
        await view.waitForPendingComparisonRefreshForTesting {
            first.selectedRange == NSRange(location: 0, length: 5)
        }
        #expect(first.selectedRange == NSRange(location: 0, length: 5))
        try await changeIOSInlineComparison(view, to: .sideBySide)
        #expect(view.inlineLayout.deletedViews.isEmpty)
        try await changeIOSInlineComparison(view, to: .inline)
        let recreated = try #require(view.inlineLayout.deletedViews[0])
        #expect(recreated !== first)
        #expect(recreated.selectedRange == NSRange(location: 0, length: 5))
        #expect(view.model.original.selectedRange == firstRange)
        try await setIOSInlineComparisonReferenceSelection(view, to: secondRange)
        let second = try #require(view.inlineLayout.deletedViews[1])
        await view.waitForPendingComparisonRefreshForTesting {
            recreated.selectedRange.length == 0 && second.selectedRange == NSRange(location: 0, length: 5)
        }
        #expect(recreated.selectedRange == NSRange(location: recreated.text.utf16.count, length: 0))
        #expect(second.selectedRange == NSRange(location: 0, length: 5))
        let spanning = NSRange(location: firstRange.location + 2, length: secondRange.upperBound - firstRange.location - 2)
        try await setIOSInlineComparisonReferenceSelection(view, to: spanning)
        await view.waitForPendingComparisonRefreshForTesting {
            recreated.selectedRange == NSRange(location: 2, length: recreated.text.utf16.count - 2)
                && second.selectedRange == NSRange(location: 0, length: 5)
        }
        #expect(recreated.selectedRange == NSRange(location: 2, length: recreated.text.utf16.count - 2))
        #expect(second.selectedRange == NSRange(location: 0, length: 5))
        #expect(view.model.original.selectedRange == spanning)
        #expect(context.model.text == "keep\nmiddle\nend\n")
    }

    @Test("A recycled iOS deletion view restores the original model selection")
    @MainActor
    func iosComparisonRestoresSelectionAfterViewportRecycling() async throws {
        let prefix = "start\n"
        let removed = (0..<300).map { "removed \($0)\n" }.joined()
        let suffix = (0..<120).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + suffix, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSInlineComparison(original: prefix + removed + suffix, context: context)
        defer { closeIOSInlineComparison(window) }
        let global = NSRange(location: prefix.utf16.count + 2, length: 4)
        try await setIOSInlineComparisonReferenceSelection(view, to: global)
        let first = try #require(view.inlineLayout.deletedViews[0])
        #expect(first.selectedRange == NSRange(location: 2, length: 4))
        let following = try #require(iosInlineLineFrame(80, in: view.modifiedEditor))
        setIOSInlineComparisonViewport(view.modifiedEditor, top: following.minY)
        layoutIOSInlineComparison(view)
        #expect(view.inlineLayout.deletedViews[0] == nil)
        #expect(view.model.original.selectedRange == global)
        setIOSInlineComparisonViewport(view.modifiedEditor, top: 0)
        layoutIOSInlineComparison(view)
        let recreated = try #require(view.inlineLayout.deletedViews[0])
        #expect(recreated !== first)
        #expect(recreated.selectedRange == NSRange(location: 2, length: 4))
        #expect(view.model.original.selectedRange == global)
    }

    @Test("Large wrapped iOS deletions use finite native views and forward native scrolling to the parent")
    @MainActor
    func iosComparisonVirtualizesDeletedTextAndForwardsScrolling() async throws {
        let prefix = "start\n"
        let removed = (0..<2_000).map { "removed line \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + "end\n", language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSInlineComparison(original: prefix + removed + "end\n", context: context)
        defer { closeIOSInlineComparison(window) }
        let editor = view.modifiedEditor
        let initial = try #require(view.inlineLayout.deletedViews[0])
        #expect(initial.text == removed)
        #expect(initial.frame.height <= editor.adjustedVisibleContentRect.height + 1)
        #expect(initial.isScrollEnabled && !initial.gestureRecognizerShouldBegin(initial.panGestureRecognizer))
        #expect(!initial.isEditable && initial.isSelectable)
        let manager = try #require(initial.textLayoutManager)
        let content = try #require(manager.textContentManager)
        var readyCount = 0
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable { readyCount += 1 }
            return true
        }
        #expect(readyCount > 0 && readyCount < 2_000)
        let firstLine = try #require(iosInlineLineFrame(0, in: view.modifiedEditor))
        setIOSInlineComparisonViewport(editor, top: firstLine.maxY + view.inlineLayout.additionalHeight * 0.5)
        layoutIOSInlineComparison(view)
        let middle = try #require(view.inlineLayout.deletedViews[0])
        #expect(middle.frame.height <= editor.adjustedVisibleContentRect.height + 1)
        #expect(middle.contentOffset.y > 0)
        let parentBefore = editor.contentOffset.y
        let nativeBefore = middle.contentOffset.y
        middle.scrollRectToVisible(CGRect(x: 0, y: nativeBefore + middle.bounds.height * 1.5, width: 10, height: 20), animated: false)
        #expect(editor.contentOffset.y > parentBefore)
        #expect(abs((editor.contentOffset.y - parentBefore) - (middle.contentOffset.y - nativeBefore)) <= 1)
        layoutIOSInlineComparison(view)
        let local = try visibleIOSDeletedLine(in: middle, editor: editor)
        let selected = NSRange(location: local + 2, length: 4)
        let global = NSRange(location: prefix.utf16.count + selected.location, length: selected.length)
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selection = await delivery.values { view.model.original.selectedRange }
        #expect(middle.becomeFirstResponder())
        middle.selectedRange = selected
        #expect(await selection.waitUntilValue(global))
        await settleIOSInlineComparison(view)
        #expect(middle.selectedRange == selected)
        #expect(middle.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        #expect(!editor.interactionShouldBegin(editor.editableTextInteraction, at: CGPoint(x: middle.frame.midX, y: middle.frame.midY)))
        #expect(editor.panGestureRecognizer.isEnabled)
        #expect(context.model.text == prefix + "end\n")
    }

    @Test("A zero iOS comparison viewport does not materialize deletion views")
    @MainActor
    func iosComparisonDefersDeletionViewsBeforeLayout() async throws {
        let original = (0..<200).map { "keep \($0)\nold \($0)\n" }.joined()
        let source = (0..<200).map { "keep \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model)
        let calculation = try #require(model.calculation)
        await calculation.value
        #expect(model.changeCount == 200)
        let view = SyntaxEditorComparisonView(model: model)
        #expect(view.bounds.isEmpty)
        #expect(view.inlineLayout.deletedViews.isEmpty)
        let window = attachIOSInlineComparison(view)
        defer { closeIOSInlineComparison(window) }
        await settleIOSInlineComparison(view)
        #expect(!view.inlineLayout.deletedViews.isEmpty)
        #expect(view.inlineLayout.deletedViews.count < 200)
        #expect(context.model.text == source)
    }

    @Test("Empty and EOF iOS deletions keep current text separate from reference layout")
    @MainActor
    func iosComparisonEmptyAndEOFDeletionGeometry() async throws {
        for (original, source) in [("removed", ""), ("removed\n", ""), ("keep\nremoved", "keep\n"), ("keep\nremoved\n", "keep\n")] {
            let context = SyntaxEditorTestContext(text: source, language: .plainText)
            let (view, window) = try await makeIOSInlineComparison(original: original, context: context)
            defer { closeIOSInlineComparison(window) }
            let deleted = try #require(view.inlineLayout.deletedViews[0])
            let caret = view.modifiedEditor.caretRect(for: SyntaxEditorView.TextPosition(offset: source.utf16.count))
            #expect(caret.height > 0)
            #expect(deleted.frame.height > 0)
            #expect(deleted.frame.maxY <= view.modifiedEditor.contentSize.height + 1)
            if source.isEmpty { #expect(deleted.frame.minY >= caret.maxY) }
            #expect(view.modifiedEditor.text.utf16.elementsEqual(source.utf16))
            #expect(context.model.text.utf16.elementsEqual(source.utf16))
            try await changeIOSInlineComparison(view, to: .changeMarkers)
            #expect(view.inlineLayout.deletedViews.isEmpty)
            #expect(view.inlineLayout.additionalHeight == 0)
            #expect(view.modifiedEditor.text.utf16.elementsEqual(source.utf16))
        }
    }

    @Test("UIKit inline blocks preserve exact UTF-16 text and full-document comment colors")
    @MainActor
    func iosInlinePreservesSourceAndSyntaxContext() async throws {
        let deletedText = "removed e\u{301}😀\r\n"
        let original = "/*\r\n" + deletedText + "*/\r\nlet x = 1\r\n"
        let source = "/*\r\n*/\r\nlet x = 1\r\n"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            comment: syntaxEditorUITestColor(hex: 0xA02090)
        )
        let context = SyntaxEditorTestContext(text: source, language: .swift, theme: theme)
        let (view, window) = try await makeIOSInlineComparison(original: original, context: context)
        defer { closeIOSInlineComparison(window) }
        let deleted = try #require(view.inlineLayout.deletedViews[0])
        #expect(deleted.text.utf16.elementsEqual(deletedText.utf16))
        #expect(view.modifiedEditor.text.utf16.elementsEqual(source.utf16))
        #expect(context.model.text.utf16.elementsEqual(source.utf16))
        #expect(deleted.textLayoutManager != nil)
        let color = try #require(deleted.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        #expect(syntaxEditorUITestColorsEqual(color, theme.comment))
    }

    @Test("UIKit inline geometry responds to width, wrapping, and fonts with bounded glyph surfaces")
    @MainActor
    func iosInlineReflowsDeletedText() async throws {
        let removed = String(repeating: "long deleted text ", count: 300) + "\n"
        let context = SyntaxEditorTestContext(text: "start\nend\n", language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSInlineComparison(original: "start\n" + removed + "end\n", context: context)
        defer { closeIOSInlineComparison(window) }
        let before = view.inlineLayout.additionalHeight
        view.frame.size.width = 360
        layoutIOSInlineComparison(view)
        #expect(view.inlineLayout.additionalHeight > before)
        let native = try #require(view.inlineLayout.deletedViews[0])
        #expect(native.frame.height <= view.modifiedEditor.adjustedVisibleContentRect.height + 1)
        for surface in view.modifiedEditor.textContentView.subviews.compactMap({ $0 as? SyntaxEditorView.TextLayoutFragmentView }) {
            #expect(surface.bounds.height < view.modifiedEditor.font.lineHeight * 3)
        }
        let currentDelivery = try #require(view.modifiedEditor.modelConfigurationDeliveryForTesting)
        let originalDelivery = try #require(view.originalEditor.modelConfigurationDeliveryForTesting)
        let currentWrap = await currentDelivery.values { view.modifiedEditor.model.lineWrappingEnabled }
        let originalWrap = await originalDelivery.values { view.originalEditor.model.lineWrappingEnabled }
        context.model.lineWrappingEnabled = false
        #expect(await currentWrap.waitUntilValue(false))
        #expect(await originalWrap.waitUntilValue(false))
        await settleIOSInlineComparison(view)
        #expect(view.inlineLayout.additionalHeight < before)
        #expect(view.modifiedEditor.contentSize.width > view.modifiedEditor.bounds.width)
        #expect(context.model.text == "start\nend\n")
    }

    @Test("UIKit inline reference styles update while preserving a native selection")
    @MainActor
    func iosInlineRestylesSelectedReference() async throws {
        let context = SyntaxEditorTestContext(text: "start\nend\n", language: .plainText)
        let (view, window) = try await makeIOSInlineComparison(original: "start\nremoved words\nend\n", context: context)
        defer { closeIOSInlineComparison(window) }
        let native = try #require(view.inlineLayout.deletedViews[0])
        #expect(native.becomeFirstResponder())
        native.selectedRange = NSRange(location: 2, length: 5)
        let selection = native.selectedRange
        await settleIOSInlineComparison(view)
        let reference = view.originalEditor
        let delivery = try #require(reference.modelConfigurationDeliveryForTesting)
        let font = await delivery.values { reference.font.pointSize }
        let expectedFont = reference.resolvedBaseFont(fontSizeDelta: 4).pointSize
        context.model.fontSizeDelta = 4
        #expect(await font.waitUntilValue(expectedFont))
        await settleIOSInlineComparison(view)
        let current = try #require(view.inlineLayout.deletedViews[0])
        #expect(current === native)
        let installed = try #require(current.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(installed.pointSize == expectedFont)
        #expect(current.selectedRange == selection)
        #expect(current.isFirstResponder)
        let theme = syntaxEditorUITestTheme(baseForeground: syntaxEditorUITestColor(hex: 0x883355))
        let themes = await delivery.values { reference.model.theme == theme }
        context.model.theme = theme
        #expect(await themes.waitUntilValue(true))
        await settleIOSInlineComparison(view)
        let color = try #require(current.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        #expect(syntaxEditorUITestColorsEqual(color, theme.baseForeground))
        #expect(current.selectedRange == selection)
    }

    @MainActor
    private func iosInlineLineFrame(_ index: Int, in editor: SyntaxEditorView) -> CGRect? {
        let offset = editor.lineMetrics.lineOffsets.lineStartOffset(at: index)
        return editor.caretRect(for: SyntaxEditorView.TextPosition(offset: offset))
    }

    @MainActor
    private func makeIOSInlineComparison(original: String, context: SyntaxEditorTestContext) async throws -> (SyntaxEditorComparisonView, UIWindow) {
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model)
        let calculation = try #require(model.calculation)
        await calculation.value
        _ = try #require(model.changeCount)
        let view = SyntaxEditorComparisonView(model: model)
        let window = attachIOSInlineComparison(view)
        await settleIOSInlineComparison(view)
        return (view, window)
    }

    @MainActor
    private func attachIOSInlineComparison(_ view: SyntaxEditorComparisonView) -> UIWindow {
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
        layoutIOSInlineComparison(view)
        return window
    }

    @MainActor
    private func closeIOSInlineComparison(_ window: UIWindow) {
        window.rootViewController?.view.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private func layoutIOSInlineComparison(_ view: SyntaxEditorComparisonView) {
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
    private func settleIOSInlineComparison(_ view: SyntaxEditorComparisonView) async {
        _ = await view.originalEditor.waitForPendingHighlightForTesting()
        _ = await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutIOSInlineComparison(view)
    }

    @MainActor
    private func changeIOSInlineComparison(_ view: SyntaxEditorComparisonView, to presentation: SyntaxEditorComparisonModel.Presentation) async throws {
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let values = await delivery.values { view.model.presentation }
        view.model.presentation = presentation
        #expect(await values.waitUntilValue(presentation))
        await view.waitForPendingComparisonRefreshForTesting {
            view.displayedPresentationForTesting == presentation
        }
        await settleIOSInlineComparison(view)
    }

    @MainActor
    private func setIOSInlineComparisonReferenceSelection(_ view: SyntaxEditorComparisonView, to range: NSRange) async throws {
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let values = await delivery.values { view.model.original.selectedRange }
        view.model.original.selectedRange = range
        #expect(await values.waitUntilValue(range))
        await settleIOSInlineComparison(view)
    }

    @MainActor
    private func setIOSInlineComparisonViewport(_ editor: SyntaxEditorView, top y: CGFloat) {
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

}
#endif
