#if canImport(AppKit)
import AppKit
import ObservationBridge
import Testing
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit
@testable import SyntaxEditorModel

extension SyntaxEditorUITests {
    @Test("Comparison presentations preserve the current editor, exact text, selection, and undo")
    @MainActor
    func macComparisonPresentationPreservesEditing() async throws {
        let source = "let café = \"e\u{301}😀\"\r\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: "old\r\n", context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let textView = editor.textView
        let parent = try #require(editor.superview)
        window.makeFirstResponder(textView)
        let undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        let revision = context.model.textRevision + 1
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let rendered = await delivery.values {
            context.model.textRevision == revision && view.model.changeCount != nil
        }
        let end = NSRange(location: source.utf16.count, length: 0)
        textView.setSelectedRange(end)
        undoManager.beginUndoGrouping()
        textView.insertText("!", replacementRange: end)
        textView.breakUndoCoalescing()
        undoManager.endUndoGrouping()
        #expect(await rendered.waitUntilValue(true))
        await view.waitForPendingComparisonRefreshForTesting()
        let selection = textView.selectedRange()

        for presentation: SyntaxEditorComparisonModel.Presentation in [.changeMarkers, .sideBySide, .inline] {
            try await changeMacComparison(view, to: presentation)
            #expect(view.modifiedEditor === editor)
            #expect(view.modifiedEditor.textView === textView)
            #expect(editor.superview === parent)
            #expect(textView.string.utf16.elementsEqual((source + "!").utf16))
            #expect(context.model.text.utf16.elementsEqual((source + "!").utf16))
            #expect(textView.selectedRange() == selection)
            #expect(undoManager.canUndo)
            #expect(window.firstResponder === textView)
        }
        undoManager.undo()
        #expect(textView.string.utf16.elementsEqual(source.utf16))
        #expect(context.model.text.utf16.elementsEqual(source.utf16))
        undoManager.redo()
        #expect(textView.string.utf16.elementsEqual((source + "!").utf16))
    }

    @Test("Comparison presentation changes preserve active marked text until IME commit")
    @MainActor
    func macComparisonPresentationPreservesMarkedText() async throws {
        let source = "current: "
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: "reference", context: context)
        defer { window.orderOut(nil) }
        let textView = view.modifiedEditor.textView
        window.makeFirstResponder(textView)
        let revision = context.model.textRevision + 1
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let rendered = await delivery.values {
            context.model.textRevision == revision && view.model.changeCount != nil
        }
        textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(await rendered.waitUntilValue(true))
        await view.waitForPendingComparisonRefreshForTesting()
        let marked = textView.markedRange()
        let selected = textView.selectedRange()

        for presentation: SyntaxEditorComparisonModel.Presentation in [.sideBySide, .changeMarkers, .inline] {
            try await changeMacComparison(view, to: presentation)
            #expect(textView.hasMarkedText())
            #expect(textView.markedRange() == marked)
            #expect(textView.selectedRange() == selected)
            #expect(textView.string == source + "かな")
            #expect(window.firstResponder === textView)
        }
        let referenceRevision = view.model.original.textRevision + 1
        let referenceChanged = await delivery.values {
            view.model.original.textRevision == referenceRevision && view.model.changeCount != nil
        }
        view.model.originalText = "another reference"
        #expect(await referenceChanged.waitUntilValue(true))
        await view.waitForPendingComparisonRefreshForTesting()
        #expect(textView.hasMarkedText())
        #expect(textView.markedRange() == marked)
        #expect(textView.selectedRange() == selected)
        #expect(window.firstResponder === textView)
        textView.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!textView.hasMarkedText())
        #expect(textView.string == source + "仮名")
        #expect(context.model.text == source + "仮名")
    }

    @Test("Inline reference selection retains whole-document syntax context and survives change navigation")
    @MainActor
    func macComparisonInlineSelectionAndReferenceStyles() async throws {
        let original = "/*\nremoved body\n*/\nlet stable = 1\n"
        let source = "/*\n*/\nlet stable = 1\n"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x102030),
            comment: syntaxEditorUITestColor(hex: 0xA02090)
        )
        let context = SyntaxEditorTestContext(text: source, language: .swift, theme: theme)
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        let deleted = try #require(view.modifiedLayout.deletedViews[0])
        #expect(deleted.string == "removed body\n")
        #expect(!deleted.isEditable)
        #expect(deleted.isSelectable)
        #expect(deleted.textLayoutManager != nil)
        let foreground = try #require(deleted.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(syntaxEditorUITestColorsEqual(foreground, theme.comment))

        let currentSelection = view.modifiedEditor.selectedRange
        window.makeFirstResponder(deleted)
        deleted.setSelectedRange(NSRange(location: 1, length: 4))
        #expect(deleted.selectedRange() == NSRange(location: 1, length: 4))
        #expect(view.model.original.selectedRange == NSRange(location: "/*\n".utf16.count + 1, length: 4))
        #expect(view.modifiedEditor.selectedRange == currentSelection)
        let cutItem = NSMenuItem(title: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        #expect(!deleted.validateUserInterfaceItem(cutItem))

        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selectedChange = await delivery.values { view.model.selectedChangeIndex }
        #expect(view.model.selectNextChange())
        #expect(await selectedChange.waitUntilValue(0))
        await view.waitForPendingComparisonRefreshForTesting()
        layoutMacComparison(view)
        #expect(view.modifiedLayout.deletedViews[0] === deleted)
        #expect(deleted.selectedRange() == NSRange(location: 1, length: 4))
        #expect(window.firstResponder === deleted)
        #expect(context.model.text == source)
    }

    @Test("Rebinding a comparison clears old deletion ranges before changing document and font")
    @MainActor
    func macComparisonRebindsShorterReferenceAndFont() async throws {
        let context = SyntaxEditorTestContext(text: "prefix\nnew words\nend\n", language: .plainText)
        let (view, window) = try await makeMacComparison(
            original: "prefix\na much longer reference line\nend\n", context: context
        )
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let oldDeleted = try #require(view.modifiedLayout.deletedViews[0])
        window.makeFirstResponder(oldDeleted)
        let nextDocument = SyntaxEditorModel(text: "new", language: .plainText, fontSizeDelta: 4)
        let next = SyntaxEditorComparisonModel(originalText: "x", modified: nextDocument)
        let calculation = try #require(next.calculation)
        await calculation.value

        view.update(model: next)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutMacComparison(view)

        #expect(view.model === next)
        #expect(view.modifiedEditor === editor)
        #expect(editor.model === nextDocument)
        #expect(editor.textView.string == "new")
        #expect(view.originalEditor.textView.string == "x")
        #expect(view.modifiedLayout.deletedViews[0]?.string == "x")
        #expect(oldDeleted.window == nil)
        #expect(window.firstResponder === editor.textView)
    }

    @Test("A synchronous layout after shortening the reference does not reuse out-of-bounds inline spans")
    @MainActor
    func macComparisonLaysOutImmediatelyAfterReferenceChange() async throws {
        let source = "prefix\nnew words\nend\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(
            original: "prefix\na much longer reference line\nend\n", context: context
        )
        defer { window.orderOut(nil) }
        let revision = view.model.original.textRevision + 1
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let ready = await delivery.values {
            view.model.original.textRevision == revision && view.model.changeCount != nil
        }
        view.model.originalText = "x"
        context.model.fontSizeDelta = 4
        layoutMacComparison(view)
        #expect(await ready.waitUntilValue(true))
        await view.waitForPendingComparisonRefreshForTesting()
        layoutMacComparison(view)
        #expect(view.modifiedLayout.deletedViews[0]?.string == "x")
        #expect(view.modifiedEditor.textView.string == source)
    }

    @Test("Removing an active deleted block transfers focus to a visible editor")
    @MainActor
    func macComparisonTransfersDeletedFocusBeforeRemoval() async throws {
        for presentation: SyntaxEditorComparisonModel.Presentation in [.changeMarkers, .sideBySide, .inline] {
            let source = "before\nafter\n"
            let context = SyntaxEditorTestContext(text: source, language: .plainText)
            let (view, window) = try await makeMacComparison(original: "before\nremoved\nafter\n", context: context)
            defer { window.orderOut(nil) }
            let deleted = try #require(view.modifiedLayout.deletedViews[0])
            #expect(window.makeFirstResponder(deleted))
            deleted.setSelectedRange(NSRange(location: 1, length: 3))
            let currentSelection = view.modifiedEditor.selectedRange
            if presentation == .inline {
                let revision = view.model.original.textRevision + 1
                let delivery = try #require(view.comparisonDeliveryForTesting)
                let ready = await delivery.values {
                    view.model.original.textRevision == revision && view.model.changeCount != nil
                }
                view.model.originalText = "before\nchanged reference\nafter\n"
                #expect(await ready.waitUntilValue(true))
                await view.waitForPendingComparisonRefreshForTesting()
                layoutMacComparison(view)
            } else {
                try await changeMacComparison(view, to: presentation)
            }
            let expected = presentation == .sideBySide
                ? view.originalEditor.textView : view.modifiedEditor.textView
            #expect(window.firstResponder === expected)
            #expect(deleted.window == nil)
            #expect(view.modifiedEditor.selectedRange == currentSelection)
            #expect(context.model.text == source)
        }
    }

    @Test("Inline deletions retain a caret frame and fit the document at empty and EOF anchors")
    @MainActor
    func macComparisonEmptyAndEOFGeometry() async throws {
        for (original, source) in [
            ("removed", ""),
            ("removed\n", ""),
            ("keep\nremoved", "keep\n"),
            ("keep\nremoved\n", "keep\n"),
        ] {
            let context = SyntaxEditorTestContext(text: source, language: .plainText)
            let (view, window) = try await makeMacComparison(original: original, context: context)
            defer { window.orderOut(nil) }
            let deleted = try #require(view.modifiedLayout.deletedViews[0])
            let eof = NSRange(location: source.utf16.count, length: 0)
            let caret = try #require(view.modifiedLayout.frame(forUTF16Range: eof))
            let deletedFrame = deleted.convert(deleted.bounds, to: view.modifiedEditor.textView)
            #expect(caret.minY.isFinite)
            #expect(caret.height > 0)
            #expect(deletedFrame.height > 0)
            #expect(deletedFrame.minY >= 0)
            #expect(deletedFrame.maxY <= view.modifiedEditor.textView.bounds.maxY + 1)
            #expect(view.modifiedEditor.textView.string.utf16.elementsEqual(source.utf16))

            try await changeMacComparison(view, to: .changeMarkers)
            #expect(view.modifiedLayout.deletedViews.isEmpty)
            let markerCaret = try #require(view.modifiedLayout.frame(forUTF16Range: eof))
            #expect(markerCaret.height > 0)
            #expect(view.modifiedEditor.textView.string.utf16.elementsEqual(source.utf16))
        }
    }

    @Test("Resizing a wrapped inline deletion moves following text without overlap or a stale gap")
    @MainActor
    func macComparisonWrappedDeletionResize() async throws {
        let original = "start\n" + String(repeating: "wide text ", count: 30) + "\nend\n"
        let source = "start\nend\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeMacComparison(original: original, context: context, width: 900)
        defer { window.orderOut(nil) }
        let wideDeleted = try #require(view.modifiedLayout.deletedViews[0])
        let wideHeight = wideDeleted.frame.height

        window.setContentSize(NSSize(width: 260, height: 420))
        layoutMacComparison(view)
        let narrowDeleted = try #require(view.modifiedLayout.deletedViews[0])
        let narrowFrame = narrowDeleted.convert(narrowDeleted.bounds, to: view.modifiedEditor.textView)
        let following = try #require(view.modifiedLayout.lineFrame(1))
        #expect(narrowFrame.height > wideHeight)
        #expect(following.minY >= narrowFrame.maxY)
        #expect(following.minY - narrowFrame.maxY < following.height)
        #expect(narrowFrame.maxY <= view.modifiedEditor.textView.bounds.maxY)

        window.setContentSize(NSSize(width: 900, height: 420))
        layoutMacComparison(view)
        let restored = try #require(view.modifiedLayout.deletedViews[0])
        #expect(abs(restored.frame.height - wideHeight) <= 1)
        #expect(view.modifiedEditor.textView.string == source)
    }

    @Test("Inline deletions use the current editor's wrapped width after content inset changes")
    @MainActor
    func macComparisonDeletionRespectsContentInsets() async throws {
        let source = "start\nend\n"
        let original = "start\n" + String(repeating: "wide text ", count: 30) + "\nend\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeMacComparison(original: original, context: context, width: 500)
        defer { window.orderOut(nil) }
        let initial = try #require(view.modifiedLayout.deletedViews[0])
        let initialHeight = initial.frame.height
        view.modifiedEditor.contentInsets = NSEdgeInsets(top: 12, left: 60, bottom: 10, right: 90)
        view.modifiedEditor.layoutSubtreeIfNeeded()
        let deleted = try #require(view.modifiedLayout.deletedViews[0])
        let currentContainer = view.modifiedEditor.textContainer
        let deletedContainer = try #require(deleted.textContainer)
        #expect(deletedContainer.size.width == currentContainer.size.width - currentContainer.lineFragmentPadding * 2)
        #expect(deleted.frame.height > initialHeight)
        #expect(deleted.frame.maxX <= view.modifiedEditor.textView.bounds.maxX)
        #expect(deleted.string == String(repeating: "wide text ", count: 30) + "\n")
        #expect(context.model.text == source)
    }

    @Test("Side-by-side scrolling follows unchanged line correspondence after an insertion")
    @MainActor
    func macComparisonScrollsCorrespondingCommonLines() async throws {
        let lines = (0..<120).map { "common \($0)" }
        let source = lines.joined(separator: "\n")
        var originalLines = lines
        originalLines.insert(contentsOf: ["removed one", "removed two", "removed three"], at: 5)
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: originalLines.joined(separator: "\n"), context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        let sourceLine = try #require(view.modifiedLayout.lineFrame(50))
        let y = sourceLine.minY + sourceLine.height * 0.35
        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)
        let originalY = view.originalEditor.textView.convert(
            view.originalEditor.contentView.bounds.origin,
            from: view.originalEditor.contentView
        ).y
        let originalLine = try #require(view.originalLayout.logicalPosition(atY: originalY))
        #expect(abs(originalLine - 53.35) < 0.2)
        #expect(view.modifiedEditor.textView.string == source)
    }

    @Test("Side-by-side scrolling interpolates the displayed height of a wrapped changed block")
    @MainActor
    func macComparisonScrollsWrappedChangedBlock() async throws {
        let prefix = (0..<30).map { "prefix \($0)\n" }.joined()
        let suffix = (0..<100).map { "suffix \($0)\n" }.joined()
        let source = prefix + "new content\n" + suffix
        let original = prefix + String(repeating: "old content ", count: 35) + "\n" + suffix
        let context = SyntaxEditorTestContext(text: source, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        let change = try #require(view.model.changes?.first)
        let currentSpan = try #require(view.modifiedLayout.frame(forUTF16Range: change.modifiedRange))
        let originalSpan = try #require(view.originalLayout.frame(forUTF16Range: change.originalRange))
        #expect(originalSpan.height > currentSpan.height)
        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: currentSpan.midY))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)
        let originalY = view.originalEditor.textView.convert(
            view.originalEditor.contentView.bounds.origin,
            from: view.originalEditor.contentView
        ).y
        let currentOriginalSpan = try #require(view.originalLayout.frame(forUTF16Range: change.originalRange))
        #expect(abs(originalY - currentOriginalSpan.midY) <= 2)
    }

    @Test("Inline reference selections project from the model across presentation changes")
    @MainActor
    func macComparisonRestoresReferenceSelectionAcrossPresentations() async throws {
        let source = "start\nmiddle\nend\n"
        let original = "start\nold A\nmiddle\nold B\nend\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        let first = try #require(view.modifiedLayout.deletedViews[0])
        window.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 1, length: 3))
        let selection = view.model.original.selectedRange
        try await changeMacComparison(view, to: .sideBySide)
        try await changeMacComparison(view, to: .inline)
        let restored = try #require(view.modifiedLayout.deletedViews[0])
        #expect(restored !== first)
        #expect(restored.selectedRange() == NSRange(location: 1, length: 3))
        #expect(view.model.original.selectedRange == selection)

        try await changeMacComparison(view, to: .sideBySide)
        let a = (original as NSString).range(of: "old A\n")
        let b = (original as NSString).range(of: "old B\n")
        let spanning = NSRange(location: a.location + 1, length: b.upperBound - 1 - a.location - 1)
        view.originalEditor.textView.setSelectedRange(spanning)
        try await changeMacComparison(view, to: .inline)
        let restoredA = try #require(view.modifiedLayout.deletedViews[0])
        let restoredB = try #require(view.modifiedLayout.deletedViews[1])
        #expect(restoredA.selectedRange() == NSRange(location: 1, length: a.length - 1))
        #expect(restoredB.selectedRange() == NSRange(location: 0, length: b.length - 1))
        #expect(view.model.original.selectedRange == spanning)

        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selections = await delivery.values { view.model.original.selectedRange }
        let lastSelection = NSRange(location: b.location + 1, length: 2)
        restoredB.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(await selections.waitUntilValue(lastSelection))
        await view.waitForPendingComparisonRefreshForTesting {
            restoredA.selectedRange().length == 0
        }
        #expect(restoredA.selectedRange().length == 0)
        #expect(restoredB.selectedRange() == NSRange(location: 1, length: 2))
        #expect(view.model.original.selectedRange == lastSelection)
        #expect(context.model.text == source)
    }

    @Test("Recycled inline views restore the reference selection without publishing a new selection")
    @MainActor
    func macComparisonRestoresReferenceSelectionAfterRecycling() async throws {
        let common = (0..<200).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: "start\n" + common, language: .plainText)
        let (view, window) = try await makeMacComparison(original: "start\nremoved value\n" + common, context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let old = try #require(view.modifiedLayout.deletedViews[0])
        window.makeFirstResponder(old)
        old.setSelectedRange(NSRange(location: 2, length: 4))
        let originalSelection = view.model.original.selectedRange
        window.makeFirstResponder(editor.textView)
        let far = try #require(view.modifiedLayout.lineFrame(120))
        editor.contentView.scroll(to: NSPoint(x: editor.contentView.bounds.minX, y: far.minY))
        editor.reflectScrolledClipView(editor.contentView)
        layoutMacComparison(view)
        #expect(view.modifiedLayout.deletedViews[0] == nil)
        #expect(old.window == nil)
        editor.contentView.scroll(to: NSPoint(x: editor.contentView.bounds.minX, y: 0))
        editor.reflectScrolledClipView(editor.contentView)
        layoutMacComparison(view)
        let recreated = try #require(view.modifiedLayout.deletedViews[0])
        #expect(recreated !== old)
        #expect(recreated.selectedRange() == NSRange(location: 2, length: 4))
        #expect(view.model.original.selectedRange == originalSelection)
    }

    @Test("Deleted block layer colors follow their effective appearance without relayout")
    @MainActor
    func macComparisonDeletedColorsFollowAppearance() async throws {
        let context = SyntaxEditorTestContext(
            text: "before\nafter\n", language: .plainText,
            theme: syntaxEditorUITestTheme(background: syntaxEditorUITestColor(hex: 0xFFFFFF))
        )
        let (view, window) = try await makeMacComparison(original: "before\nremoved\nafter\n", context: context)
        defer { window.orderOut(nil) }
        let deleted = try #require(view.modifiedLayout.deletedViews[0])
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let selection = await delivery.values { view.model.selectedChangeIndex }
        #expect(view.model.selectNextChange())
        #expect(await selection.waitUntilValue(0))
        await view.waitForPendingComparisonRefreshForTesting()
        let layer = try #require(deleted.layer)
        let alpha = try #require(layer.backgroundColor).alpha
        for name: NSAppearance.Name in [.darkAqua, .aqua] {
            deleted.appearance = try #require(NSAppearance(named: name))
            deleted.viewDidChangeEffectiveAppearance()
            var background: CGColor?
            var border: CGColor?
            deleted.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = NSColor.systemRed.withAlphaComponent(alpha).cgColor
                border = NSColor.selectedControlColor.cgColor
            }
            #expect(layer.backgroundColor == background)
            #expect(layer.borderColor == border)
            #expect(layer.borderWidth == 1)
        }
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
            let (view, window) = try await makeMacComparison(original: original, context: context)
            defer { window.orderOut(nil) }
            let editor = view.modifiedEditor
            let target: CGRect
            if kind == "deletion" {
                let deleted = try #require(view.modifiedLayout.deletedViews[0])
                target = deleted.convert(deleted.bounds, to: editor.textView)
            } else {
                target = try #require(view.modifiedLayout.frame(forUTF16Range: NSRange(location: 0, length: source.utf16.count)))
            }
            editor.contentView.scroll(to: NSPoint(x: editor.contentView.bounds.minX, y: target.midY))
            editor.reflectScrolledClipView(editor.contentView)
            layoutMacComparison(view)
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
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        editor.contentInsets.bottom = 70
        layoutMacComparison(view)
        func bottomBounds() -> CGRect {
            var bounds = editor.contentView.bounds
            bounds.origin.y = editor.textView.bounds.maxY + editor.contentView.contentInsets.bottom
            return editor.contentView.constrainBoundsRect(bounds)
        }
        editor.contentView.scroll(to: bottomBounds().origin)
        editor.reflectScrolledClipView(editor.contentView)
        layoutMacComparison(view)
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
        layoutMacComparison(view)
        #expect(abs(editor.contentView.bounds.minY - bottomBounds().minY) < 1)
    }

    @Test("Resizing preserves a reference viewport inside a deleted span")
    @MainActor
    func macComparisonPreservesReferenceViewportOnResize() async throws {
        let prefix = (0..<30).map { "prefix \($0)\n" }.joined()
        let removed = (0..<200).map { "removed \($0)\n" }.joined()
        let suffix = (0..<200).map { "suffix \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + suffix, language: .plainText)
        let (view, window) = try await makeMacComparison(original: prefix + removed + suffix, context: context, width: 900)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        let reference = view.originalEditor
        let line = try #require(view.originalLayout.lineFrame(130))
        reference.contentView.scroll(to: NSPoint(x: reference.contentView.bounds.minX, y: line.minY))
        reference.reflectScrolledClipView(reference.contentView)
        let beforeY = reference.textView.convert(reference.contentView.bounds.origin, from: reference.contentView).y
        let before = try #require(view.originalLayout.logicalPosition(atY: beforeY))

        window.setContentSize(NSSize(width: 720, height: 420))
        layoutMacComparison(view)

        let afterY = reference.textView.convert(reference.contentView.bounds.origin, from: reference.contentView).y
        let after = try #require(view.originalLayout.logicalPosition(atY: afterY))
        #expect(abs(before - after) < 0.2)
    }

    @Test("Inline geometry changes retain the visible common line")
    @MainActor
    func macComparisonPreservesAnchorAcrossInlineGeometryChanges() async throws {
        for setting in ["width", "font", "wrapping"] {
            let common = (0..<120).map { "common \($0)\n" }.joined()
            let context = SyntaxEditorTestContext(text: "start\n" + common, language: .plainText, lineWrappingEnabled: true)
            let original = "start\n" + String(repeating: "deleted text ", count: 100) + "\n" + common
            let (view, window) = try await makeMacComparison(original: original, context: context, width: 900)
            defer { window.orderOut(nil) }
            let editor = view.modifiedEditor
            let line = try #require(view.modifiedLayout.lineFrame(50))
            editor.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
            editor.reflectScrolledClipView(editor.contentView)
            layoutMacComparison(view)
            let beforeY = editor.textView.convert(editor.contentView.bounds.origin, from: editor.contentView).y
            let before = try #require(view.modifiedLayout.logicalPosition(atY: beforeY))
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
            layoutMacComparison(view)
            let afterY = editor.textView.convert(editor.contentView.bounds.origin, from: editor.contentView).y
            let after = try #require(view.modifiedLayout.logicalPosition(atY: afterY))
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
        let (view, window) = try await makeMacComparison(original: prefix + removed + "end\n", context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let initial = try #require(view.modifiedLayout.deletedViews[0])
        let blockFrame = initial.convert(initial.bounds, to: editor.textView)
        editor.contentView.scroll(to: NSPoint(x: 0, y: blockFrame.midY))
        editor.reflectScrolledClipView(editor.contentView)
        layoutMacComparison(view)
        let deleted = try #require(view.modifiedLayout.deletedViews[0])
        func visibleReferenceLine(in textView: NSTextView) -> Int {
            var point = textView.convert(editor.contentView.bounds.origin, from: editor.contentView)
            point.x = textView.textContainerOrigin.x + 1
            let offset = textView.characterIndexForInsertion(at: point)
            return prefix.utf16.count + (textView.string as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
        }
        let localLine = visibleReferenceLine(in: deleted) - prefix.utf16.count
        window.makeFirstResponder(deleted)
        deleted.setSelectedRange(NSRange(location: localLine + 2, length: 5))
        layoutMacComparison(view)
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
        layoutMacComparison(view)
        let updated = try #require(view.modifiedLayout.deletedViews[0])
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
            let (view, window) = try await makeMacComparison(original: "start\n" + first + "middle\n" + second + "end\n", context: context, width: 900)
            defer { window.orderOut(nil) }
            #expect(view.model.changeCount == 2)
            let editor = view.modifiedEditor
            view.modifiedLayout.revealChange(at: 1)
            layoutMacComparison(view)
            let deleted = try #require(view.modifiedLayout.deletedViews[1])
            let frame = deleted.convert(deleted.bounds, to: editor.textView)
            editor.contentView.scroll(to: CGPoint(x: 0, y: frame.minY + 1200))
            editor.reflectScrolledClipView(editor.contentView)
            layoutMacComparison(view)
            func visibleLine() throws -> Int {
                let current = try #require(view.modifiedLayout.deletedViews[1])
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
            layoutMacComparison(view)
            #expect(try visibleLine() == before, "setting: \(setting)")
        }
    }

    @Test("Completed comparisons resynchronize visible panes after edits above the viewport")
    @MainActor
    func macComparisonResynchronizesAfterComparisonRefresh() async throws {
        let source = (0..<140).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: source, context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        let editor = view.modifiedEditor
        let line = try #require(view.modifiedLayout.lineFrame(70))
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
        let currentLine = try #require(view.modifiedLayout.logicalPosition(atY: currentY))
        let referenceLine = try #require(view.originalLayout.logicalPosition(atY: referenceY))
        #expect(abs(currentLine - 2 - referenceLine) < 0.2)
    }

    @Test("EOF changes have correctly colored boundary markers")
    @MainActor
    func macComparisonEOFChangesHaveMarkers() async throws {
        for (original, source, referenceBoundary) in [
            ("a\nb\n", "a\n", false), ("a\r\nb\r\n", "a\r\n", false), ("removed\n", "", false),
            ("a\n", "a\nb\n", true), ("", "added\n", true),
        ] {
            let theme = syntaxEditorUITestTheme(background: syntaxEditorUITestColor(hex: 0xFFFFFF))
            let context = SyntaxEditorTestContext(text: source, language: .plainText, theme: theme)
            let (view, window) = try await makeMacComparison(original: original, context: context)
            defer { window.orderOut(nil) }
            try await changeMacComparison(view, to: referenceBoundary ? .sideBySide : .changeMarkers)
            let editor = referenceBoundary ? view.originalEditor : view.modifiedEditor
            let ruler = try #require(editor.verticalRulerView)
            let (bitmap, graphics) = try comparisonBitmap(size: ruler.bounds.size)
            ruler.displayIgnoringOpacity(ruler.bounds, in: graphics)
            let markerX = Int(ruler.ruleThickness) - 4
            let hasExpectedMarker = (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: markerX, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return referenceBoundary
                    ? color.greenComponent > color.redComponent + 0.15 && color.greenComponent > color.blueComponent + 0.15
                    : color.redComponent > color.greenComponent + 0.15 && color.redComponent > color.blueComponent + 0.15
            }
            #expect(hasExpectedMarker)
        }
    }

    @Test("Deletion boundaries do not color the following common text")
    @MainActor
    func macComparisonDeletionDoesNotColorCommonRow() async throws {
        let context = SyntaxEditorTestContext(text: "before\nafter\n", language: .plainText)
        let (view, window) = try await makeMacComparison(original: "before\nremoved\nafter\n", context: context)
        defer { window.orderOut(nil) }
        for presentation: SyntaxEditorComparisonModel.Presentation in [.inline, .sideBySide] {
            try await changeMacComparison(view, to: presentation)
            let editor = view.modifiedEditor
            let surface = try #require(editor.textView.textContentView.subviews.compactMap {
                $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView
            }.first { editor.textSystem.utf16Range(for: $0.layoutFragment).location == "before\n".utf16.count })
            let (bitmap, graphics) = try comparisonBitmap(size: surface.bounds.size)
            graphics.cgContext.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            graphics.cgContext.fill(surface.bounds)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            view.modifiedLayout.drawBackground(
                for: surface.layoutFragment, surfaceOrigin: surface.frame.origin,
                in: surface.bounds, dirtyRect: surface.bounds
            )
            NSGraphicsContext.restoreGraphicsState()
            let addedRed = (0..<bitmap.pixelsHigh).contains { y in
                let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB)
                return (color?.redComponent ?? 0) > 0.01
            }
            #expect(!addedRed)
        }
    }

    @Test("Resizing wrapped comparisons keeps the visible common lines synchronized")
    @MainActor
    func macComparisonResynchronizesAfterWrappedResize() async throws {
        let prefix = (0..<10).map { "prefix \($0)\n" }.joined()
        let suffix = (0..<100).map { "common \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: prefix + "new\n" + suffix, language: .plainText, lineWrappingEnabled: true)
        let original = prefix + String(repeating: "long reference text ", count: 25) + "\n" + suffix
        let (view, window) = try await makeMacComparison(original: original, context: context, width: 900)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        let line = try #require(view.modifiedLayout.lineFrame(50))
        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)

        window.setContentSize(NSSize(width: 440, height: 420))
        layoutMacComparison(view)
        let currentY = view.modifiedEditor.textView.convert(view.modifiedEditor.contentView.bounds.origin, from: view.modifiedEditor.contentView).y
        let referenceY = view.originalEditor.textView.convert(view.originalEditor.contentView.bounds.origin, from: view.originalEditor.contentView).y
        let currentLine = try #require(view.modifiedLayout.logicalPosition(atY: currentY))
        let referenceLine = try #require(view.originalLayout.logicalPosition(atY: referenceY))
        #expect(abs(currentLine - referenceLine) < 0.2)
    }

    @MainActor
    private func comparisonBitmap(size: NSSize) throws -> (NSBitmapImageRep, NSGraphicsContext) {
        let bitmap = try #require(unsafe NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return (bitmap, try #require(NSGraphicsContext(bitmapImageRep: bitmap)))
    }

    @Test("The comparison ruler does not paint over the document")
    @MainActor
    func macComparisonDrawsTextBesideRuler() async throws {
        let theme = syntaxEditorUITestTheme(background: syntaxEditorUITestColor(hex: 0xFFFFFF))
        let context = SyntaxEditorTestContext(text: "Visible document", language: .plainText, theme: theme)
        let (view, window) = try await makeMacComparison(original: "Reference document", context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .changeMarkers)

        let ruler = try #require(view.modifiedEditor.verticalRulerView)
        let canvas = NSRect(x: 0, y: 0, width: view.modifiedEditor.bounds.width, height: ruler.bounds.height)
        let bitmap = try #require(unsafe NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(canvas.width)),
            pixelsHigh: Int(ceil(canvas.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        graphics.cgContext.fill(canvas)

        // Draw into a CPU bitmap wider than the ruler. This exercises AppKit's
        // clipping and the real ruler drawing without waiting for glyph layers.
        ruler.displayIgnoringOpacity(canvas, in: graphics)

        let inside = try #require(bitmap.colorAt(x: Int(ruler.bounds.midX), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let outside = try #require(bitmap.colorAt(x: Int(ruler.bounds.maxX) + 10, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(inside.redComponent > 0.99 && inside.greenComponent > 0.99 && inside.blueComponent > 0.99)
        #expect(outside.redComponent < 0.01 && outside.greenComponent < 0.01 && outside.blueComponent > 0.99)

        try await changeMacComparison(view, to: .sideBySide)
        let reference = view.originalEditor
        let clip = reference.contentView
        #expect(abs(clip.bounds.minX + clip.contentInsets.left) < 1)
        let caret = try #require(view.originalLayout.frame(forUTF16Range: NSRange(location: 0, length: 0)))
        let caretInEditor = reference.convert(caret, from: reference.textView)
        let referenceRuler = try #require(reference.verticalRulerView)
        #expect(caretInEditor.minX >= referenceRuler.ruleThickness)
    }

    @Test("Comparison accessibility actions navigate changes without editing the document")
    @MainActor
    func macComparisonAccessibilityNavigation() async throws {
        let source = "first\nkeep\nlast\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: "old first\nkeep\nold last\n", context: context)
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
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        let editor = view.modifiedEditor
        let parent = editor.superview
        editor.selectedRange = NSRange(location: 1, length: 3)
        let deleted = try #require(view.modifiedLayout.deletedViews[0])
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

    @Test("A large full deletion keeps current glyph surfaces small and reference layout local")
    @MainActor
    func macComparisonLargeFullDeletionUsesBoundedSurfaces() async throws {
        let referenceLineCount = 2_000
        let original = (0..<referenceLineCount).map { "removed line \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: "", language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        let current = view.modifiedEditor.textView
        let deleted = try #require(view.modifiedLayout.deletedViews[0])
        let surface = try #require(current.textContentView.subviews.compactMap {
            $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView
        }.first)
        let caret = try #require(view.modifiedLayout.frame(forUTF16Range: NSRange(location: 0, length: 0)))

        #expect(context.model.text.isEmpty)
        #expect(current.string.isEmpty)
        #expect(deleted.frame.height > view.modifiedEditor.contentView.bounds.height)
        #expect(surface.frame.height <= caret.height + 1)
        #expect(deleted.frame.minY >= caret.maxY)
        #expect(deleted.string == original)
        #expect(!deleted.isEditable && deleted.isSelectable)

        let manager = try #require(deleted.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let viewport = try #require(manager.textViewportLayoutController.viewportRange)
        #expect(viewport.endLocation.compare(content.documentRange.endLocation) == .orderedAscending)
        var laidOutFragmentCount = 0
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable { laidOutFragmentCount += 1 }
            return true
        }
        #expect(laidOutFragmentCount > 0)
        #expect(laidOutFragmentCount < referenceLineCount)

        view.modifiedEditor.contentView.scroll(to: NSPoint(x: 0, y: deleted.frame.midY))
        view.modifiedEditor.reflectScrolledClipView(view.modifiedEditor.contentView)
        layoutMacComparison(view)
        let scrolled = try #require(view.modifiedLayout.deletedViews[0])
        #expect(scrolled === deleted)
        #expect(scrolled.visibleRect.height > 0)
        let scrolledViewport = try #require(manager.textViewportLayoutController.viewportRange)
        #expect(scrolledViewport.location.compare(content.documentRange.location) == .orderedDescending)
        #expect(current.string.isEmpty)
    }

    @Test("A large inline margin is excluded from the following glyph surface")
    @MainActor
    func macComparisonLargeMarginUsesBoundedSurfaces() async throws {
        let source = "keep\n"
        let original = (0..<2_000).map { "removed line \($0)\n" }.joined() + source
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeMacComparison(original: original, context: context)
        defer { window.orderOut(nil) }
        let surfaces = view.modifiedEditor.textView.textContentView.subviews.compactMap {
            $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView
        }
        let surface = try #require(surfaces.first { $0.layoutFragment.topMargin > 0 })
        #expect(surface.layoutFragment.layoutFragmentFrame.height > window.contentLayoutRect.height)
        #expect(surface.frame.height < window.contentLayoutRect.height)
        #expect(surface.frame.minY >= surface.layoutFragment.topMargin)
        #expect(view.modifiedEditor.textView.string == source)
    }

    @Test("A zero viewport defers deleted views until visible blocks can be identified")
    @MainActor
    func macComparisonZeroViewportDefersDeletedViews() async throws {
        let deletionCount = 1_000
        let original = (0..<deletionCount).map { "keep \($0)\nremoved \($0)\n" }.joined()
        let source = (0..<deletionCount).map { "keep \($0)\n" }.joined()
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model)
        let calculation = try #require(model.calculation)
        await calculation.value
        #expect(model.changeCount == deletionCount)

        let view = SyntaxEditorComparisonView(model: model)
        #expect(view.bounds.isEmpty)
        #expect(view.modifiedEditor.contentView.bounds.isEmpty)
        #expect(view.modifiedLayout.deletedViews.isEmpty)
        #expect(context.model.text == source)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        layoutMacComparison(view)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutMacComparison(view)

        #expect(!view.modifiedLayout.deletedViews.isEmpty)
        #expect(view.modifiedLayout.deletedViews.count < deletionCount)
        #expect(view.modifiedEditor.textView.string == source)
    }

    @MainActor
    private func makeMacComparison(
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
        layoutMacComparison(view)
        await view.originalEditor.waitForPendingHighlightForTesting()
        await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutMacComparison(view)
        return (view, window)
    }

    @MainActor
    private func changeMacComparison(
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
        layoutMacComparison(view)
    }

    @MainActor
    private func layoutMacComparison(_ view: SyntaxEditorComparisonView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.modifiedEditor.textView.layoutVisibleViewport()
        if !view.originalEditor.isHidden {
            view.originalEditor.textView.layoutVisibleViewport()
        }
    }
}
#endif
