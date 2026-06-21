#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

@MainActor
final class SyntaxEditorTextInputView: NSView, @preconcurrency NSTextInputClient, @preconcurrency NSTextFinderClient, @preconcurrency NSTextLayoutManagerDelegate, @preconcurrency NSTextViewportLayoutControllerDelegate, NSUserInterfaceValidations {
    let textSystem: EditorTextSystem
    let textContentView = SyntaxEditorTextInputView.TextContentView()
    let textFinder = NSTextFinder()
    let insertionIndicator = NSTextInsertionIndicator(frame: .zero)
    private var incrementalMatchRangesObservation: NSKeyValueObservation?
    var findHighlightRangesOverrideForTesting: [NSRange]?
    var findHighlightRangeIndex = TextRangeIntersectionIndex(utf16Length: 0)

    var guardedUndoManager: UndoManager?
    var shortcutHandler: ((EditorShortcutAction) -> Bool)?
    var shortcutValidator: ((EditorShortcutAction) -> Bool)?
    var commandHandler: ((Selector) -> Bool)?
    var lineWrappingStateProvider: (() -> Bool)?
    var didChangeText: (() -> Void)?
    var didChangeSelection: (() -> Void)?
    var didChangeMarkedTextRange: (() -> Void)?
    var shouldChangeText: (([NSRange], [String]) -> Bool)?

    var typingAttributes: [NSAttributedString.Key: Any] = [:]
    var isEditable = true
    var isSelectable = true
    var allowsUndo = true
    var usesFindBar = false {
        didSet {
            guard usesFindBar != oldValue else { return }
            configureTextFinder()
        }
    }
    var usesFindPanel = false
    var isIncrementalSearchingEnabled = false {
        didSet {
            guard isIncrementalSearchingEnabled != oldValue else { return }
            textFinder.isIncrementalSearchingEnabled = isIncrementalSearchingEnabled
            rebuildFindHighlightRangeIndex()
            updateFindHighlightsForVisibleFragments()
        }
    }
    var drawsBackground = false
    var backgroundColor: NSColor = .clear {
        didSet {
            guard backgroundColor != oldValue else { return }
            needsDisplay = true
        }
    }
    var font: NSFont?
    var textColor: NSColor?
    var minSize = NSSize(width: 0, height: 0)
    var maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    var isHorizontallyResizable = true
    var selectedRangeStorage = NSRange(location: 0, length: 0)
    var markedTextRangeStorage: NSRange?
    var markedTextAttributedStringStorage: NSAttributedString?
    var mouseDraggingSelectionAnchors: [NSTextSelection]?
    var fragmentViewMap = NSMapTable<NSTextLayoutFragment, SyntaxEditorTextInputView.TextLayoutFragmentView>.weakToWeakObjects()
    var lastUsedFragmentViews: Set<SyntaxEditorTextInputView.TextLayoutFragmentView> = []
    var bracketHighlightRanges: [NSRange] = []
    var bracketHighlightColor: NSColor?
    var fragmentDisplayInvalidationCount = 0
    var syntaxRenderingAttributeApplicationCountForTesting = 0
    var syntaxRenderingAttributeUTF16LengthForTesting = 0
    var syntaxRenderingAttributeColorRunCountForTesting = 0
    var lineMetrics = DocumentLineMetrics(tabWidth: 4)
    var caretGeometryQueryCountForTesting = 0

    init(textSystem: EditorTextSystem) {
        self.textSystem = textSystem
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        unsafe textFinder.client = self
        textSystem.layoutManager.textViewportLayoutController.delegate = self
        textContentView.textInputView = self
        insertionIndicator.displayMode = .hidden
        insertionIndicator.isHidden = true
        textSystem.layoutManager.delegate = self
        addSubview(textContentView)
        addSubview(insertionIndicator)
        incrementalMatchRangesObservation = textFinder.observe(\.incrementalMatchRanges, options: [.new, .old]) { [weak self] _, change in
            let changedRanges: [NSRange]?
            switch change.kind {
            case .insertion:
                changedRanges = change.newValue?.map(\.rangeValue)
            case .removal:
                changedRanges = change.oldValue?.map(\.rangeValue)
            case .replacement:
                changedRanges = ((change.oldValue ?? []) + (change.newValue ?? [])).map(\.rangeValue)
            default:
                changedRanges = nil
            }
            Task { @MainActor in
                self?.handleIncrementalMatchRangesChange(changedRanges: changedRanges)
            }
        }
        configureSyntaxRenderingAttributesValidator()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isSelectable else { return nil }
        unsafe window?.makeFirstResponder(self)
        return makeContextualEditMenu()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let window = unsafe self.window,
           window.firstResponder !== self {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""

        if key.lowercased() == "l",
           modifiers.contains(.command),
           modifiers.contains(.control),
           modifiers.contains(.shift),
           !modifiers.contains(.option),
           shortcutHandler?(.toggleLineWrapping) == true {
            return true
        }

        if key == "0",
           modifiers.contains(.command),
           modifiers.contains(.control),
           !modifiers.contains(.option),
           !modifiers.contains(.shift),
           shortcutHandler?(.resetFontSize) == true {
            return true
        }

        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option)
        else {
            return super.performKeyEquivalent(with: event)
        }

        if key == "+" || key == "=" {
            return shortcutHandler?(.increaseFontSize) == true || super.performKeyEquivalent(with: event)
        }
        if key == "-" {
            return shortcutHandler?(.decreaseFontSize) == true || super.performKeyEquivalent(with: event)
        }
        if key == "/" {
            return shortcutHandler?(.toggleComment) == true || super.performKeyEquivalent(with: event)
        }
        if key == "]" {
            return shortcutHandler?(.indent) == true || super.performKeyEquivalent(with: event)
        }
        if key == "[" {
            return shortcutHandler?(.outdent) == true || super.performKeyEquivalent(with: event)
        }
        if key.lowercased() == "c", canCopySelection {
            copy(nil)
            return true
        }
        if key.lowercased() == "x", canCutSelection {
            cut(nil)
            return true
        }
        if key.lowercased() == "v", canPaste {
            paste(nil)
            return true
        }
        if key.lowercased() == "a", isSelectable {
            selectAll(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if commandHandler?(selector) == true {
            return
        }

        switch selector {
        case #selector(selectAll(_:)):
            selectAll(nil)
        case #selector(insertNewline(_:)):
            insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        case #selector(deleteBackward(_:)):
            deleteBackward()
        case #selector(deleteForward(_:)):
            deleteForward()
        case #selector(moveLeft(_:)):
            moveSelection(direction: .left, destination: .character, extending: false, confined: false)
        case #selector(moveLeftAndModifySelection(_:)):
            moveSelection(direction: .left, destination: .character, extending: true, confined: false)
        case #selector(moveRight(_:)):
            moveSelection(direction: .right, destination: .character, extending: false, confined: false)
        case #selector(moveRightAndModifySelection(_:)):
            moveSelection(direction: .right, destination: .character, extending: true, confined: false)
        case #selector(moveUp(_:)):
            moveSelection(direction: .up, destination: .character, extending: false, confined: false)
        case #selector(moveUpAndModifySelection(_:)):
            moveSelection(direction: .up, destination: .character, extending: true, confined: false)
        case #selector(moveDown(_:)):
            moveSelection(direction: .down, destination: .character, extending: false, confined: false)
        case #selector(moveDownAndModifySelection(_:)):
            moveSelection(direction: .down, destination: .character, extending: true, confined: false)
        case #selector(moveWordLeft(_:)):
            moveSelection(direction: .left, destination: .word, extending: false, confined: false)
        case #selector(moveWordLeftAndModifySelection(_:)):
            moveSelection(direction: .left, destination: .word, extending: true, confined: false)
        case #selector(moveWordRight(_:)):
            moveSelection(direction: .right, destination: .word, extending: false, confined: false)
        case #selector(moveWordRightAndModifySelection(_:)):
            moveSelection(direction: .right, destination: .word, extending: true, confined: false)
        case #selector(moveWordForward(_:)):
            moveSelection(direction: .forward, destination: .word, extending: false, confined: false)
        case #selector(moveWordForwardAndModifySelection(_:)):
            moveSelection(direction: .forward, destination: .word, extending: true, confined: false)
        case #selector(moveWordBackward(_:)):
            moveSelection(direction: .backward, destination: .word, extending: false, confined: false)
        case #selector(moveWordBackwardAndModifySelection(_:)):
            moveSelection(direction: .backward, destination: .word, extending: true, confined: false)
        case #selector(moveToBeginningOfLine(_:)),
             #selector(moveToLeftEndOfLine(_:)):
            moveSelection(direction: .backward, destination: .line, extending: false, confined: true)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)),
             #selector(moveToLeftEndOfLineAndModifySelection(_:)):
            moveSelection(direction: .backward, destination: .line, extending: true, confined: true)
        case #selector(moveToEndOfLine(_:)),
             #selector(moveToRightEndOfLine(_:)):
            moveSelection(direction: .forward, destination: .line, extending: false, confined: true)
        case #selector(moveToEndOfLineAndModifySelection(_:)),
             #selector(moveToRightEndOfLineAndModifySelection(_:)):
            moveSelection(direction: .forward, destination: .line, extending: true, confined: true)
        case #selector(moveToBeginningOfDocument(_:)):
            moveSelection(direction: .backward, destination: .document, extending: false, confined: false)
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)):
            moveSelection(direction: .backward, destination: .document, extending: true, confined: false)
        case #selector(moveToEndOfDocument(_:)):
            moveSelection(direction: .forward, destination: .document, extending: false, confined: false)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)):
            moveSelection(direction: .forward, destination: .document, extending: true, confined: false)
        default:
            break
        }
    }

    override func selectAll(_ sender: Any?) {
        guard isSelectable else { return }
        setSelectedRange(NSRange(location: 0, length: storage.length))
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard usesFindBar else { return }
        configureTextFinder()
        let action = (sender as? NSMenuItem)
            .flatMap { NSTextFinder.Action(rawValue: $0.tag) }
            ?? .showFindInterface
        textFinder.performAction(action)
    }

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
#endif
