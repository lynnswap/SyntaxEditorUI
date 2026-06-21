#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

struct SyntaxEditorMarkedTextUndoAnchor {
    let source: String
    let selectedRange: NSRange
    let refreshStartUTF16: Int
}

@MainActor
public final class SyntaxEditorView: UIScrollView, UITextInput, UITextInputTraits, UITextInteractionDelegate, @preconcurrency NSTextViewportLayoutControllerDelegate {
    public internal(set) var model: SyntaxEditorModel

    let guardedUndoManager = SyntaxEditorReadOnlyGuardedUndoManager()
    let textSystem = EditorTextSystem()
    let textContentView = SyntaxEditorView.TextContentView()
    let editableTextInteraction = UITextInteraction(for: .editable)
    let nonEditableTextInteraction = UITextInteraction(for: .nonEditable)
    var findCoordinator: SyntaxEditorFindCoordinator?
    static let estimatedTabColumnWidth = 4

    let highlighter: any SyntaxEditorHighlighting.Engine
    let commandEngine = EditorCommandEngine()
    var highlightTask: Task<Void, Never>?
    var scheduledHighlightRequest: ScheduledHighlightRequest?
    var nextScheduledHighlightRequestID = 0
    var lastHighlightTokens: [SyntaxEditorHighlighting.Token] = []
    var lastHighlightSource: String?
    var lastHighlightRevision: Int?
    var lastHighlightLanguage: SyntaxLanguage?
    var materializedHighlightPhase: SyntaxEditorHighlighting.Result.Phase?
    var materializedHighlightRevision: Int?
    var materializedHighlightLanguage: SyntaxLanguage?
    var appliedHighlightPhaseRecordsForTesting: [HighlightPhaseRecord] = []
    var appliedHighlightPhaseWaitersForTesting: [HighlightPhaseWaiter] = []
    var skippedHighlightPhaseRecordsForTesting: [HighlightPhaseRecord] = []
    var skippedHighlightPhaseWaitersForTesting: [HighlightPhaseWaiter] = []
    var nextHighlightPhaseWaiterID = 0
    var isApplyingModel = false
    var isApplyingHighlight = false
    var isApplyingUndoRedo = false
    var isApplyingCommandSelection = false
    var lastAppliedLanguageIdentifier: String?
    var matchedBracketRanges: [NSRange] = []
    var lastAppliedLineWrappingEnabled: Bool
    var lastAppliedTheme: SyntaxEditorTheme
    var lastAppliedThemeAppearance: SyntaxEditorTheme.Appearance?
    var lastAppliedFontSizeDelta: Int
    var isApplyingEditorOwnedScroll = false
    var isIgnoringTextInteractionHorizontalOffsetPreservation = false
    var preservedTextInteractionHorizontalOffset: CGFloat?
    var textInteractionHorizontalOffsetLockGeneration = 0
    var lineMetrics = DocumentLineMetrics(tabWidth: SyntaxEditorView.estimatedTabColumnWidth)
    var lastAppliedDocumentRevision = 0
    var isLayingOutText = false
    var needsTextRelayout = false
    var fragmentViewMap = NSMapTable<NSTextLayoutFragment, SyntaxEditorView.TextLayoutFragmentView>.weakToWeakObjects()
    var lastUsedFragmentViews: Set<SyntaxEditorView.TextLayoutFragmentView> = []
    var postLayoutAction: (() -> Void)?
    var markedRange: NSRange?
    var markedTextUndoAnchor: SyntaxEditorMarkedTextUndoAnchor?
    var pendingTextInteractionCaretOverride: SyntaxEditorTextInteractionCaretOverride?
    var isTextInteractionSelectionDrag = false
    var findFoundRanges: [NSRange] = []
    var findHighlightedRanges: [NSRange] = []
    var findDecorationBatchDepth = 0
    var pendingFindDecorationInvalidationRanges: [NSRange] = []
    var findHighlightUpdatePassCount = 0
    #if !os(visionOS)
    var keyboardAccessoryModel: SyntaxEditorKeyboardAccessoryModel?
    var keyboardAccessoryView: UIView?
    #endif
    var modelObservation: PortableObservationTracking.Token?
    var modelConfigurationObservation: PortableObservationTracking.Token?
    public var isFindInteractionEnabled = true {
        didSet {
            guard isFindInteractionEnabled != oldValue else { return }
            updateFindInteraction()
        }
    }

    public var textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0) {
        didSet {
            guard textContainerInset != oldValue else { return }
            invalidateHorizontalMeasurement()
            updateTextContainerForCurrentWrappingMode()
            invalidateTextLayout()
        }
    }

    public var isSelectable = true {
        didSet {
            guard isSelectable != oldValue else { return }
            updateTextInteractions()
        }
    }

    var currentSelectedRange = NSRange(location: 0, length: 0)
    public weak var inputDelegate: UITextInputDelegate?
    var tokenizerStorage: (any UITextInputTokenizer)?
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    var typingAttributes: [NSAttributedString.Key: Any] = [:]

    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var keyboardType: UIKeyboardType = .default
    public var keyboardAppearance: UIKeyboardAppearance = .default
    public var returnKeyType: UIReturnKeyType = .default
    public var enablesReturnKeyAutomatically = false
    public var isSecureTextEntry = false
    public var textContentType: UITextContentType?
    public var passwordRules: UITextInputPasswordRules?

    package init(
        model: SyntaxEditorModel,
        highlighter: any SyntaxEditorHighlighting.Engine
    ) {
        self.model = model
        self.highlighter = highlighter
        self.lastAppliedLineWrappingEnabled = model.lineWrappingEnabled
        self.lastAppliedTheme = model.theme
        self.lastAppliedThemeAppearance = nil
        self.lastAppliedFontSizeDelta = model.fontSizeDelta
        self.lastAppliedDocumentRevision = model.textRevision
        self.lastAppliedLanguageIdentifier = model.language.syntaxHighlightCacheKey

        super.init(frame: .zero)

        configureTextSystem()
        configureScrollView()
        configureUndoObservation()
        configureTraitChangeObservation()
        startModelObservation(schedulesInitialHighlight: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        highlightTask?.cancel()
        cancelModelObservations()
        NotificationCenter.default.removeObserver(self)
    }
}
#endif
