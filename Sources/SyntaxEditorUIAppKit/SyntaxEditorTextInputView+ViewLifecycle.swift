#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
    override class var isCompatibleWithResponsiveScrolling: Bool {
        false
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }
    override var undoManager: UndoManager? { guardedUndoManager ?? super.undoManager }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            backgroundColor.setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        textContentView.frame = bounds
        layoutVisibleViewport()
        updateDecorationRenderingForVisibleFragments()
    }

    override func prepareContent(in rect: NSRect) {
        let oldPreparedContentRect = preparedContentRect
        var preparedRect = rect
        let expansion = viewportPreparationExpansion
        if expansion > 0 {
            let upwardShift = min(expansion, max(0, preparedRect.minY))
            preparedRect.origin.y -= upwardShift
            preparedRect.size.height += upwardShift
        }
        preparedRect.origin.x = 0
        preparedRect.size.width = max(preparedRect.width, bounds.width)

        super.prepareContent(in: preparedRect)

        if oldPreparedContentRect != preparedContentRect {
            layoutVisibleViewport()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureTextFinder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clearTextFinderAttachments()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTextFinder()
        updateSelectionRendering()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        updateSelectionRendering()
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        updateSelectionRendering()
        return resignedFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        if inputContext?.handleEvent(event) == true {
            return
        }
        interpretKeyEvents([event])
    }

    override func mouseDown(with event: NSEvent) {
        guard inputContext?.handleEvent(event) != true else {
            return
        }
        unsafe window?.makeFirstResponder(self)
        guard isSelectable, event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let extendsSelection = modifiers.contains(.shift)
        let usesVisualSelection = modifiers.contains(.option)

        switch event.clickCount {
        case 1:
            updateTextSelection(
                interactingAt: location,
                anchors: extendsSelection ? textLayoutManager.textSelections : [],
                extending: extendsSelection,
                isDragging: false,
                visual: usesVisualSelection
            )
        case 2:
            updateTextSelection(interactingAt: location)
            selectGranularity(.word)
        case 3:
            updateTextSelection(interactingAt: location)
            selectGranularity(.paragraph)
        default:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard inputContext?.handleEvent(event) != true else {
            return
        }
        guard isSelectable else {
            super.mouseDragged(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        if mouseDraggingSelectionAnchors == nil {
            mouseDraggingSelectionAnchors = textLayoutManager.textSelections
        }
        updateTextSelection(
            interactingAt: location,
            inContainerAt: mouseDraggingSelectionAnchors?.first?.textRanges.first?.location,
            anchors: mouseDraggingSelectionAnchors ?? [],
            extending: true,
            isDragging: true,
            visual: event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        )
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDraggingSelectionAnchors = nil
        super.mouseUp(with: event)
    }
}
#endif
