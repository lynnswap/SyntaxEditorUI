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

/// A UIKit text-input and scroll view backed by an app-owned model.
///
/// Use the model to observe text and selection changes or update editor
/// settings. The view manages text input, syntax rendering, and scrolling;
/// the app remains responsible for loading and saving the document.
///
/// The editor itself implements `UITextInput`; it does not contain a public
/// `UITextView`. Configure text through ``model``, ``text``, and
/// ``selectedRange``, and use inherited `UIScrollView` properties for scrolling.
@MainActor
public final class SyntaxEditorView: UIScrollView, UITextInput, UITextInputTraits, UITextInteractionDelegate, @preconcurrency NSTextViewportLayoutControllerDelegate {
    /// The retained model that owns the editor's text, selection, and settings.
    ///
    /// To display another model instance, call ``update(model:)``.
    public internal(set) var model: SyntaxEditorModel

    let guardedUndoManager = SyntaxEditorReadOnlyGuardedUndoManager()
    let textSystem = EditorTextSystem()
    let textContentView = SyntaxEditorView.TextContentView()
    weak var comparisonLayout: SyntaxEditorComparisonTextLayout?
    weak var inlineComparisonLayout: SyntaxEditorInlineComparisonLayout?
    var needsInlineComparisonLayout = false
    let comparisonMarginFragments = NSHashTable<SyntaxEditorComparisonTextLayoutFragment>.weakObjects()
    var didUpdateSyntaxRendering: (([NSRange]) -> Void)?
    var didChangeComparisonViewport: (() -> Void)?
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
    var isPerformingTextInteractionRectScroll = false
    var preservedTextInteractionHorizontalOffset: CGFloat?
    var preservedTextInteractionOffsetSuppressesDirectScrolls = false
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
    /// Whether the editor installs a native find interaction.
    ///
    /// The default is `true`. Setting this value to `false` ends active search,
    /// removes its decorations, and makes ``findInteraction`` return `nil`.
    /// Find remains available when ``isEditable`` is `false`.
    public var isFindInteractionEnabled = true {
        didSet {
            guard isFindInteractionEnabled != oldValue else { return }
            updateFindInteraction()
        }
    }

    /// Insets, in points, between the text container and the editor's content.
    ///
    /// The default adds 8 points above and below the text and no horizontal
    /// inset. Changes update text layout, including the width used for wrapping.
    public var textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0) {
        didSet {
            guard textContainerInset != oldValue else { return }
            invalidateHorizontalMeasurement()
            updateTextContainerForCurrentWrappingMode()
            invalidateTextLayout()
        }
    }

    /// Whether selection-only interaction and selection commands are enabled.
    ///
    /// The default is `true`. When ``isEditable`` is `false`, this property
    /// controls whether the editor installs a noneditable text interaction for
    /// selecting and copying text. Programmatic selection remains available.
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
