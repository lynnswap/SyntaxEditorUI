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
        for presentation: SyntaxEditorComparisonModel.Presentation in [.changeMarkers, .sideBySide] {
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
        let caretOnScreen = reference.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let caret = reference.textView.convert(window.convertFromScreen(caretOnScreen), from: nil)
        let caretInEditor = reference.convert(caret, from: reference.textView)
        let referenceRuler = try #require(reference.verticalRulerView)
        #expect(caretInEditor.minX >= referenceRuler.ruleThickness)
    }

    @Test("Transparent comparison editors leave the ruler background transparent")
    @MainActor
    func macComparisonRulerRespectsTransparentBackground() async throws {
        let context = SyntaxEditorTestContext(
            text: "unchanged\n", language: .plainText,
            theme: syntaxEditorUITestTheme(background: syntaxEditorUITestColor(hex: 0xFFFFFF)),
            drawsBackground: false
        )
        let (view, window) = try await makeMacComparison(original: context.model.text, context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        for editor in [view.modifiedEditor, view.originalEditor] {
            #expect(!editor.drawsBackground)
            let ruler = try #require(editor.verticalRulerView)
            let (bitmap, graphics) = try comparisonBitmap(size: ruler.bounds.size)
            graphics.cgContext.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            graphics.cgContext.fill(ruler.bounds)
            ruler.displayIgnoringOpacity(ruler.bounds, in: graphics)
            let background = try #require(bitmap.colorAt(x: 20, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(background.redComponent < 0.01 && background.greenComponent < 0.01 && background.blueComponent > 0.99)
        }
    }

    @Test("Side-by-side comparisons draw row and intraline backgrounds across the viewport")
    @MainActor
    func macComparisonDrawsRowAndIntralineBackgrounds() async throws {
        let context = SyntaxEditorTestContext(text: "prefix green suffix\n", language: .plainText)
        let (view, window) = try await makeMacComparison(original: "prefix blue suffix\n", context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        for (editor, layout, isReference) in [
            (view.modifiedEditor, view.modifiedLayout, false),
            (view.originalEditor, view.originalLayout, true),
        ] {
            let surface = try #require(editor.textView.textContentView.subviews.compactMap {
                $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView
            }.first { editor.textSystem.utf16Range(for: $0.layoutFragment).location == 0 })
            #expect(surface.frame.maxX >= editor.textView.bounds.maxX - 1)
            let range = try #require(layout.changes.first?.inlineChanges.map {
                isReference ? $0.originalRange : $0.modifiedRange
            }.first { $0.length > 0 })
            let screenRect = editor.textView.firstRect(forCharacterRange: range, actualRange: nil)
            let wordRect = surface.convert(window.convertFromScreen(screenRect), from: nil)
            let (bitmap, graphics) = try comparisonBitmap(size: surface.bounds.size)
            graphics.cgContext.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            graphics.cgContext.fill(surface.bounds)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.cgContext.translateBy(x: 0, y: surface.bounds.height)
            graphics.cgContext.scaleBy(x: 1, y: -1)
            layout.drawBackground(for: surface.layoutFragment, surfaceOrigin: surface.frame.origin,
                                  in: surface.bounds, dirtyRect: surface.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let row = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: Int(wordRect.midY))?.usingColorSpace(.deviceRGB))
            let inline = try #require(bitmap.colorAt(x: Int(wordRect.midX), y: Int(wordRect.midY))?.usingColorSpace(.deviceRGB))
            let rowComponent = isReference ? row.redComponent : row.greenComponent
            let inlineComponent = isReference ? inline.redComponent : inline.greenComponent
            #expect(rowComponent > 0.02)
            #expect(inlineComponent > rowComponent + 0.05)
        }
    }

    @Test("Rebinding comparisons clears old ranges before installing shorter documents")
    @MainActor
    func macComparisonRebindsNativeEditors() async throws {
        let context = SyntaxEditorTestContext(text: "current\n" + String(repeating: "value\n", count: 200), language: .plainText)
        let (view, window) = try await makeMacComparison(original: "reference\n" + String(repeating: "old\n", count: 200), context: context)
        defer { window.orderOut(nil) }
        try await changeMacComparison(view, to: .sideBySide)
        let current = view.modifiedEditor
        let original = view.originalEditor
        let nextDocument = SyntaxEditorModel(text: "y", language: .plainText, fontSizeDelta: 4)
        let next = SyntaxEditorComparisonModel(originalText: "x", modified: nextDocument, presentation: .sideBySide)
        await next.calculation?.value
        view.update(model: next)
        layoutMacComparison(view)
        #expect(view.modifiedEditor === current)
        #expect(view.originalEditor === original)
        #expect(current.model === nextDocument)
        #expect(current.text == "y")
        #expect(original.text == "x")
        #expect(!original.isEditable)
        #expect(view.modifiedLayout.changes == next.changes)
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

    @MainActor
    private func makeMacComparison(
        original: String,
        context: SyntaxEditorTestContext,
        width: CGFloat = 720
    ) async throws -> (SyntaxEditorComparisonView, NSWindow) {
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model, presentation: .changeMarkers)
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
