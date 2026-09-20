#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView {
    var textContentStorage: NSTextContentStorage { textSystem.textContentStorage }
    var layoutManager: NSTextLayoutManager { textSystem.layoutManager }
    var container: NSTextContainer { textSystem.container }
    var highlightStyleStore: HighlightRenderSnapshotStore { textSystem.styleStore }
    var modelDeliveryForTesting: PortableObservationTracking.Token? { modelObservation }
    var modelConfigurationDeliveryForTesting: PortableObservationTracking.Token? { modelConfigurationObservation }
    var storage: NSTextStorage {
        textSystem.textStorage
    }

    internal var textStorage: NSTextStorage {
        storage
    }

    internal var textLayoutManager: NSTextLayoutManager? {
        layoutManager
    }

    internal var textContainer: NSTextContainer {
        container
    }

    internal var attributedText: NSAttributedString? {
        storage.copy() as? NSAttributedString
    }

    internal var renderedTextContentFrameForTesting: CGRect {
        textContentView.frame
    }

    internal var bracketHighlightRangesForTesting: [NSRange] {
        matchedBracketRanges
    }

    internal var findFoundRangesForTesting: [NSRange] {
        findFoundRanges
    }

    internal var findHighlightedRangesForTesting: [NSRange] {
        findHighlightedRanges
    }

    internal var findHighlightUpdatePassCountForTesting: Int {
        findHighlightUpdatePassCount
    }

    internal func syntaxForegroundColorForTesting(at location: Int) -> UIColor? {
        guard location >= 0,
              location < storage.length
        else {
            return nil
        }
        return highlightStyleStore.foregroundColor(at: location)
    }

    internal func syntaxFontForTesting(at location: Int) -> UIFont? {
        guard location >= 0,
              location < storage.length
        else {
            return nil
        }
        return highlightStyleStore.font(at: location)
    }

    internal func baseForegroundColorForTesting() -> UIColor? {
        highlightStyleStore.baseForeground
    }

    /// The native find interaction, or `nil` when find is disabled.
    ///
    /// Use this interaction to present the system find interface. The editor
    /// manages its installation through ``isFindInteractionEnabled``.
    public var findInteraction: UIFindInteraction? {
        findCoordinator?.findInteraction
    }

    /// The base font installed by the latest configuration delivery.
    var font: UIFont {
        (typingAttributes[.font] as? UIFont) ?? resolvedBaseFont()
    }

    /// Whether user input can modify the document.
    ///
    /// This property reads and writes the model's `isEditable` value. Disabling
    /// editing prevents user edits and undo or redo from changing the text.
    /// Selection and copying remain available when ``isSelectable`` is `true`,
    /// and programmatic model updates remain available.
    public var isEditable: Bool {
        get { model.isEditable }
        set {
            guard model.isEditable != newValue else { return }
            model.isEditable = newValue
        }
    }

    /// The text currently displayed in the editor.
    ///
    /// Assigning a value replaces the model's document text and updates the
    /// view. The current selection is clamped to the replacement text. This
    /// programmatic replacement is available even when ``isEditable`` is `false`.
    public var text: String {
        get {
            storage.string
        }
        set {
            replaceDocumentText(newValue)
        }
    }

    /// The selection, expressed as a range of UTF-16 code units in ``text``.
    ///
    /// A zero-length range represents the insertion point. Assignments are
    /// clamped to the document bounds, update the model's selection, and
    /// schedule scrolling to reveal the selection. Moving the selection outside
    /// an active marked-text composition clears that composition.
    public var selectedRange: NSRange {
        get {
            currentSelectedRange
        }
        set {
            let nextRange = clampedTextRange(newValue)
            clearMarkedTextIfSelectionLeavesComposition(nextRange)
            setSelectedRange(
                nextRange,
                preservesCommandState: false,
                schedulesSelectionScroll: true
            )
        }
    }

    public var tokenizer: any UITextInputTokenizer {
        if let tokenizerStorage {
            return tokenizerStorage
        }
        let tokenizer = SyntaxEditorView.TextInputTokenizer(textInput: self)
        tokenizerStorage = tokenizer
        return tokenizer
    }

    /// Creates an editor and begins observing the supplied model.
    ///
    /// - Parameter model: The model to display and update through user editing.
    public convenience init(
        model: SyntaxEditorModel
    ) {
        self.init(model: model, highlighter: SyntaxHighlighterEngine())
    }

    /// Switches the editor to another model instance.
    ///
    /// The editor stops observing the previous model, clears its undo history,
    /// and applies the new model's text, selection, and settings. Passing the
    /// current model instance has no effect; its changes are already observed.
    ///
    /// - Parameter nextModel: The model to display and observe.
    public func update(model nextModel: SyntaxEditorModel) {
        guard model !== nextModel else { return }

        cancelModelObservations()
        activeUndoManager?.removeAllActions()
        commandEngine.invalidateTransientState()
        clearHighlightCache()
        model = nextModel
        synchronizeReboundModel()
        refreshKeyboardAccessoryState()
        startModelObservation(schedulesInitialHighlight: false, skipsInitialModelDelivery: true)
    }

    /// The editor's undo manager for user text edits.
    ///
    /// Undo and redo are unavailable while ``isEditable`` is `false`; restoring
    /// editability makes the retained history available again. Switching models
    /// with ``update(model:)`` clears that history.
    public override var undoManager: UndoManager? {
        guardedUndoManager
    }

    #if !os(visionOS)
    public override var inputAccessoryView: UIView? {
        keyboardAccessoryView
    }
    #endif

    public override var canBecomeFirstResponder: Bool {
        isEditable || isSelectable
    }

    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        refreshKeyboardAccessoryState()
        return didBecomeFirstResponder
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshKeyboardAccessoryState()
    }

    public override var keyCommands: [UIKeyCommand]? {
        editorKeyCommands()
    }
}
#endif
