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

    public var findInteraction: UIFindInteraction? {
        findCoordinator?.findInteraction
    }

    var font: UIFont {
        resolvedBaseFont()
    }

    public var isEditable: Bool {
        get { model.isEditable }
        set {
            guard model.isEditable != newValue else { return }
            model.isEditable = newValue
        }
    }

    public var text: String {
        get {
            storage.string
        }
        set {
            replaceDocumentText(newValue)
        }
    }

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

    public convenience init(
        model: SyntaxEditorModel
    ) {
        self.init(model: model, highlighter: SyntaxHighlighterEngine())
    }

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
