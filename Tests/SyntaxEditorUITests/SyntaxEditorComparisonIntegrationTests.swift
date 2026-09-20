#if canImport(AppKit)
import AppKit
import ObservationBridge
import Testing
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit
@testable import SyntaxEditorModel

extension SyntaxEditorUITests {
    @Test("Side-by-side scrolling follows unchanged line correspondence after an insertion")
    @MainActor
    func macComparisonScrollsCorrespondingCommonLines() async throws {
        let lines = (0..<120).map { "common \($0)" }
        let source = lines.joined(separator: "\n")
        var originalLines = lines
        originalLines.insert(contentsOf: ["removed one", "removed two", "removed three"], at: 5)
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeComparisonIntegrationFixture(original: originalLines.joined(separator: "\n"), context: context)
        defer { window.orderOut(nil) }
        try await setComparisonPresentation(view, to: .sideBySide)
        let sourceLine = try #require(view.viewport.lineFrame(50, in: view.modifiedEditor))
        let y = sourceLine.minY + sourceLine.height * 0.35
        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)
        let originalY = view.originalEditor.textView.convert(
            view.originalEditor.contentView.bounds.origin,
            from: view.originalEditor.contentView
        ).y
        let originalLine = try #require(view.viewport.logicalLine(at: originalY, in: view.originalEditor))
        #expect(abs(originalLine - 53.35) < 0.2)
        #expect(view.modifiedEditor.textView.string == source)
    }

    @Test("Side-by-side scrolling interpolates the displayed height of a wrapped changed block")
    @MainActor
    func macComparisonScrollsWrappedChangedBlock() async throws {
        let prefix = (0..<30).map { "prefix \($0)\n" }.joined()
        let suffix = (0..<100).map { "suffix \($0)\n" }.joined()
        let source = prefix + "new content\n" + suffix
        let original = prefix + String(repeating: "old content ", count: 350) + "\n" + suffix
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeComparisonIntegrationFixture(original: original, context: context)
        defer { window.orderOut(nil) }
        try await setComparisonPresentation(view, to: .sideBySide)
        let change = try #require(view.model.changes?.first)
        let currentSpan = try #require(view.viewport.frame(change.modifiedRange, in: view.modifiedEditor))
        let originalSpan = try #require(view.viewport.frame(change.originalRange, in: view.originalEditor))
        #expect(originalSpan.height > currentSpan.height)
        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: currentSpan.midY))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)
        let originalY = view.originalEditor.textView.convert(
            view.originalEditor.contentView.bounds.origin,
            from: view.originalEditor.contentView
        ).y
        let currentOriginalSpan = try #require(view.viewport.frame(change.originalRange, in: view.originalEditor))
        #expect(abs(originalY - currentOriginalSpan.midY) <= 2)
    }

    @Test("Resizing wrapped comparisons keeps the visible common lines synchronized")
    @MainActor
    func macComparisonResynchronizesAfterWrappedResize() async throws {
        let prefix = (0..<10).map { "prefix \($0)\n" }.joined()
        let suffix = (0..<100).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + "new\n" + suffix, language: .plainText, lineWrappingEnabled: true)
        let original = prefix + String(repeating: "long reference text ", count: 25) + "\n" + suffix
        let (view, window) = try await makeComparisonIntegrationFixture(original: original, context: context, width: 900)
        defer { window.orderOut(nil) }
        try await setComparisonPresentation(view, to: .sideBySide)
        let line = try #require(view.viewport.lineFrame(50, in: view.modifiedEditor))
        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)

        window.setContentSize(NSSize(width: 440, height: 420))
        layoutComparisonIntegrationFixture(view)
        let currentY = view.modifiedEditor.textView.convert(view.modifiedEditor.contentView.bounds.origin, from: view.modifiedEditor.contentView).y
        let referenceY = view.originalEditor.textView.convert(view.originalEditor.contentView.bounds.origin, from: view.originalEditor.contentView).y
        let currentLine = try #require(view.viewport.logicalLine(at: currentY, in: view.modifiedEditor))
        let referenceLine = try #require(view.viewport.logicalLine(at: referenceY, in: view.originalEditor))
        #expect(abs(currentLine - referenceLine) < 0.2)
    }

    @Test("Completed comparisons resynchronize visible panes after edits above the viewport")
    @MainActor
    func macComparisonResynchronizesAfterComparisonRefresh() async throws {
        let source = (0..<140).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeComparisonIntegrationFixture(original: source, context: context)
        defer { window.orderOut(nil) }
        try await setComparisonPresentation(view, to: .sideBySide)
        let editor = view.modifiedEditor
        let line = try #require(view.viewport.lineFrame(70, in: view.modifiedEditor))
        editor.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
        editor.reflectScrolledClipView(editor.contentView)
        let revision = context.model.textRevision + 1
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let ready = await delivery.values {
            context.model.textRevision == revision && view.model.changeCount != nil
        }
        let retained = (0..<138).map { "common \($0)\n" }.joined()
        context.model.text = "inserted one\ninserted two\n" + retained
        #expect(await ready.waitUntilValue(true))
        await view.waitForPendingComparisonRefreshForTesting()
        let currentY = editor.textView.convert(editor.contentView.bounds.origin, from: editor.contentView).y
        let referenceY = view.originalEditor.textView.convert(view.originalEditor.contentView.bounds.origin, from: view.originalEditor.contentView).y
        let currentLine = try #require(view.viewport.logicalLine(at: currentY, in: view.modifiedEditor))
        let referenceLine = try #require(view.viewport.logicalLine(at: referenceY, in: view.originalEditor))
        #expect(abs(currentLine - 2 - referenceLine) < 0.2)
    }

    @Test("Comparison accessibility actions navigate changes without editing the document")
    @MainActor
    func macComparisonAccessibilityNavigation() async throws {
        let source = "first\nkeep\nlast\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeComparisonIntegrationFixture(original: "old first\nkeep\nold last\n", context: context)
        defer { window.orderOut(nil) }
        let ruler = try #require(view.modifiedEditor.verticalRulerView)
        let actions = try #require(ruler.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Next change", "Previous change"])
        let next = try #require(actions.first?.handler)
        let previous = try #require(actions.last?.handler)
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selection = await delivery.values { view.model.selectedChangeIndex }
        #expect(next())
        #expect(await selection.waitUntilValue(0))
        await view.waitForPendingComparisonRefreshForTesting()
        #expect(ruler.accessibilityValue() as? String == "Change 1 of 2")
        #expect(next())
        #expect(await selection.waitUntilValue(1))
        #expect(previous())
        #expect(await selection.waitUntilValue(0))
        #expect(context.model.text == source)
    }

    @Test("Find from a deleted block opens the full reference without changing current text or selection")
    @MainActor
    func macComparisonFindInDeletedText() async throws {
        let source = "before\nafter\n"
        let original = "before\nremoved words\nafter\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeComparisonIntegrationFixture(original: original, context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let parent = editor.superview
        editor.selectedRange = NSRange(location: 1, length: 3)
        let deleted = try #require(view.inlineLayout.deletedViews[0])
        window.makeFirstResponder(deleted)
        deleted.setSelectedRange(NSRange(location: 0, length: 7))
        let find = NSMenuItem()
        find.tag = NSTextFinder.Action.showFindInterface.rawValue

        deleted.performTextFinderAction(find)

        #expect(view.model.presentation == .sideBySide)
        #expect(!view.originalEditor.isHidden)
        #expect(view.originalEditor.isFindBarVisible)
        #expect(view.originalEditor.textView.string == original)
        #expect(!editor.isFindBarVisible)
        #expect(view.modifiedEditor === editor)
        #expect(editor.superview === parent)
        #expect(editor.selectedRange == NSRange(location: 1, length: 3))
        #expect(context.model.text == source)
    }

    @Test("Selecting a visible tall change from its ruler retains the viewport")
    @MainActor
    func macComparisonRulerSelectionKeepsVisibleHunk() async throws {
        let large = (0..<300).map { "changed line \($0)\n" }.joined()
        for kind in ["deletion", "insertion", "replacement"] {
            let source = kind == "deletion" ? "before\nafter\n" : large
            let original = kind == "deletion" ? "before\n" + large + "after\n"
                : kind == "replacement" ? (0..<300).map { "old line \($0)\n" }.joined() : ""
            let context = SyntaxEditorTestContext(text: source, language: .plainText)
            let (view, window) = try await makeComparisonIntegrationFixture(original: original, context: context)
            defer { window.orderOut(nil) }
            let editor = view.modifiedEditor
            let target: CGRect
            if kind == "deletion" {
                let deleted = try #require(view.inlineLayout.deletedViews[0])
                target = deleted.convert(deleted.bounds, to: editor.textView)
            } else {
                target = try #require(view.viewport.frame(NSRange(location: 0, length: source.utf16.count), in: view.modifiedEditor))
            }
            editor.contentView.scroll(to: NSPoint(x: editor.contentView.bounds.minX, y: target.midY))
            editor.reflectScrolledClipView(editor.contentView)
            layoutComparisonIntegrationFixture(view)
            let before = editor.contentView.bounds.origin
            let ruler = try #require(editor.verticalRulerView)
            let location = ruler.convert(NSPoint(x: ruler.ruleThickness - 4, y: ruler.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            let delivery = try #require(view.comparisonDeliveryForTesting)
            let selected = await delivery.values { view.model.selectedChangeIndex }
            ruler.mouseDown(with: event)
            #expect(await selected.waitUntilValue(0))
            await view.waitForPendingComparisonRefreshForTesting()
            #expect(editor.contentView.bounds.origin == before)
            #expect(context.model.text == source)
        }
    }

    @Test("An inline comparison retains its constrained bottom including trailing insets")
    @MainActor
    func macComparisonPreservesBottomContentInset() async throws {
        let suffix = (0..<30).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: "start\n" + suffix, language: .plainText, lineWrappingEnabled: true)
        let original = "start\n" + String(repeating: "removed text ", count: 300) + "\n" + suffix
        let (view, window) = try await makeComparisonIntegrationFixture(original: original, context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        editor.contentInsets.bottom = 70
        layoutComparisonIntegrationFixture(view)
        func bottomBounds() -> CGRect {
            var bounds = editor.contentView.bounds
            bounds.origin.y = editor.textView.bounds.maxY + editor.contentView.contentInsets.bottom
            return editor.contentView.constrainBoundsRect(bounds)
        }
        editor.contentView.scroll(to: bottomBounds().origin)
        editor.reflectScrolledClipView(editor.contentView)
        layoutComparisonIntegrationFixture(view)
        #expect(abs(editor.contentView.bounds.minY - bottomBounds().minY) < 1)
        let editorDelivery = try #require(editor.modelConfigurationDeliveryForTesting)
        let referenceDelivery = try #require(view.originalEditor.modelConfigurationDeliveryForTesting)
        let comparisonDelivery = try #require(view.comparisonConfigurationDeliveryForTesting)
        let expected = editor.resolvedBaseFont(fontSizeDelta: 4).pointSize
        let currentFont = await editorDelivery.values { editor.textView.font?.pointSize }
        let referenceFont = await referenceDelivery.values { view.originalEditor.textView.font?.pointSize }
        let configuration = await comparisonDelivery.values { context.model.fontSizeDelta }
        context.model.fontSizeDelta = 4
        #expect(await currentFont.waitUntilValue(expected))
        #expect(await referenceFont.waitUntilValue(expected))
        #expect(await configuration.waitUntilValue(4))
        await view.waitForPendingComparisonRefreshForTesting()
        layoutComparisonIntegrationFixture(view)
        #expect(abs(editor.contentView.bounds.minY - bottomBounds().minY) < 1)
    }

    @Test("Resizing preserves a reference viewport inside a deleted span")
    @MainActor
    func macComparisonPreservesReferenceViewportOnResize() async throws {
        let prefix = (0..<30).map { "prefix \($0)\n" }.joined()
        let removed = (0..<200).map { "removed \($0)\n" }.joined()
        let suffix = (0..<200).map { "suffix \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + suffix, language: .plainText)
        let (view, window) = try await makeComparisonIntegrationFixture(original: prefix + removed + suffix, context: context, width: 900)
        defer { window.orderOut(nil) }
        try await setComparisonPresentation(view, to: .sideBySide)
        let reference = view.originalEditor
        let line = try #require(view.viewport.lineFrame(130, in: view.originalEditor))
        reference.contentView.scroll(to: NSPoint(x: reference.contentView.bounds.minX, y: line.minY))
        reference.reflectScrolledClipView(reference.contentView)
        let beforeY = reference.textView.convert(reference.contentView.bounds.origin, from: reference.contentView).y
        let before = try #require(view.viewport.logicalLine(at: beforeY, in: view.originalEditor))

        window.setContentSize(NSSize(width: 720, height: 420))
        layoutComparisonIntegrationFixture(view)

        let afterY = reference.textView.convert(reference.contentView.bounds.origin, from: reference.contentView).y
        let after = try #require(view.viewport.logicalLine(at: afterY, in: view.originalEditor))
        #expect(abs(before - after) < 0.2)
    }

    @Test("Inline geometry changes retain the visible common line")
    @MainActor
    func macComparisonPreservesAnchorAcrossInlineGeometryChanges() async throws {
        for setting in ["width", "font", "wrapping"] {
            let common = (0..<120).map { "common \($0)\n" }.joined()
            let context = SyntaxEditorTestContext(text: "start\n" + common, language: .plainText, lineWrappingEnabled: true)
            let original = "start\n" + String(repeating: "deleted text ", count: 100) + "\n" + common
            let (view, window) = try await makeComparisonIntegrationFixture(original: original, context: context, width: 900)
            defer { window.orderOut(nil) }
            let editor = view.modifiedEditor
            let line = try #require(view.viewport.lineFrame(50, in: view.modifiedEditor))
            editor.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
            editor.reflectScrolledClipView(editor.contentView)
            layoutComparisonIntegrationFixture(view)
            let beforeY = editor.textView.convert(editor.contentView.bounds.origin, from: editor.contentView).y
            let before = try #require(view.viewport.logicalLine(at: beforeY, in: view.modifiedEditor))
            if setting == "width" {
                window.setContentSize(NSSize(width: 400, height: 420))
            } else {
                let editorDelivery = try #require(editor.modelConfigurationDeliveryForTesting)
                let comparisonDelivery = try #require(view.comparisonConfigurationDeliveryForTesting)
                if setting == "font" {
                    let expected = editor.resolvedBaseFont(fontSizeDelta: 4).pointSize
                    let font = await editorDelivery.values { editor.textView.font?.pointSize }
                    let configuration = await comparisonDelivery.values { context.model.fontSizeDelta }
                    context.model.fontSizeDelta = 4
                    #expect(await font.waitUntilValue(expected))
                    #expect(await configuration.waitUntilValue(4))
                } else {
                    let scrolling = await editorDelivery.values { editor.hasHorizontalScroller }
                    let configuration = await comparisonDelivery.values { context.model.lineWrappingEnabled }
                    context.model.lineWrappingEnabled = false
                    #expect(await scrolling.waitUntilValue(true))
                    #expect(await configuration.waitUntilValue(false))
                }
                await view.waitForPendingComparisonRefreshForTesting()
            }
            layoutComparisonIntegrationFixture(view)
            let afterY = editor.textView.convert(editor.contentView.bounds.origin, from: editor.contentView).y
            let after = try #require(view.viewport.logicalLine(at: afterY, in: view.modifiedEditor))
            #expect(abs(before - after) < 0.2, "setting: \(setting), before: \(before), after: \(after)")
        }
    }

    @Test("Changing font size inside an inline deletion preserves its visible reference line and selection")
    @MainActor
    func macComparisonPreservesDeletedAnchorAcrossFontChange() async throws {
        let prefix = "start\n"
        let removed = (0..<300).map { "removed line \($0)\n" }.joined()
        let source = prefix + "end\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeComparisonIntegrationFixture(original: prefix + removed + "end\n", context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let initial = try #require(view.inlineLayout.deletedViews[0])
        let blockFrame = initial.convert(initial.bounds, to: editor.textView)
        editor.contentView.scroll(to: NSPoint(x: 0, y: blockFrame.midY))
        editor.reflectScrolledClipView(editor.contentView)
        layoutComparisonIntegrationFixture(view)
        let deleted = try #require(view.inlineLayout.deletedViews[0])
        func visibleReferenceLine(in textView: NSTextView) -> Int {
            var point = textView.convert(editor.contentView.bounds.origin, from: editor.contentView)
            point.x = textView.textContainerOrigin.x + 1
            let offset = textView.characterIndexForInsertion(at: point)
            return prefix.utf16.count + (textView.string as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
        }
        let localLine = visibleReferenceLine(in: deleted) - prefix.utf16.count
        window.makeFirstResponder(deleted)
        deleted.setSelectedRange(NSRange(location: localLine + 2, length: 5))
        layoutComparisonIntegrationFixture(view)
        let before = visibleReferenceLine(in: deleted)
        try #require(before > prefix.utf16.count && before < prefix.utf16.count + removed.utf16.count)
        let selection = deleted.selectedRange()
        let referenceSelection = view.model.original.selectedRange
        let editorDelivery = try #require(editor.modelConfigurationDeliveryForTesting)
        let referenceDelivery = try #require(view.originalEditor.modelConfigurationDeliveryForTesting)
        let comparisonDelivery = try #require(view.comparisonConfigurationDeliveryForTesting)
        let expected = editor.resolvedBaseFont(fontSizeDelta: 4).pointSize
        let currentFont = await editorDelivery.values { editor.textView.font?.pointSize }
        let referenceFont = await referenceDelivery.values { view.originalEditor.textView.font?.pointSize }
        let configuration = await comparisonDelivery.values { context.model.fontSizeDelta }
        context.model.fontSizeDelta = 4
        #expect(await currentFont.waitUntilValue(expected))
        #expect(await referenceFont.waitUntilValue(expected))
        #expect(await configuration.waitUntilValue(4))
        await view.waitForPendingComparisonRefreshForTesting()
        layoutComparisonIntegrationFixture(view)
        let updated = try #require(view.inlineLayout.deletedViews[0])
        #expect(visibleReferenceLine(in: updated) == before)
        #expect(updated === deleted)
        #expect(updated.selectedRange() == selection)
        #expect(view.model.original.selectedRange == referenceSelection)
        #expect(window.firstResponder === updated)
        #expect(context.model.text == source)
    }

    @Test("An earlier deletion resizing preserves the visible line inside a later deletion")
    @MainActor
    func macComparisonPreservesLaterDeletedAnchorAcrossGeometryChanges() async throws {
        for setting in ["width", "font", "wrapping"] {
            let first = String(repeating: "wide deleted text ", count: 100) + "\n"
            let second = (0..<300).map { "later deleted line \($0)\n" }.joined()
            let context = SyntaxEditorTestContext(text: "start\nmiddle\nend\n", language: .plainText, lineWrappingEnabled: true)
            let (view, window) = try await makeComparisonIntegrationFixture(original: "start\n" + first + "middle\n" + second + "end\n", context: context, width: 900)
            defer { window.orderOut(nil) }
            #expect(view.model.changeCount == 2)
            let editor = view.modifiedEditor
            view.viewport.selectionDidChange(1)
            layoutComparisonIntegrationFixture(view)
            let deleted = try #require(view.inlineLayout.deletedViews[1])
            let frame = deleted.convert(deleted.bounds, to: editor.textView)
            editor.contentView.scroll(to: CGPoint(x: 0, y: frame.minY + 1200))
            editor.reflectScrolledClipView(editor.contentView)
            layoutComparisonIntegrationFixture(view)
            func visibleLine() throws -> Int {
                let current = try #require(view.inlineLayout.deletedViews[1])
                var point = current.convert(editor.contentView.bounds.origin, from: editor.contentView)
                point.x = current.textContainerOrigin.x + 1
                let offset = current.characterIndexForInsertion(at: point)
                return (current.string as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
            }
            let before = try visibleLine()
            try #require(before > 0)
            if setting == "width" {
                window.setContentSize(NSSize(width: 400, height: 420))
            } else {
                let delivery = try #require(editor.modelConfigurationDeliveryForTesting)
                let referenceDelivery = try #require(view.originalEditor.modelConfigurationDeliveryForTesting)
                let comparisonDelivery = try #require(view.comparisonConfigurationDeliveryForTesting)
                if setting == "font" {
                    let font = await delivery.values { editor.textView.font?.pointSize }
                    let referenceFont = await referenceDelivery.values { view.originalEditor.textView.font?.pointSize }
                    let configuration = await comparisonDelivery.values { context.model.fontSizeDelta }
                    let expected = editor.resolvedBaseFont(fontSizeDelta: 4).pointSize
                    context.model.fontSizeDelta = 4
                    #expect(await font.waitUntilValue(expected))
                    #expect(await referenceFont.waitUntilValue(expected))
                    #expect(await configuration.waitUntilValue(4))
                } else {
                    let wraps = await delivery.values { editor.textView.isHorizontallyResizable }
                    let referenceWraps = await referenceDelivery.values { view.originalEditor.textView.isHorizontallyResizable }
                    let configuration = await comparisonDelivery.values { context.model.lineWrappingEnabled }
                    context.model.lineWrappingEnabled = false
                    #expect(await wraps.waitUntilValue(true))
                    #expect(await referenceWraps.waitUntilValue(true))
                    #expect(await configuration.waitUntilValue(false))
                }
                await view.waitForPendingComparisonRefreshForTesting()
            }
            layoutComparisonIntegrationFixture(view)
            #expect(try visibleLine() == before, "setting: \(setting)")
        }
    }

    @MainActor
    private func makeComparisonIntegrationFixture(
        original: String,
        context: SyntaxEditorTestContext,
        width: CGFloat = 720
    ) async throws -> (SyntaxEditorComparisonView, NSWindow) {
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model)
        let calculation = try #require(model.calculation)
        await calculation.value
        _ = try #require(model.changeCount)
        let view = SyntaxEditorComparisonView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        layoutComparisonIntegrationFixture(view)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutComparisonIntegrationFixture(view)
        return (view, window)
    }

    @MainActor
    private func setComparisonPresentation(
        _ view: SyntaxEditorComparisonView,
        to presentation: SyntaxEditorComparisonModel.Presentation
    ) async throws {
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let presentations = await delivery.values { view.model.presentation }
        view.model.presentation = presentation
        #expect(await presentations.waitUntilValue(presentation))
        await view.waitForPendingComparisonRefreshForTesting {
            view.displayedPresentationForTesting == presentation
        }
        layoutComparisonIntegrationFixture(view)
    }

    @MainActor
    private func layoutComparisonIntegrationFixture(_ view: SyntaxEditorComparisonView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.modifiedEditor.textView.layoutVisibleViewport()
        if !view.originalEditor.isHidden {
            view.originalEditor.textView.layoutVisibleViewport()
        }
    }
}
#endif
