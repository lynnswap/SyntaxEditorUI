#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  final class SyntaxEditorReadOnlyGuardedUndoManager: UndoManager {
    var allowsMutation: () -> Bool = { true }

    override var canUndo: Bool {
      allowsMutation() && super.canUndo
    }

    override var canRedo: Bool {
      allowsMutation() && super.canRedo
    }

    override func undo() {
      guard allowsMutation() else { return }
      super.undo()
    }

    override func redo() {
      guard allowsMutation() else { return }
      super.redo()
    }

    override func undoNestedGroup() {
      guard allowsMutation() else { return }
      super.undoNestedGroup()
    }
  }

  @MainActor
  public final class SyntaxEditorView: NSScrollView {
    public private(set) var model: SyntaxEditorModel
    public var isFindInteractionEnabled = true {
      didSet {
        guard isFindInteractionEnabled != oldValue else { return }
        applyFindInteractionConfiguration()
      }
    }

    let fallbackUndoManager = UndoManager()
    let guardedUndoManager = SyntaxEditorReadOnlyGuardedUndoManager()
    let textSystem: EditorTextSystem
    let textView: SyntaxEditorTextInputView
    let textStorage: NSTextStorage
    let layoutManager: NSTextLayoutManager
    let textContainer: NSTextContainer

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
    var isApplyingModel = false
    var isApplyingHighlight = false
    var lastAppliedLanguageIdentifier: String?
    var pendingEditStartUTF16: Int?
    var pendingUndoSelection: NSRange?
    var pendingHighlightEdit: PendingHighlightEdit?
    var pendingHighlightApplication: PendingHighlightApplication?
    var matchedBracketRanges: [NSRange] = []
    var visibleTextDisplayInvalidationCount = 0
    var fullTextDisplayInvalidationCount = 0
    var isApplyingUndoRedo = false
    var isApplyingCommandSelection = false
    var isApplyingLineWrappingConfiguration = false
    var isScrollViewConfigured = false
    var lastAppliedTheme: SyntaxEditorTheme?
    var lastAppliedThemeAppearance: SyntaxEditorTheme.Appearance?
    var lastAppliedFontSizeDelta: Int
    var lastAppliedDocumentRevision = 0
    var modelObservation: PortableObservationTracking.Token?
    var modelConfigurationObservation: PortableObservationTracking.Token?
    var isRetilingForContentInsetsChange = false
    var appliedHighlightPhaseRecordsForTesting: [HighlightPhaseRecord] = []
    var appliedHighlightPhaseWaitersForTesting: [HighlightPhaseWaiter] = []
    var skippedHighlightPhaseRecordsForTesting: [HighlightPhaseRecord] = []
    var skippedHighlightPhaseWaitersForTesting: [HighlightPhaseWaiter] = []
    var nextHighlightPhaseWaiterID = 0

    var scrollView: NSScrollView { self }

    public override var contentInsets: NSEdgeInsets {
      didSet {
        guard contentInsetsDidChange(from: oldValue, to: contentInsets),
          isScrollViewConfigured,
          !isApplyingLineWrappingConfiguration,
          !isRetilingForContentInsetsChange
        else {
          return
        }

        isRetilingForContentInsetsChange = true
        defer { isRetilingForContentInsetsChange = false }
        tile()
      }
    }

    public override var acceptsFirstResponder: Bool {
      true
    }

    public convenience init(
      model: SyntaxEditorModel
    ) {
      self.init(model: model, highlighter: SyntaxHighlighterEngine())
    }

    package init(
      model: SyntaxEditorModel,
      highlighter: any SyntaxEditorHighlighting.Engine
    ) {
      self.model = model
      self.highlighter = highlighter
      self.lastAppliedDocumentRevision = model.textRevision

      let textSystem = EditorTextSystem(
        container: NSTextContainer(
          size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
          )
        )
      )
      let nativeTextView = SyntaxEditorTextInputView(textSystem: textSystem)
      self.textSystem = textSystem
      self.textStorage = textSystem.textStorage
      self.layoutManager = textSystem.layoutManager
      self.textContainer = textSystem.container
      self.textView = nativeTextView
      self.lastAppliedFontSizeDelta = model.fontSizeDelta

      super.init(frame: .zero)

      nativeTextView.guardedUndoManager = guardedUndoManager
      guardedUndoManager.allowsMutation = { [weak self] in
        self?.model.isEditable ?? true
      }
      nativeTextView.shortcutHandler = { [weak self] action in
        guard let self else { return false }
        return self.handleShortcut(action)
      }
      nativeTextView.shortcutValidator = { [weak self] action in
        guard let self else { return false }
        return self.canHandleShortcut(action)
      }
      nativeTextView.commandHandler = { [weak self] selector in
        guard let self else { return false }
        return self.textView(self.textView, doCommandBy: selector)
      }
      nativeTextView.lineWrappingStateProvider = { [weak self] in
        self?.model.lineWrappingEnabled ?? false
      }
      nativeTextView.didChangeMarkedTextRange = { [weak self] in
        self?.syncMarkedTextSuppressionRanges()
      }

      configureScrollView()
      configureTextView()
      startModelObservation(schedulesInitialHighlight: false)
    }

    public func update(model nextModel: SyntaxEditorModel) {
      guard model !== nextModel else { return }

      cancelModelObservations()
      activeUndoManager?.removeAllActions()
      commandEngine.invalidateTransientState()
      clearHighlightCache()
      model = nextModel
      synchronizeReboundModel()
      startModelObservation(schedulesInitialHighlight: false, skipsInitialModelDelivery: true)
    }

    public override func layout() {
      super.layout()
      applyLineWrappingConfiguration(lineWrappingEnabled: model.lineWrappingEnabled)
    }

    public override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      let previousAppearance = lastAppliedThemeAppearance ?? currentThemeAppearance
      let nextAppearance = currentThemeAppearance
      let theme = lastAppliedTheme ?? model.theme
      let baseFontChanged = !resolvedBaseFont(
        for: theme.resolved(for: model.language, appearance: previousAppearance),
        fontSizeDelta: lastAppliedFontSizeDelta
      ).isEqual(
        resolvedBaseFont(
          for: theme.resolved(for: model.language, appearance: nextAppearance),
          fontSizeDelta: lastAppliedFontSizeDelta
        ))
      let hasCachedSyntaxFontRunChanges: Bool
      if previousAppearance != nextAppearance {
        hasCachedSyntaxFontRunChanges = cachedSyntaxFontRunsChanged(
          from: theme,
          previousAppearance: previousAppearance,
          previousFontSizeDelta: lastAppliedFontSizeDelta,
          to: theme,
          nextAppearance: nextAppearance,
          nextFontSizeDelta: lastAppliedFontSizeDelta,
          language: model.language
        )
      } else {
        hasCachedSyntaxFontRunChanges = false
      }
      lastAppliedThemeAppearance = nextAppearance

      updateEditorBackgroundColor()
      applyBaseForegroundColorChange(from: lastAppliedTheme, to: theme)
      updateTextViewFontAndTypingAttributes()
      if baseFontChanged || hasCachedSyntaxFontRunChanges {
        applyResolvedFontsToExistingText()
      }
      reapplyCachedHighlight()
      applyMatchingBracketHighlight(force: true)
    }

    public override func tile() {
      super.tile()
      guard isScrollViewConfigured, !isApplyingLineWrappingConfiguration else { return }

      applyLineWrappingConfiguration(lineWrappingEnabled: model.lineWrappingEnabled)
    }

    public override func reflectScrolledClipView(_ clipView: NSClipView) {
      super.reflectScrolledClipView(clipView)
      guard isScrollViewConfigured, !isApplyingLineWrappingConfiguration else { return }

      textView.layoutVisibleViewportIfNeeded()
    }

    public override func becomeFirstResponder() -> Bool {
      guard let window = unsafe self.window else {
        return textView.becomeFirstResponder()
      }
      if window.firstResponder === textView {
        return true
      }
      return window.makeFirstResponder(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
      highlightTask?.cancel()
      cancelModelObservations()
    }

  }
#endif
