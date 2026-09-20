#if canImport(AppKit)
import AppKit
import ObservationBridge
import Testing
@testable import SyntaxEditorModel
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit

extension SyntaxEditorUITests {
    @Test("Inline reference blocks preserve the exact modified document")
    @MainActor
    func appKitInlinePreservesExactModifiedText() async throws {
        let source = "let café = \"e\u{301}😀\"\r\nkeep\r\n"
        let original = "let café = \"e\u{301}😀\"\r\nremoved 😀\r\nkeep\r\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let fixture = try await makeInlineLayoutFixture(original: original, context: context)
        defer { fixture.close() }
        let deleted = try #require(fixture.view.inlineLayout.deletedViews[0])
        #expect(deleted.string.utf16.elementsEqual("removed 😀\r\n".utf16))
        #expect(!deleted.isEditable && deleted.isSelectable)
        #expect(deleted.textLayoutManager != nil)
        #expect(context.model.text.utf16.elementsEqual(source.utf16))
        #expect(fixture.view.modifiedEditor.textView.string.utf16.elementsEqual(source.utf16))
        #expect(context.model.textRevision == 0)
    }

    @Test("Inline syntax colors retain the complete reference's multiline comment context")
    @MainActor
    func appKitInlineUsesFullReferenceSyntaxContext() async throws {
        let source = "/*\n*/\nlet stable = 1\n"
        let original = "/*\nremoved body\n*/\nlet stable = 1\n"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            comment: syntaxEditorUITestColor(hex: 0xA02090)
        )
        let context = SyntaxEditorTestContext(text: source, language: .swift, theme: theme)
        let fixture = try await makeInlineLayoutFixture(original: original, context: context)
        defer { fixture.close() }
        let deleted = try #require(fixture.view.inlineLayout.deletedViews[0])
        #expect(deleted.string == "removed body\n")
        let color = try #require(deleted.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(syntaxEditorUITestColorsEqual(color, theme.comment))
        #expect(context.model.text == source)
    }

    @Test("Empty and EOF inline deletions retain a caret and fit the native document extent")
    @MainActor
    func appKitInlineEmptyAndEOFGeometry() async throws {
        for (original, source) in [
            ("removed", ""), ("removed\n", ""),
            ("keep\nremoved", "keep\n"), ("keep\nremoved\n", "keep\n"),
        ] {
            let context = SyntaxEditorTestContext(text: source, language: .plainText)
            let fixture = try await makeInlineLayoutFixture(original: original, context: context)
            defer { fixture.close() }
            let editor = fixture.view.modifiedEditor
            let deleted = try #require(fixture.view.inlineLayout.deletedViews[0])
            let caret = try #require(editor.textView.rectsForCharacterRange(NSRange(location: source.utf16.count, length: 0)).first)
            let frame = deleted.convert(deleted.bounds, to: editor.textView)
            #expect(caret.height > 0 && caret.minY.isFinite)
            #expect(frame.height > 0)
            #expect(frame.minY >= caret.maxY)
            #expect(frame.maxY <= editor.textView.bounds.maxY + 1)
            #expect(fixture.view.inlineLayout.additionalHeight > 0)
            #expect(editor.textView.string.utf16.elementsEqual(source.utf16))
        }
    }

    @Test("Inline measurements follow resized width, native wrapping, and applied fonts")
    @MainActor
    func appKitInlineMeasuresAppliedSettings() async throws {
        let original = "start\n" + String(repeating: "wide deleted text ", count: 35) + "\nend\n"
        let context = SyntaxEditorTestContext(text: "start\nend\n", language: .plainText, lineWrappingEnabled: true)
        let fixture = try await makeInlineLayoutFixture(original: original, context: context, width: 900)
        defer { fixture.close() }
        let wideHeight = try #require(fixture.view.inlineLayout.deletedViews[0]).frame.height
        fixture.window.setContentSize(NSSize(width: 320, height: 420))
        layoutInlineFixture(fixture.view)
        let narrow = try #require(fixture.view.inlineLayout.deletedViews[0])
        #expect(narrow.frame.height > wideHeight)
        let endRange = (context.model.text as NSString).range(of: "end")
        let endFrame = try #require(fixture.view.modifiedEditor.textView.rectsForCharacterRange(endRange).first)
        let narrowFrame = narrow.convert(narrow.bounds, to: fixture.view.modifiedEditor.textView)
        #expect(endFrame.minY >= narrowFrame.maxY)

        let modifiedDelivery = try #require(fixture.view.modifiedEditor.modelConfigurationDeliveryForTesting)
        let originalDelivery = try #require(fixture.view.originalEditor.modelConfigurationDeliveryForTesting)
        let modifiedFont = await modifiedDelivery.values { fixture.view.modifiedEditor.textView.font?.pointSize }
        let originalFont = await originalDelivery.values { fixture.view.originalEditor.textView.font?.pointSize }
        let expected = fixture.view.modifiedEditor.resolvedBaseFont(fontSizeDelta: 4).pointSize
        context.model.fontSizeDelta = 4
        #expect(await modifiedFont.waitUntilValue(expected))
        #expect(await originalFont.waitUntilValue(expected))
        await fixture.view.waitForPendingComparisonRefreshForTesting()
        layoutInlineFixture(fixture.view)
        let enlarged = try #require(fixture.view.inlineLayout.deletedViews[0])
        let installedFont = try #require(enlarged.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(installedFont.pointSize == expected)
        let wrappedHeight = enlarged.frame.height

        let modifiedWrapping = await modifiedDelivery.values { fixture.view.modifiedEditor.textView.isHorizontallyResizable }
        let originalWrapping = await originalDelivery.values { fixture.view.originalEditor.textView.isHorizontallyResizable }
        context.model.lineWrappingEnabled = false
        #expect(await modifiedWrapping.waitUntilValue(true))
        #expect(await originalWrapping.waitUntilValue(true))
        await fixture.view.waitForPendingComparisonRefreshForTesting()
        layoutInlineFixture(fixture.view)
        let unwrapped = try #require(fixture.view.inlineLayout.deletedViews[0])
        #expect(unwrapped.frame.height < wrappedHeight)
        #expect(fixture.view.inlineLayout.minimumTextWidth > fixture.view.modifiedEditor.contentView.bounds.width)
        #expect(context.model.text == "start\nend\n")
    }

    @Test("Large wrapped deletions keep glyph surfaces bounded and reference layout local")
    @MainActor
    func appKitInlineLargeDeletionUsesLocalLayout() async throws {
        let lineCount = 1_000
        let original = (0..<lineCount).map { "removed line \($0) " + String(repeating: "wide ", count: 20) + "\n" }.joined()
        let context = SyntaxEditorTestContext(text: "", language: .plainText, lineWrappingEnabled: true)
        let fixture = try await makeInlineLayoutFixture(original: original, context: context, width: 420)
        defer { fixture.close() }
        let current = fixture.view.modifiedEditor.textView
        let deleted = try #require(fixture.view.inlineLayout.deletedViews[0])
        let caret = try #require(current.rectsForCharacterRange(NSRange(location: 0, length: 0)).first)
        let surface = try #require(current.textContentView.subviews.compactMap {
            $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView
        }.first)
        #expect(surface.frame.height <= caret.height + 1)
        #expect(deleted.frame.height > fixture.view.modifiedEditor.contentView.bounds.height)
        #expect(deleted.frame.minY >= caret.maxY)
        #expect(deleted.string == original)
        #expect(current.string.isEmpty)
        let manager = try #require(deleted.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let viewport = try #require(manager.textViewportLayoutController.viewportRange)
        #expect(viewport.endLocation.compare(content.documentRange.endLocation) == .orderedAscending)
        var laidOut = 0
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        #expect(laidOut > 0 && laidOut < lineCount)
        #expect(!fixture.view.inlineLayout.visibleLineMarks.isEmpty)
    }

    @Test("A zero viewport does not create native deleted views")
    @MainActor
    func appKitInlineDefersViewsUntilViewportExists() async throws {
        let count = 200
        let original = (0..<count).map { "keep \($0)\nremoved \($0)\n" }.joined()
        let source = (0..<count).map { "keep \($0)\n" }.joined()
        let model = SyntaxEditorComparisonModel(originalText: original, modified: SyntaxEditorModel(text: source, language: .plainText))
        await model.calculation?.value
        #expect(model.changeCount == count)
        let view = SyntaxEditorComparisonView(model: model)
        #expect(view.bounds.isEmpty)
        #expect(view.inlineLayout.deletedViews.isEmpty)
        let fixture = InlineLayoutFixture(view: view, width: 720)
        defer { fixture.close() }
        await settleInlineFixture(view)
        #expect(!view.inlineLayout.deletedViews.isEmpty)
        #expect(view.inlineLayout.deletedViews.count < count)
        #expect(view.modifiedEditor.text == source)
    }

    @Test("Clearing inline presentation removes old native margins and document spacing")
    @MainActor
    func appKitInlineClearRemovesMargins() async throws {
        let source = "keep\n"
        let original = (0..<30).map { "removed \($0)\n" }.joined() + source
        let fixture = try await makeInlineLayoutFixture(original: original, context: SyntaxEditorTestContext(text: source, language: .plainText))
        defer { fixture.close() }
        let editor = fixture.view.modifiedEditor
        let oldFragments = editor.textView.textContentView.subviews.compactMap {
            ($0 as? SyntaxEditorTextInputView.TextLayoutFragmentView)?.layoutFragment
                as? SyntaxEditorTextInputView.TextLayoutFragment
        }
        #expect(oldFragments.contains { $0.comparisonTopMargin > 0 })
        fixture.view.model.presentation = .changeMarkers
        await fixture.view.waitForPendingComparisonRefreshForTesting {
            fixture.view.displayedPresentationForTesting == .changeMarkers
        }
        layoutInlineFixture(fixture.view)
        #expect(fixture.view.inlineLayout.deletedViews.isEmpty)
        #expect(fixture.view.inlineLayout.additionalHeight == 0)
        #expect(oldFragments.allSatisfy { $0.comparisonTopMargin == 0 && $0.comparisonBottomMargin == 0 })
        let first = try #require(editor.textView.rectsForCharacterRange(NSRange(location: 0, length: 1)).first)
        #expect(first.minY < first.height)
        #expect(editor.textView.bounds.height <= editor.contentView.bounds.height + 1)
        #expect(editor.text == source)
    }

    @Test("Reference selection projects into multiple blocks and survives recycling")
    @MainActor
    func appKitInlineProjectsSelectionAndRecyclesViews() async throws {
        let common = (0..<250).map { "common \($0)\n" }.joined()
        let source = "start\nmiddle\n" + common
        let original = "start\nold A\nmiddle\nold B\n" + common
        let fixture = try await makeInlineLayoutFixture(original: original, context: SyntaxEditorTestContext(text: source, language: .plainText))
        defer { fixture.close() }
        let a = (original as NSString).range(of: "old A\n")
        let b = (original as NSString).range(of: "old B\n")
        let first = try #require(fixture.view.inlineLayout.deletedViews[0])
        fixture.window.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 1, length: 3))
        #expect(fixture.view.model.original.selectedRange == NSRange(location: a.location + 1, length: 3))
        let currentSelection = fixture.view.modifiedEditor.selectedRange
        let spanning = NSRange(location: a.location + 1, length: b.upperBound - 1 - a.location - 1)
        fixture.view.model.original.selectedRange = spanning
        await fixture.view.waitForPendingComparisonRefreshForTesting {
            fixture.view.inlineLayout.deletedViews[0]?.selectedRange() == NSRange(location: 1, length: a.length - 1)
                && fixture.view.inlineLayout.deletedViews[1]?.selectedRange() == NSRange(location: 0, length: b.length - 1)
        }
        #expect(fixture.view.model.original.selectedRange == spanning)
        let editor = fixture.view.modifiedEditor
        fixture.window.makeFirstResponder(editor.textView)
        let farRange = (source as NSString).range(of: "common 120\n")
        let far = try #require(editor.textView.rectsForCharacterRange(farRange).first)
        editor.contentView.scroll(to: CGPoint(x: 0, y: far.minY))
        editor.reflectScrolledClipView(editor.contentView)
        layoutInlineFixture(fixture.view)
        #expect(fixture.view.inlineLayout.deletedViews.isEmpty)
        #expect(first.window == nil)
        editor.contentView.scroll(to: .zero)
        editor.reflectScrolledClipView(editor.contentView)
        layoutInlineFixture(fixture.view)
        let recreated = try #require(fixture.view.inlineLayout.deletedViews[0])
        #expect(recreated !== first)
        #expect(recreated.selectedRange() == NSRange(location: 1, length: a.length - 1))
        #expect(fixture.view.inlineLayout.deletedViews[1]?.selectedRange() == NSRange(location: 0, length: b.length - 1))
        #expect(fixture.view.model.original.selectedRange == spanning)
        #expect(editor.selectedRange == currentSelection)
    }

    @Test("Reference style invalidation reinstalls only intersecting visible blocks")
    @MainActor
    func appKitInlineLimitsReferenceStyleInstallation() async throws {
        let original = "first\nold A\nbetween\nold B\nlast\n"
        let source = "first\nbetween\nlast\n"
        let fixture = try await makeInlineLayoutFixture(original: original, context: SyntaxEditorTestContext(text: source, language: .plainText))
        defer { fixture.close() }
        let a = try #require(fixture.view.inlineLayout.deletedViews[0])
        let b = try #require(fixture.view.inlineLayout.deletedViews[1])
        let aStorage = try #require(a.textStorage)
        let bStorage = try #require(b.textStorage)
        let aEdits = InlineStorageEditRecorder(storage: aStorage)
        let bEdits = InlineStorageEditRecorder(storage: bStorage)
        defer { aEdits.stop(); bEdits.stop() }
        let reference = fixture.view.originalEditor
        let delivery = try #require(reference.modelDeliveryForTesting)
        let selected = await delivery.values { reference.textView.selectedRange() }
        let selection = NSRange(location: (original as NSString).range(of: "old A").location + 1, length: 2)
        fixture.view.model.original.selectedRange = selection
        #expect(await selected.waitUntilValue(selection))
        await fixture.view.waitForPendingComparisonRefreshForTesting {
            a.selectedRange() == NSRange(location: 1, length: 2)
        }
        layoutInlineFixture(fixture.view)
        #expect(aEdits.characterEdits == 0 && bEdits.characterEdits == 0)

        fixture.view.inlineLayout.invalidateReferenceStyles(in: [(original as NSString).range(of: "between")])
        layoutInlineFixture(fixture.view)
        #expect(aEdits.characterEdits == 0 && bEdits.characterEdits == 0)

        fixture.view.inlineLayout.invalidateReferenceStyles(in: [(original as NSString).range(of: "old A")])
        layoutInlineFixture(fixture.view)
        #expect(aEdits.characterEdits > 0)
        #expect(bEdits.characterEdits == 0)
        #expect(fixture.view.inlineLayout.deletedViews[0] === a)
        #expect(fixture.view.inlineLayout.deletedViews[1] === b)
        #expect(a.string == "old A\n" && b.string == "old B\n")
        #expect(fixture.view.modifiedEditor.text == source)
    }

    @Test("Focused reference blocks move with their paragraphs even outside the viewport")
    @MainActor
    func appKitInlineRepositionsFocusedOffscreenBlock() async throws {
        let source = "start\nmiddle\nend\n"
        let original = "start\n" + String(repeating: "wide deleted text ", count: 100)
            + "\nmiddle\nselected reference\nend\n"
        let fixture = try await makeInlineLayoutFixture(
            original: original,
            context: SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true),
            width: 900
        )
        defer { fixture.close() }
        let editor = fixture.view.modifiedEditor
        let deleted = try #require(fixture.view.inlineLayout.deletedViews[1])
        let before = deleted.convert(deleted.bounds, to: editor.textView)
        try #require(before.maxY < editor.contentView.bounds.maxY)
        fixture.window.makeFirstResponder(deleted)
        deleted.setSelectedRange(NSRange(location: 1, length: 4))
        let selection = fixture.view.model.original.selectedRange

        fixture.window.setContentSize(NSSize(width: 320, height: 420))
        layoutInlineFixture(fixture.view)

        let after = deleted.convert(deleted.bounds, to: editor.textView)
        let end = try #require(editor.textView.rectsForCharacterRange((source as NSString).range(of: "end")).first)
        #expect(after.minY > before.minY + 50)
        #expect(abs(after.maxY + 4 - end.minY) < 1)
        #expect(fixture.window.firstResponder === deleted)
        #expect(deleted.selectedRange() == NSRange(location: 1, length: 4))
        #expect(fixture.view.model.original.selectedRange == selection)
        let hit = editor.textView.textContentView.hitTest(CGPoint(x: before.minX + 10, y: before.midY))
        #expect(hit !== deleted && !(hit?.isDescendant(of: deleted) ?? false))
    }

    @Test("Inline measurement never reenters the active parent viewport delegate")
    @MainActor
    func appKitInlineDoesNotReenterParentViewport() async throws {
        let original = "start\n" + String(repeating: "wrapped deleted text ", count: 80) + "\nend\n"
        let context = SyntaxEditorTestContext(text: "start\nend\n", language: .plainText, lineWrappingEnabled: true)
        let fixture = try await makeInlineLayoutFixture(original: original, context: context, probesViewport: true)
        defer { fixture.close() }
        let probe = try #require(fixture.probe)
        fixture.window.setContentSize(NSSize(width: 320, height: 420))
        layoutInlineFixture(fixture.view)
        #expect(probe.layoutCalls > 0)
        #expect(probe.maximumDepth == 1)
        #expect(probe.depth == 0)
        #expect(!fixture.view.inlineLayout.deletedViews.isEmpty)
    }

    @Test("Inline base colors update while reference text is selected")
    @MainActor
    func appKitInlineUpdatesBaseColorWithReferenceSelection() async throws {
        let source = "before\nafter\n"
        let original = "before\nremoved body\nafter\n"
        let initialTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456)
        )
        let updatedTheme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0xA04080)
        )
        let context = SyntaxEditorTestContext(text: source, language: .plainText, theme: initialTheme)
        let fixture = try await makeInlineLayoutFixture(original: original, context: context)
        defer { fixture.close() }
        let view = fixture.view
        let reference = view.originalEditor
        let deleted = try #require(view.inlineLayout.deletedViews[0])
        let initialColor = try #require(deleted.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(syntaxEditorUITestColorsEqual(initialColor, initialTheme.baseForeground))

        let deletedRange = (original as NSString).range(of: "removed body\n")
        let selection = NSRange(location: deletedRange.location + 1, length: 4)
        reference.textView.setSelectedRange(selection)
        await view.waitForPendingComparisonRefreshForTesting {
            view.inlineLayout.deletedViews[0]?.selectedRange() == NSRange(location: 1, length: 4)
        }
        let modifiedSelection = view.modifiedEditor.selectedRange
        let modifiedDelivery = try #require(view.modifiedEditor.modelConfigurationDeliveryForTesting)
        let referenceDelivery = try #require(reference.modelConfigurationDeliveryForTesting)
        let modifiedBaseApplied = await modifiedDelivery.values {
            syntaxEditorUITestColorsEqual(view.modifiedEditor.baseForegroundColorForTesting(), updatedTheme.baseForeground)
        }
        let referenceBaseApplied = await referenceDelivery.values {
            syntaxEditorUITestColorsEqual(reference.baseForegroundColorForTesting(), updatedTheme.baseForeground)
        }

        context.model.theme = updatedTheme

        #expect(await modifiedBaseApplied.waitUntilValue(true))
        #expect(await referenceBaseApplied.waitUntilValue(true))
        #expect(reference.textView.selectedRange() == selection)
        await view.waitForPendingComparisonRefreshForTesting()
        layoutInlineFixture(view)
        let refreshed = try #require(view.inlineLayout.deletedViews[0])
        let color = try #require(refreshed.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(refreshed === deleted)
        #expect(syntaxEditorUITestColorsEqual(color, updatedTheme.baseForeground))
        #expect(refreshed.selectedRange() == NSRange(location: 1, length: 4))
        #expect(reference.textView.selectedRange() == selection)
        #expect(view.model.original.selectedRange == selection)
        #expect(view.modifiedEditor.selectedRange == modifiedSelection)
        #expect(view.modifiedEditor.text == source)
        #expect(reference.text == original)
    }

    @MainActor
    private func makeInlineLayoutFixture(
        original: String,
        context: SyntaxEditorTestContext,
        width: CGFloat = 720,
        probesViewport: Bool = false
    ) async throws -> InlineLayoutFixture {
        let comparison = SyntaxEditorComparisonModel(originalText: original, modified: context.model)
        await comparison.calculation?.value
        _ = try #require(comparison.changeCount)
        let fixture = InlineLayoutFixture(view: SyntaxEditorComparisonView(model: comparison), width: width, probesViewport: probesViewport)
        await settleInlineFixture(fixture.view)
        return fixture
    }

    @MainActor
    private func settleInlineFixture(_ view: SyntaxEditorComparisonView) async {
        layoutInlineFixture(view)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutInlineFixture(view)
    }

    @MainActor
    private func layoutInlineFixture(_ view: SyntaxEditorComparisonView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.modifiedEditor.textView.layoutVisibleViewport()
    }
}

@MainActor
private final class InlineLayoutFixture {
    let view: SyntaxEditorComparisonView
    let window: NSWindow
    let probe: InlineParentViewportProbe?

    init(view: SyntaxEditorComparisonView, width: CGFloat, probesViewport: Bool = false) {
        self.view = view
        let probe = probesViewport ? InlineParentViewportProbe(view.modifiedEditor.textView) : nil
        self.probe = probe
        if let probe { view.modifiedEditor.layoutManager.textViewportLayoutController.delegate = probe }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        if probe != nil {
            view.modifiedEditor.layoutManager.textViewportLayoutController.delegate = view.modifiedEditor.textView
        }
        window.orderOut(nil)
    }
}

@MainActor
private final class InlineParentViewportProbe: NSObject, @preconcurrency NSTextViewportLayoutControllerDelegate {
    private let real: SyntaxEditorTextInputView
    private(set) var depth = 0
    private(set) var maximumDepth = 0
    private(set) var layoutCalls = 0

    init(_ real: SyntaxEditorTextInputView) {
        self.real = real
        super.init()
    }

    func viewportBounds(for controller: NSTextViewportLayoutController) -> CGRect {
        real.viewportBounds(for: controller)
    }

    func textViewportLayoutController(_ controller: NSTextViewportLayoutController, configureRenderingSurfaceFor fragment: NSTextLayoutFragment) {
        real.textViewportLayoutController(controller, configureRenderingSurfaceFor: fragment)
    }

    func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController) {
        depth += 1
        layoutCalls += 1
        maximumDepth = max(maximumDepth, depth)
        real.textViewportLayoutControllerWillLayout(controller)
    }

    func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        defer { depth -= 1 }
        real.textViewportLayoutControllerDidLayout(controller)
    }
}

@MainActor
private final class InlineStorageEditRecorder: NSObject {
    private(set) var characterEdits = 0

    init(storage: NSTextStorage) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(record(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    @objc private func record(_ notification: Notification) {
        if let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) {
            characterEdits += 1
        }
    }

    func stop() { NotificationCenter.default.removeObserver(self) }
}
#endif
