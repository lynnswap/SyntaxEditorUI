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
}
#endif
