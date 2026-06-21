#if canImport(AppKit)
import AppKit
import ObservationBridge
import SyntaxEditorCore
import SyntaxEditorUICommon

enum EditorShortcutAction {
    case indent
    case outdent
    case toggleComment
    case toggleLineWrapping
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
}

extension EditorShortcutAction {
    init?(command: SyntaxEditorMenu.Command) {
        switch command {
        case .shiftRight:
            self = .indent
        case .shiftLeft:
            self = .outdent
        case .commentSelection:
            self = .toggleComment
        case .wrapLines:
            self = .toggleLineWrapping
        case .increaseFontSize:
            self = .increaseFontSize
        case .decreaseFontSize:
            self = .decreaseFontSize
        case .resetFontSize:
            self = .resetFontSize
        }
    }
}

private struct PendingHighlightApplication {
    let tokens: [SyntaxEditorHighlighting.Token]
    let expectedRevision: Int
    let source: String
    let language: SyntaxLanguage
    let refreshRanges: [NSRange]
    let mutation: SyntaxEditorTextChange.Replacement?
    let recordsCache: Bool
    let phase: SyntaxEditorHighlighting.Result.Phase
    let tokenPayload: SyntaxEditorHighlighting.Result.Payload
}

private struct ScheduledHighlightRequest {
    let id: Int
    let model: SyntaxEditorModel
    let language: SyntaxLanguage
    let revision: Int
    let mutation: SyntaxEditorTextChange.Replacement?
}

private enum PendingHighlightEdit {
    case incremental(SyntaxEditorTextChange.Replacement)
    case fullReset
}

private struct SyntaxHighlightAttributeKey: Hashable {
    let syntaxID: EditorSourceSyntax.ID
    let language: SyntaxLanguage
}

private struct SyntaxHighlightStyle {
    let foregroundColor: NSColor
    let font: NSFont
}

private struct SyntaxHighlightResolvedStyle {
    let key: SyntaxHighlightAttributeKey
    let attributes: SyntaxHighlightStyle
}

private struct HighlightPhaseRecord: Equatable {
    let revision: Int
    let phase: SyntaxEditorHighlighting.Result.Phase
}

private struct HighlightPhaseWaiter {
    let id: Int
    let revision: Int
    let phase: SyntaxEditorHighlighting.Result.Phase
    let continuation: CheckedContinuation<Bool, Never>
}

private struct SyntaxHighlightAttributeResolver {
    let theme: SyntaxEditorTheme
    let defaultLanguage: SyntaxLanguage
    let appearance: SyntaxEditorTheme.Appearance
    let fontSizeDelta: Int

    private var styleCache: [SyntaxHighlightAttributeKey: SyntaxHighlightStyle] = [:]
    private var missingAttributeKeys: Set<SyntaxHighlightAttributeKey> = []
    private var fontCache: [SyntaxEditorTheme.FontDescriptor: NSFont] = [:]

    init(
        theme: SyntaxEditorTheme,
        defaultLanguage: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance,
        fontSizeDelta: Int
    ) {
        self.theme = theme
        self.defaultLanguage = defaultLanguage
        self.appearance = appearance
        self.fontSizeDelta = fontSizeDelta
    }

    mutating func style(
        for syntaxID: EditorSourceSyntax.ID,
        language: SyntaxLanguage?
    ) -> (key: SyntaxHighlightAttributeKey, style: SyntaxHighlightStyle)? {
        let effectiveLanguage = language ?? defaultLanguage
        let key = SyntaxHighlightAttributeKey(syntaxID: syntaxID, language: effectiveLanguage)

        if let cached = styleCache[key] {
            return (key, cached)
        }
        guard !missingAttributeKeys.contains(key) else {
            return nil
        }

        guard let style = SyntaxEditorHighlightTheme.style(
            for: syntaxID,
            in: theme,
            language: effectiveLanguage,
            appearance: appearance
        ) else {
            missingAttributeKeys.insert(key)
            return nil
        }

        let resolvedStyle = SyntaxHighlightStyle(
            foregroundColor: style.foreground,
            font: platformFont(for: style.font)
        )
        styleCache[key] = resolvedStyle
        return (key, resolvedStyle)
    }

    private mutating func platformFont(for descriptor: SyntaxEditorTheme.FontDescriptor) -> NSFont {
        if let cached = fontCache[descriptor] {
            return cached
        }
        let font = descriptor.platformFont(fontSizeDelta: fontSizeDelta)
        fontCache[descriptor] = font
        return font
    }
}

@MainActor
private final class SyntaxEditorReadOnlyGuardedUndoManager: UndoManager {
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

    private let fallbackUndoManager = UndoManager()
    private let guardedUndoManager = SyntaxEditorReadOnlyGuardedUndoManager()
    let textSystem: EditorTextSystem
    let textView: SyntaxEditorTextInputView
    let textStorage: NSTextStorage
    let layoutManager: NSTextLayoutManager
    private let textContainer: NSTextContainer

    private let highlighter: any SyntaxEditorHighlighting.Engine
    private let commandEngine = EditorCommandEngine()
    private var highlightTask: Task<Void, Never>?
    private var scheduledHighlightRequest: ScheduledHighlightRequest?
    private var nextScheduledHighlightRequestID = 0
    private var lastHighlightTokens: [SyntaxEditorHighlighting.Token] = []
    private var lastHighlightSource: String?
    private var lastHighlightRevision: Int?
    private var lastHighlightLanguage: SyntaxLanguage?
    private var materializedHighlightPhase: SyntaxEditorHighlighting.Result.Phase?
    private var materializedHighlightRevision: Int?
    private var materializedHighlightLanguage: SyntaxLanguage?
    private var isApplyingModel = false
    private var isApplyingHighlight = false
    private var lastAppliedLanguageIdentifier: String?
    private var pendingEditStartUTF16: Int?
    private var pendingUndoSelection: NSRange?
    private var pendingHighlightEdit: PendingHighlightEdit?
    private var pendingHighlightApplication: PendingHighlightApplication?
    var matchedBracketRanges: [NSRange] = []
    private var visibleTextDisplayInvalidationCount = 0
    private var fullTextDisplayInvalidationCount = 0
    private var isApplyingUndoRedo = false
    private var isApplyingCommandSelection = false
    private var isApplyingLineWrappingConfiguration = false
    private var isScrollViewConfigured = false
    private var lastAppliedTheme: SyntaxEditorTheme?
    private var lastAppliedThemeAppearance: SyntaxEditorTheme.Appearance?
    private var lastAppliedFontSizeDelta: Int
    private var lastAppliedDocumentRevision = 0
    private var modelObservation: PortableObservationTracking.Token?
    private var modelConfigurationObservation: PortableObservationTracking.Token?
    private var isRetilingForContentInsetsChange = false
    var modelDeliveryForTesting: PortableObservationTracking.Token? { modelObservation }
    var modelConfigurationDeliveryForTesting: PortableObservationTracking.Token? { modelConfigurationObservation }
    private var appliedHighlightPhaseRecordsForTesting: [HighlightPhaseRecord] = []
    private var appliedHighlightPhaseWaitersForTesting: [HighlightPhaseWaiter] = []
    private var skippedHighlightPhaseRecordsForTesting: [HighlightPhaseRecord] = []
    private var skippedHighlightPhaseWaitersForTesting: [HighlightPhaseWaiter] = []
    private var nextHighlightPhaseWaiterID = 0

    private var scrollView: NSScrollView { self }

    private func contentInsetsDidChange(from oldValue: NSEdgeInsets, to newValue: NSEdgeInsets) -> Bool {
        oldValue.top != newValue.top
            || oldValue.left != newValue.left
            || oldValue.bottom != newValue.bottom
            || oldValue.right != newValue.right
    }

    public var text: String {
        get { textView.string }
        set {
            guard let change = model.replaceText(newValue, selectedRange: selectedRange) else {
                updateTypingAttributes()
                return
            }
            applyObservedModelChange(forceTextUpdate: true, observedRevision: change.textRevision)
        }
    }

    public var selectedRange: NSRange {
        get { textView.selectedRange() }
        set {
            textView.setSelectedRange(newValue)
            model.selectedRange = textView.selectedRange()
        }
    }

    public var isEditable: Bool {
        get { model.isEditable }
        set {
            guard model.isEditable != newValue else { return }
            model.isEditable = newValue
        }
    }

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

    internal func synchronizeDocumentForTesting() {
        applyObservedConfiguration(
            language: model.language,
            isEditable: model.isEditable,
            lineWrappingEnabled: model.lineWrappingEnabled,
            theme: model.theme,
            drawsBackground: model.drawsBackground,
            fontSizeDelta: model.fontSizeDelta
        )
        applyObservedModelChange()
        applyObservedSelection(model.selectedRange)
    }

    @discardableResult
    internal func waitForPendingHighlightForTesting() async -> Bool {
        // Deterministic: a result that cannot apply yet (payload gating,
        // revision races) reschedules and lets its task complete unapplied, so
        // follow reschedules by generation until a waited task finishes
        // without scheduling a successor. No wall-clock is involved — a
        // pipeline that never settles is a real bug and surfaces as the
        // suite's time limit, never as a racy early false.
        while true {
            guard let task = highlightTask else { return true }
            let generation = nextScheduledHighlightRequestID
            await task.value
            if nextScheduledHighlightRequestID == generation {
                return true
            }
        }
    }

    internal func waitForAppliedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase
    ) async -> Bool {
        let expectedRevision = model.textRevision
        guard !hasAppliedHighlightPhaseForTesting(phase, revision: expectedRevision) else {
            return true
        }

        let waiterID = nextHighlightPhaseWaiterID
        nextHighlightPhaseWaiterID += 1
        return await withCheckedContinuation { continuation in
            appliedHighlightPhaseWaitersForTesting.append(
                HighlightPhaseWaiter(
                    id: waiterID,
                    revision: expectedRevision,
                    phase: phase,
                    continuation: continuation
                )
            )
        }
    }

    internal func waitForSkippedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase
    ) async -> Bool {
        let expectedRevision = model.textRevision
        guard !hasSkippedHighlightPhaseForTesting(phase, revision: expectedRevision) else {
            return true
        }

        let waiterID = nextHighlightPhaseWaiterID
        nextHighlightPhaseWaiterID += 1
        return await withCheckedContinuation { continuation in
            skippedHighlightPhaseWaitersForTesting.append(
                HighlightPhaseWaiter(
                    id: waiterID,
                    revision: expectedRevision,
                    phase: phase,
                    continuation: continuation
                )
            )
        }
    }

    internal func setApplyingHighlightForTesting(_ isApplying: Bool) {
        isApplyingHighlight = isApplying
    }

    internal var bracketHighlightRangesForTesting: [NSRange] {
        matchedBracketRanges
    }

    internal var visibleTextDisplayInvalidationCountForTesting: Int {
        visibleTextDisplayInvalidationCount
    }

    internal var fullTextDisplayInvalidationCountForTesting: Int {
        fullTextDisplayInvalidationCount
    }

    internal var fragmentDisplayInvalidationCountForTesting: Int {
        textView.fragmentDisplayInvalidationCount
    }

    internal var syntaxForegroundMaterializationCountForTesting: Int {
        textSystem.styleStore.epoch
    }

    internal var syntaxRenderingAttributeApplicationCountForTesting: Int {
        textView.syntaxRenderingAttributeApplicationCountForTesting
    }

    internal var syntaxColorRunCountForTesting: Int {
        textSystem.styleStore.appliedColorRunsForTesting.count
    }

    internal var lineMetricsFullRebuildCountForTesting: Int {
        textView.lineMetrics.fullRebuildCount
    }

    internal func materializeSyntaxForegroundForTesting(in range: NSRange) {
        textView.setNeedsDisplayForTextRanges([range])
    }

    internal func syntaxForegroundColorForTesting(at location: Int) -> NSColor? {
        guard location >= 0,
              location < textStorage.length
        else {
            return nil
        }
        return textSystem.styleStore.foregroundColor(at: location)
    }

    internal func syntaxFontForTesting(at location: Int) -> NSFont? {
        guard location >= 0,
              location < textStorage.length
        else {
            return nil
        }
        return textSystem.styleStore.font(at: location)
    }

    internal func baseForegroundColorForTesting() -> NSColor? {
        textSystem.styleStore.baseForeground
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        highlightTask?.cancel()
        cancelModelObservations()
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
        ).isEqual(resolvedBaseFont(
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

    public override var acceptsFirstResponder: Bool {
        true
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

    public func textDidChange(_ notification: Notification) {
        textDidChange()
    }

    private func textDidChange() {
        guard !isApplyingModel else {
            clearPendingTextChangeState()
            return
        }

        let previousText = model.text
        let nextText = textView.string
        if isApplyingHighlight, nextText == previousText {
            clearPendingTextChangeState()
            return
        }

        let change: SyntaxEditorTextChange?
        let mutation: SyntaxEditorTextChange.Replacement?
        switch pendingHighlightEdit {
        case let .incremental(pendingMutation):
            mutation = pendingMutation
            change = model.commitTextReplacements(
                [
                    SyntaxEditorTextChange.Replacement(
                        range: NSRange(location: pendingMutation.location, length: pendingMutation.length),
                        replacement: pendingMutation.replacement
                    ),
                ],
                selectedRange: textView.selectedRange()
            )
        case .fullReset:
            mutation = nil
            change = model.replaceText(nextText, selectedRange: textView.selectedRange())
        case .none:
            mutation = SyntaxEditorTextChange.Replacement.singleReplacement(from: previousText, to: nextText)
            if let mutation {
                change = model.commitTextReplacements(
                    [
                        SyntaxEditorTextChange.Replacement(
                            range: NSRange(location: mutation.location, length: mutation.length),
                            replacement: mutation.replacement
                        ),
                    ],
                    selectedRange: textView.selectedRange()
                )
            } else {
                change = model.replaceText(nextText, selectedRange: textView.selectedRange())
            }
        }
        guard let change else {
            model.selectedRange = textView.selectedRange()
            clearPendingTextChangeState()
            return
        }
        lastAppliedDocumentRevision = change.textRevision

        let editStartUTF16 = pendingEditStartUTF16 ?? textView.selectedRange().location
        let previousSelection = pendingUndoSelection
        clearPendingTextChangeState()
        let refreshStartUTF16 = SyntaxEditorRangeUtilities.lineStartUTF16Offset(
            in: nextText,
            around: editStartUTF16
        )
        if !isApplyingUndoRedo {
            registerUndoForTextInput(
                previousText: previousText,
                nextText: nextText,
                previousSelection: previousSelection,
                nextSelection: textView.selectedRange(),
                mutation: mutation,
                refreshStartUTF16: refreshStartUTF16
            )
        }
        prepareSyntaxHighlightRenderingForPendingTextChange(
            mutation: mutation,
            source: nextText,
            refreshStartUTF16: refreshStartUTF16
        )
        scheduleHighlight(
            source: nextText,
            language: model.language,
            revision: change.textRevision,
            mutation: mutation,
            refreshStartUTF16: refreshStartUTF16
        )
    }

    private func clearPendingTextChangeState() {
        pendingEditStartUTF16 = nil
        pendingUndoSelection = nil
        pendingHighlightEdit = nil
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        textSelectionDidChange()
    }

    private func textSelectionDidChange() {
        if !isApplyingModel {
            model.selectedRange = textView.selectedRange()
        }
        if !isApplyingCommandSelection {
            commandEngine.invalidateTransientState()
        }
        applyMatchingBracketHighlight()
        applyPendingHighlightIfSelectionAllows()
    }

    private func textShouldChange(inRanges affectedRanges: [NSRange], replacementStrings: [String]) -> Bool {
        guard let affectedCharRange = affectedRanges.first else { return true }
        let usesSingleReplacement = affectedRanges.count == 1 && replacementStrings.count == 1
        guard !isApplyingModel else {
            clearPendingTextChangeState()
            return true
        }

        guard model.isEditable else {
            clearPendingTextChangeState()
            return false
        }

        pendingEditStartUTF16 = affectedCharRange.location
        pendingUndoSelection = affectedCharRange
        guard usesSingleReplacement, let replacementString = replacementStrings.first else {
            pendingHighlightEdit = .fullReset
            return true
        }

        pendingHighlightEdit = .incremental(
            SyntaxEditorTextChange.Replacement(
                location: affectedCharRange.location,
                length: affectedCharRange.length,
                replacement: replacementString
            )
        )

        let source = textView.string
        if let result = commandEngine.transformInput(
            source: source,
            range: affectedCharRange,
            replacementText: replacementString,
            language: model.language
        ) {
            applyCommandResult(result)
            return false
        }

        return true
    }

    func textView(
        _ textView: SyntaxEditorTextInputView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        textShouldChange(
            inRanges: [affectedCharRange],
            replacementStrings: replacementString.map { [$0] } ?? []
        )
    }

    func textView(_ textView: SyntaxEditorTextInputView, doCommandBy commandSelector: Selector) -> Bool {
        guard model.isEditable else {
            return false
        }

        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            return runInsertTabCommand()
        case #selector(NSResponder.insertBacktab(_:)):
            return runOutdentCommand()
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let selectedRange = textView.selectedRange()
            if let result = commandEngine.transformInput(
                source: textView.string,
                range: selectedRange,
                replacementText: "\n",
                language: model.language
            ) {
                applyCommandResult(result)
                return true
            }
            return false
        case #selector(NSResponder.deleteBackward(_:)):
            let selectedRange = textView.selectedRange()
            let deleteRange: NSRange
            let deletionIntent: EditorCommandEngine.DeletionIntent
            if selectedRange.length > 0 {
                deleteRange = selectedRange
                deletionIntent = .unspecified
            } else {
                guard selectedRange.location > 0 else { return false }
                deleteRange = NSRange(location: selectedRange.location - 1, length: 1)
                deletionIntent = .backward
            }

            if let result = commandEngine.transformInput(
                source: textView.string,
                range: deleteRange,
                replacementText: "",
                language: model.language,
                deletionIntent: deletionIntent
            ) {
                applyCommandResult(result)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func configureScrollView() {
        scrollView.drawsBackground = model.drawsBackground
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !model.lineWrappingEnabled
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        isScrollViewConfigured = true
    }

    private func configureTextView() {
        textView.drawsBackground = false
        updateEditorBackgroundColor()
        textView.isEditable = model.isEditable
        textView.guardedUndoManager = guardedUndoManager
        textView.didChangeText = { [weak self] in
            self?.textDidChange()
        }
        textView.didChangeSelection = { [weak self] in
            self?.textSelectionDidChange()
        }
        textView.shouldChangeText = { [weak self] ranges, replacements in
            self?.textShouldChange(inRanges: ranges, replacementStrings: replacements) ?? true
        }
        applyFindInteractionConfiguration()
        configureBaseTextViewAppearance()

        applyLineWrappingConfiguration(lineWrappingEnabled: model.lineWrappingEnabled)
    }

    private func applyFindInteractionConfiguration() {
        if isFindInteractionEnabled {
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.usesFindPanel = false
        } else {
            isFindBarVisible = false
            textView.usesFindBar = false
            textView.isIncrementalSearchingEnabled = false
            textView.usesFindPanel = false
        }
    }

    private var activeUndoManager: UndoManager? {
        textView.undoManager ?? fallbackUndoManager
    }

    private func configureBaseTextViewAppearance() {
        let base = baseAttributes()
        updateRenderingBaseForeground(from: base)
        textView.font = base[.font] as? NSFont ?? textView.font
        textView.textColor = base[.foregroundColor] as? NSColor ?? textView.textColor
        textView.typingAttributes = base
    }

    private func updateTextViewFontAndTypingAttributes() {
        let base = baseAttributes()
        updateRenderingBaseForeground(from: base)
        textView.font = base[.font] as? NSFont ?? textView.font
        textView.typingAttributes = base
    }

    private func updateTypingAttributes() {
        let base = baseAttributes()
        updateRenderingBaseForeground(from: base)
        textView.typingAttributes = base
    }

    private func updateRenderingBaseForeground(from base: [NSAttributedString.Key: Any]) {
        textSystem.styleStore.updateBaseForeground(
            base[.foregroundColor] as? NSColor,
            textLength: textStorage.length
        )
    }

    private func startModelObservation(
        schedulesInitialHighlight: Bool = true,
        skipsInitialModelDelivery: Bool = false
    ) {
        let model = model
        modelConfigurationObservation = withPortableContinuousObservation { [weak self, model] event in
            guard let self else { return }

            let language = model.language
            let isEditable = model.isEditable
            let lineWrappingEnabled = model.lineWrappingEnabled
            let theme = model.theme
            let drawsBackground = model.drawsBackground
            let fontSizeDelta = model.fontSizeDelta

            self.applyObservedConfiguration(
                language: language,
                isEditable: isEditable,
                lineWrappingEnabled: lineWrappingEnabled,
                theme: theme,
                drawsBackground: drawsBackground,
                fontSizeDelta: fontSizeDelta,
                forceLanguageRefresh: event.kind == .initial,
                schedulesHighlight: event.kind != .initial || schedulesInitialHighlight
            )
        }

        modelObservation = withPortableContinuousObservation { [weak self, model] event in
            guard let self else { return }

            _ = model.text
            let revision = model.textRevision
            let selectedRange = model.selectedRange

            guard !(skipsInitialModelDelivery && event.kind == .initial) else { return }
            self.applyObservedModelChange(
                forceTextUpdate: event.kind == .initial,
                observedRevision: revision
            )
            self.applyObservedSelection(selectedRange)
        }
    }

    private func cancelModelObservations() {
        modelConfigurationObservation?.cancel()
        modelConfigurationObservation = nil
        modelObservation?.cancel()
        modelObservation = nil
    }

    private func synchronizeReboundModel() {
        applyObservedConfiguration(
            language: model.language,
            isEditable: model.isEditable,
            lineWrappingEnabled: model.lineWrappingEnabled,
            theme: model.theme,
            drawsBackground: model.drawsBackground,
            fontSizeDelta: model.fontSizeDelta,
            forceLanguageRefresh: true,
            schedulesHighlight: false
        )
        applyObservedModelChange(forceTextUpdate: true, observedRevision: model.textRevision)
        applyObservedSelection(model.selectedRange)
    }

    private func applyObservedModelChange(forceTextUpdate: Bool = false, observedRevision: Int? = nil) {
        let revision = observedRevision ?? model.textRevision
        guard forceTextUpdate || revision != lastAppliedDocumentRevision else { return }

        isApplyingModel = true
        defer {
            isApplyingModel = false
        }

        let text = model.text
        let textNeedsUpdate = forceTextUpdate || textView.string != text
        var highlightMutation: SyntaxEditorTextChange.Replacement?
        if textNeedsUpdate {
            commandEngine.invalidateTransientState()
            let change = model.latestTextChange
            if change?.kind == .wholeDocumentReplacement {
                activeUndoManager?.removeAllActions()
            }
            let canApplyIncrementally = change.map {
                $0.textRevision == revision
                    && $0.kind == .incremental
                    && !forceTextUpdate
                    && lastAppliedDocumentRevision == revision - 1
            } ?? false
            let didApplyIncrementally = if canApplyIncrementally, let change {
                applyStorageTextEdits(change.replacements)
            } else {
                false
            }
            if didApplyIncrementally {
                highlightMutation = change.flatMap(Self.highlightMutation)
            } else {
                replaceEntireStorageText(text)
            }
            if let change,
               !(change.kind == .wholeDocumentReplacement && change.selectedRange == NSRange(location: 0, length: 0)) {
                textView.setSelectedRange(change.selectedRange)
            }
        }

        updateTypingAttributes()
        if textNeedsUpdate {
            prepareSyntaxHighlightRenderingForPendingTextChange(
                mutation: highlightMutation,
                source: text,
                refreshStartUTF16: 0
            )
            scheduleHighlight(
                source: text,
                language: model.language,
                revision: revision,
                mutation: highlightMutation,
                refreshStartUTF16: 0
            )
        }
        lastAppliedDocumentRevision = revision
    }

    private func applyObservedSelection(_ range: NSRange) {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textStorage.length)
        guard textView.selectedRange() != clamped else { return }

        isApplyingModel = true
        defer {
            isApplyingModel = false
        }
        textView.setSelectedRange(clamped)
    }

    private func applyObservedConfiguration(
        language: SyntaxLanguage,
        isEditable: Bool,
        lineWrappingEnabled: Bool,
        theme: SyntaxEditorTheme,
        drawsBackground: Bool,
        fontSizeDelta: Int,
        forceLanguageRefresh: Bool = false,
        schedulesHighlight: Bool = true
    ) {
        let previousTheme = lastAppliedTheme
        let themeChanged = previousTheme.map { $0 != theme } ?? true
        let fontSizeDeltaChanged = lastAppliedFontSizeDelta != fontSizeDelta
        let appearance = currentThemeAppearance
        let previousEffectiveTheme = previousTheme ?? theme
        let previousBaseFont = resolvedBaseFont(
            for: previousEffectiveTheme.resolved(for: language, appearance: appearance),
            fontSizeDelta: lastAppliedFontSizeDelta
        )
        let nextBaseFont = resolvedBaseFont(
            for: theme.resolved(for: language, appearance: appearance),
            fontSizeDelta: fontSizeDelta
        )
        let baseFontChanged = !previousBaseFont.isEqual(nextBaseFont)
        let hasCachedSyntaxFontRunChanges: Bool
        if themeChanged || fontSizeDeltaChanged {
            hasCachedSyntaxFontRunChanges = cachedSyntaxFontRunsChanged(
                from: previousEffectiveTheme,
                previousAppearance: appearance,
                previousFontSizeDelta: lastAppliedFontSizeDelta,
                to: theme,
                nextAppearance: appearance,
                nextFontSizeDelta: fontSizeDelta,
                language: language,
                revision: lastAppliedDocumentRevision
            )
        } else {
            hasCachedSyntaxFontRunChanges = false
        }
        if themeChanged {
            applyBaseForegroundColorChange(from: previousTheme, to: theme, language: language)
        }
        lastAppliedTheme = theme
        lastAppliedThemeAppearance = appearance
        lastAppliedFontSizeDelta = fontSizeDelta
        updateTextViewFontAndTypingAttributes()
        if baseFontChanged || hasCachedSyntaxFontRunChanges {
            applyResolvedFontsToExistingText(
                source: textView.string,
                language: language,
                revision: lastAppliedDocumentRevision
            )
        }
        updateEditorBackgroundColor(drawsBackground: drawsBackground)

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        applyLineWrappingConfiguration(lineWrappingEnabled: lineWrappingEnabled)

        let languageChanged = forceLanguageRefresh || lastAppliedLanguageIdentifier != language.syntaxHighlightCacheKey
        lastAppliedLanguageIdentifier = language.syntaxHighlightCacheKey

        if languageChanged && schedulesHighlight {
            scheduleHighlight(
                source: textView.string,
                language: language,
                revision: lastAppliedDocumentRevision,
                refreshStartUTF16: 0
            )
        } else if (themeChanged || fontSizeDeltaChanged) && schedulesHighlight {
            reapplyCachedHighlight(
                source: textView.string,
                language: language,
                revision: lastAppliedDocumentRevision
            )
        }
    }

    private func applyBaseForegroundColorChange(
        from _: SyntaxEditorTheme?,
        to theme: SyntaxEditorTheme,
        language: SyntaxLanguage? = nil
    ) {
        let language = language ?? model.language
        let nextBaseForeground = theme
            .resolved(for: language, appearance: currentThemeAppearance)
            .baseForeground
        textSystem.styleStore.updateBaseForeground(nextBaseForeground, textLength: textStorage.length)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        if fullRange.length > 0 {
            TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
                textStorage.addAttribute(.foregroundColor, value: nextBaseForeground, range: fullRange)
            }
        }
        invalidateVisibleTextDisplay()
    }

    private func applyCommandResult(_ result: EditorCommandEngine.Result) {
        guard model.isEditable else {
            return
        }

        let previousText = textView.string
        let previousSelection = textView.selectedRange()
        let textChanged = !result.edits.isEmpty
        let nextText = textChanged
            ? SyntaxEditorModel.applying(result.edits, to: previousText)
            : previousText

        let undoState: (restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState)? =
            if textChanged, !isApplyingUndoRedo {
                (
                    EditorCommandEngine.UndoState(
                        edits: SyntaxEditorModel.inverseReplacements(for: result.edits, in: previousText),
                        selectedRange: previousSelection,
                        refreshStartUTF16: 0
                    ),
                    EditorCommandEngine.UndoState(
                        edits: result.edits,
                        selectedRange: result.selectedRange,
                        refreshStartUTF16: result.refreshStartUTF16
                    )
                )
            } else {
                nil
            }

        isApplyingModel = true
        if textChanged, !applyTextEdits(result.edits) {
            isApplyingModel = false
            return
        }
        isApplyingCommandSelection = true
        textView.setSelectedRange(result.selectedRange)
        isApplyingCommandSelection = false
        textView.typingAttributes = baseAttributes()
        isApplyingModel = false
        if !textChanged {
            model.selectedRange = textView.selectedRange()
        }

        clearPendingTextChangeState()

        if let undoState {
            registerUndoAction(restore: undoState.restore, counterpart: undoState.counterpart)
        }

        var change: SyntaxEditorTextChange?
        if textChanged {
            change = model.commitTextReplacements(result.edits, selectedRange: result.selectedRange)
            lastAppliedDocumentRevision = change?.textRevision ?? lastAppliedDocumentRevision
        }

        if textChanged {
            let mutation = change.flatMap(Self.highlightMutation)
            prepareSyntaxHighlightRenderingForPendingTextChange(
                mutation: mutation,
                source: nextText,
                refreshStartUTF16: result.refreshStartUTF16
            )
            scheduleHighlight(
                source: nextText,
                language: model.language,
                revision: change?.textRevision ?? model.textRevision,
                mutation: mutation,
                refreshStartUTF16: result.refreshStartUTF16
            )
        } else {
            applyMatchingBracketHighlight()
        }
    }

    private func registerUndoAction(restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState) {
        guard restore != counterpart else { return }
        guard let activeUndoManager = activeUndoManager else { return }

        registerUndoAction(restore: restore, counterpart: counterpart, in: activeUndoManager)
    }

    private func registerUndoForTextInput(
        previousText: String,
        nextText: String,
        previousSelection: NSRange?,
        nextSelection: NSRange,
        mutation: SyntaxEditorTextChange.Replacement?,
        refreshStartUTF16: Int
    ) {
        let edits: [SyntaxEditorTextChange.Replacement]
        let restoreEdits: [SyntaxEditorTextChange.Replacement]
        if let mutation {
            edits = [
                SyntaxEditorTextChange.Replacement(
                    range: NSRange(location: mutation.location, length: mutation.length),
                    replacement: mutation.replacement
                ),
            ]
            restoreEdits = SyntaxEditorModel.inverseReplacements(for: edits, in: previousText)
        } else {
            edits = [
                SyntaxEditorTextChange.Replacement(
                    range: NSRange(location: 0, length: previousText.utf16.count),
                    replacement: nextText
                ),
            ]
            restoreEdits = [
                SyntaxEditorTextChange.Replacement(
                    range: NSRange(location: 0, length: nextText.utf16.count),
                    replacement: previousText
                ),
            ]
        }

        registerUndoAction(
            restore: EditorCommandEngine.UndoState(
                edits: restoreEdits,
                selectedRange: previousSelection ?? NSRange(location: 0, length: 0),
                refreshStartUTF16: refreshStartUTF16
            ),
            counterpart: EditorCommandEngine.UndoState(
                edits: edits,
                selectedRange: nextSelection,
                refreshStartUTF16: refreshStartUTF16
            )
        )
    }

    private func registerUndoAction(
        restore: EditorCommandEngine.UndoState,
        counterpart: EditorCommandEngine.UndoState,
        in undoManager: UndoManager
    ) {
        guard restore != counterpart else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.applyUndoAction(restore: restore, counterpart: counterpart)
        }

        if !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName("Edit")
        }
    }

    private func applyUndoAction(restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState) {
        guard model.isEditable else {
            return
        }

        registerUndoAction(restore: counterpart, counterpart: restore)

        isApplyingUndoRedo = true
        applyCommandResult(
            EditorCommandEngine.Result(
                edits: restore.edits,
                selectedRange: restore.selectedRange,
                refreshStartUTF16: restore.refreshStartUTF16
            )
        )
        isApplyingUndoRedo = false
    }

    private func applyTextEdits(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
        let validationEdits = edits.sorted { $0.range.location < $1.range.location }
        guard editsAreValid(validationEdits) else {
            return false
        }

        let undoManager = activeUndoManager
        let disablesUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if disablesUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if disablesUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
        }

        let affectedRanges = validationEdits.map(\.range)
        let replacementStrings = validationEdits.map(\.replacement)
        guard textView.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else {
            return false
        }

        guard applyStorageTextEdits(edits) else { return false }
        textView.didChangeTextNotification()
        return true
    }

    private func canHandleShortcut(_ action: EditorShortcutAction) -> Bool {
        switch action {
        case .indent, .outdent, .toggleComment:
            model.isEditable && model.language.supportsCodeEditingCommands
        case .toggleLineWrapping, .increaseFontSize, .decreaseFontSize, .resetFontSize:
            true
        }
    }

    private func handleShortcut(_ action: EditorShortcutAction) -> Bool {
        switch action {
        case .indent:
            return runIndentCommand()
        case .outdent:
            return runOutdentCommand()
        case .toggleComment:
            return runToggleCommentCommand()
        case .toggleLineWrapping:
            return runToggleLineWrappingCommand()
        case .increaseFontSize:
            model.increaseFontSize()
            return true
        case .decreaseFontSize:
            model.decreaseFontSize()
            return true
        case .resetFontSize:
            model.resetFontSize()
            return true
        }
    }

    private func runInsertTabCommand() -> Bool {
        guard model.isEditable else {
            return false
        }

        guard model.language.supportsCodeEditingCommands else {
            textView.insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        let source = textView.string
        guard let result = commandEngine.insertTab(
            source: source,
            selection: textView.selectedRange(),
            language: model.language
        ) else {
            return false
        }
        applyCommandResult(result)
        return true
    }

    private func runIndentCommand() -> Bool {
        guard model.isEditable, model.language.supportsCodeEditingCommands else {
            return false
        }

        let source = textView.string
        guard let result = commandEngine.indentSelection(
            source: source,
            selection: textView.selectedRange(),
            language: model.language
        ) else {
            return false
        }
        applyCommandResult(result)
        return true
    }

    private func runOutdentCommand() -> Bool {
        guard model.isEditable, model.language.supportsCodeEditingCommands else {
            return false
        }

        let source = textView.string
        guard let result = commandEngine.outdentSelection(
            source: source,
            selection: textView.selectedRange(),
            language: model.language
        ) else {
            return false
        }
        applyCommandResult(result)
        return true
    }

    private func runToggleCommentCommand() -> Bool {
        guard model.isEditable, model.language.supportsCodeEditingCommands else {
            return false
        }

        let source = textView.string
        guard let result = commandEngine.toggleComment(
            source: source,
            selection: textView.selectedRange(),
            language: model.language
        ) else {
            return false
        }
        applyCommandResult(result)
        return true
    }

    private func runToggleLineWrappingCommand() -> Bool {
        model.lineWrappingEnabled.toggle()
        return true
    }

    private func resetHighlightPhaseTrackingForTesting() {
        appliedHighlightPhaseRecordsForTesting.removeAll()
        skippedHighlightPhaseRecordsForTesting.removeAll()
        resumeAppliedHighlightPhaseWaitersForTesting(result: false)
        resumeSkippedHighlightPhaseWaitersForTesting(result: false)
    }

    private func hasAppliedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) -> Bool {
        appliedHighlightPhaseRecordsForTesting.contains {
            $0.revision == revision && $0.phase == phase
        }
    }

    private func recordAppliedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) {
        appliedHighlightPhaseRecordsForTesting.append(
            HighlightPhaseRecord(revision: revision, phase: phase)
        )
        if appliedHighlightPhaseRecordsForTesting.count > 16 {
            appliedHighlightPhaseRecordsForTesting.removeFirst(
                appliedHighlightPhaseRecordsForTesting.count - 16
            )
        }

        resumeAppliedHighlightPhaseWaitersForTesting(
            revision: revision,
            phase: phase,
            result: true
        )
    }

    private func hasSkippedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) -> Bool {
        skippedHighlightPhaseRecordsForTesting.contains {
            $0.revision == revision && $0.phase == phase
        }
    }

    private func recordSkippedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) {
        skippedHighlightPhaseRecordsForTesting.append(
            HighlightPhaseRecord(revision: revision, phase: phase)
        )
        if skippedHighlightPhaseRecordsForTesting.count > 16 {
            skippedHighlightPhaseRecordsForTesting.removeFirst(
                skippedHighlightPhaseRecordsForTesting.count - 16
            )
        }

        resumeSkippedHighlightPhaseWaitersForTesting(
            revision: revision,
            phase: phase,
            result: true
        )
    }

    private func resumeAppliedHighlightPhaseWaitersForTesting(
        revision: Int? = nil,
        phase: SyntaxEditorHighlighting.Result.Phase? = nil,
        result: Bool
    ) {
        var matchedWaiters: [HighlightPhaseWaiter] = []
        appliedHighlightPhaseWaitersForTesting.removeAll { waiter in
            guard revision == nil || waiter.revision == revision,
                  phase == nil || waiter.phase == phase
            else {
                return false
            }
            matchedWaiters.append(waiter)
            return true
        }

        for waiter in matchedWaiters {
            waiter.continuation.resume(returning: result)
        }
    }

    private func resumeSkippedHighlightPhaseWaiterForTesting(id: Int, result: Bool) {
        guard let waiterIndex = skippedHighlightPhaseWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = skippedHighlightPhaseWaitersForTesting.remove(at: waiterIndex)
        waiter.continuation.resume(returning: result)
    }

    private func resumeSkippedHighlightPhaseWaitersForTesting(
        revision: Int? = nil,
        phase: SyntaxEditorHighlighting.Result.Phase? = nil,
        result: Bool
    ) {
        var matchedWaiters: [HighlightPhaseWaiter] = []
        skippedHighlightPhaseWaitersForTesting.removeAll { waiter in
            guard revision == nil || waiter.revision == revision,
                  phase == nil || waiter.phase == phase
            else {
                return false
            }
            matchedWaiters.append(waiter)
            return true
        }

        for waiter in matchedWaiters {
            waiter.continuation.resume(returning: result)
        }
    }

    private func scheduleHighlight(
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        mutation: SyntaxEditorTextChange.Replacement? = nil,
        refreshStartUTF16 _: Int = 0
    ) {
        highlightTask?.cancel()
        let requestID = nextScheduledHighlightRequestID
        nextScheduledHighlightRequestID += 1
        scheduledHighlightRequest = ScheduledHighlightRequest(
            id: requestID,
            model: model,
            language: language,
            revision: revision,
            mutation: mutation
        )
        pendingHighlightApplication = nil
        resetHighlightPhaseTrackingForTesting()

        let highlighter = self.highlighter
        // Viewport hint: progressive opens and background semantic drains
        // process the chunk nearest this range first (pure ordering hint).
        let visibleRange = textView.visibleCharacterRangeWithoutLayout()
        let operation: SyntaxEditorHighlighting.Request.Operation = if let mutation {
            .update(mutation)
        } else {
            .reset
        }
        let request = SyntaxEditorHighlighting.Request(
            source: source,
            language: language,
            revision: revision,
            operation: operation,
            visibleRange: visibleRange
        )
        let shouldYieldBeforeReplacingRequest = !source.isEmpty
        highlightTask = Task.detached(priority: .utility) { [
            weak self,
            highlighter,
            request,
            mutation,
            requestID,
            shouldYieldBeforeReplacingRequest
        ] in
            defer {
                Task { @MainActor [weak self] in
                    self?.clearScheduledHighlightRequestIfCurrent(id: requestID)
                }
            }
            if shouldYieldBeforeReplacingRequest {
                await Task.yield()
            }
            guard !Task.isCancelled else {
                return
            }
            let phases = await highlighter.replaceCurrentRequest(with: request)
            for await result in phases {
                guard !Task.isCancelled else { return }
                await self?.applyHighlightResultFromScheduledTask(result, mutation: mutation)
            }
        }
    }

    private func clearScheduledHighlightRequestIfCurrent(id: Int) {
        guard scheduledHighlightRequest?.id == id else { return }
        scheduledHighlightRequest = nil
    }

    private func applyHighlightResultFromScheduledTask(
        _ result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) async {
        guard !Task.isCancelled else { return }
        guard model.textRevision == result.revision else { return }
        guard canApplyHighlightTokenPayload(for: result, mutation: mutation) else {
            recordSkippedHighlightPhaseForTesting(result.phase, revision: result.revision)
            scheduleHighlight(source: result.source, language: result.language, revision: result.revision)
            return
        }
        guard shouldMaterializeHighlightResult(result, mutation: mutation) else {
            recordSkippedHighlightPhaseForTesting(result.phase, revision: result.revision)
            return
        }
        let refreshRanges = highlightApplicationRefreshRanges(
            for: result,
            mutation: mutation
        )
        await applyHighlightFromScheduledTask(
            result.tokens,
            expectedRevision: result.revision,
            source: result.source,
            language: result.language,
            refreshRanges: refreshRanges,
            mutation: mutation,
            recordsCache: result.phase == .complete,
            phase: result.phase,
            tokenPayload: result.tokenPayload
        )
    }

    private func shouldMaterializeHighlightResult(
        _ result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) -> Bool {
        guard mutation != nil,
              result.phase == .syntacticFastPass
        else {
            return true
        }

        return !hasMaterializedCompletedHighlightToAvoidDowngrade(for: result)
    }

    private func hasMaterializedCompletedHighlightToAvoidDowngrade(for result: SyntaxEditorHighlighting.Result) -> Bool {
        guard materializedHighlightPhase == .complete,
              materializedHighlightLanguage == result.language,
              textSystem.styleStore.hasMaterializedRuns,
              let materializedHighlightRevision
        else {
            return false
        }

        return materializedHighlightRevision < result.revision
    }

    private func highlightApplicationRefreshRanges(
        for result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) -> [NSRange] {
        _ = mutation
        return result.refreshRanges
    }

    private static func highlightTargetRanges(_ ranges: [NSRange], textLength: Int) -> [NSRange] {
        let validRanges = ranges.filter { $0.location != NSNotFound }
        let clampedRanges = validRanges.map {
            SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: textLength)
        }
        let nonEmptyRanges = clampedRanges.filter { $0.length > 0 }
        let clamped = nonEmptyRanges.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
        guard var current = clamped.first else { return [] }
        var merged: [NSRange] = []
        for range in clamped.dropFirst() {
            if range.location <= current.upperBound {
                current = NSRange(
                    location: current.location,
                    length: max(current.upperBound, range.upperBound) - current.location
                )
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private func canApplyHighlightTokenPayload(
        for result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) -> Bool {
        guard result.tokenPayload == .replacement else {
            return true
        }
        // Reset-origin streams paint progressively: the reset itself defines
        // the (initially bare) baseline these replacements apply onto, so no
        // prior materialization is required.
        if mutation == nil {
            return true
        }
        guard materializedHighlightLanguage == result.language,
              let materializedHighlightRevision
        else {
            return false
        }
        return materializedHighlightRevision <= result.revision
    }

    private func reapplyCachedHighlight(
        source: String? = nil,
        language: SyntaxLanguage? = nil,
        revision: Int? = nil
    ) {
        let source = source ?? textView.string
        let language = language ?? model.language
        let revision = revision ?? model.textRevision

        if hasScheduledFullResetHighlight(language: language, revision: revision) {
            return
        }
        guard hasReusableRecordedHighlightSnapshot(
            source: source,
            language: language,
            revision: revision
        ) else {
            scheduleHighlight(source: source, language: language, revision: revision)
            return
        }

        applyHighlight(
            lastHighlightTokens,
            expectedRevision: revision,
            source: source,
            language: language,
            refreshRanges: [NSRange(location: 0, length: source.utf16.count)],
            mutation: nil
        )
    }

    private func hasReusableRecordedHighlightSnapshot(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) -> Bool {
        lastHighlightRevision == revision
            && lastHighlightLanguage == language
            && lastHighlightSource == source
    }

    private func hasScheduledFullResetHighlight(
        language: SyntaxLanguage,
        revision: Int
    ) -> Bool {
        guard let scheduledHighlightRequest,
              scheduledHighlightRequest.mutation == nil
        else {
            return false
        }
        return scheduledHighlightRequest.model === model
            && scheduledHighlightRequest.language == language
            && scheduledHighlightRequest.revision == revision
    }

    private func clearHighlightCache() {
        highlightTask?.cancel()
        highlightTask = nil
        scheduledHighlightRequest = nil
        lastHighlightTokens = []
        lastHighlightSource = nil
        lastHighlightRevision = nil
        lastHighlightLanguage = nil
        clearMaterializedHighlightState()
        pendingHighlightApplication = nil
        resetHighlightPhaseTrackingForTesting()
        resetSyntaxHighlightRenderingState(textLength: textStorage.length)
    }

    private func replaceEntireStorageText(_ nextText: String) {
        resetSyntaxHighlightRenderingState(textLength: nextText.utf16.count)
        textView.lineMetrics.reset(source: nextText)
        TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
            textStorage.setAttributedString(NSAttributedString(string: nextText, attributes: storageBaseAttributes()))
        }
        textView.setSelectedRange(textView.selectedRange())
        textView.invalidateTextLayout()
    }

    private func applyStorageTextEdits(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
        guard editsAreValid(edits) else { return false }

        let base = storageBaseAttributes()
        let previousSource = textStorage.string
        TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                let replacement = NSAttributedString(string: edit.replacement, attributes: base)
                textStorage.replaceCharacters(in: edit.range, with: replacement)
            }
        }
        textView.lineMetrics.apply(edits: edits, previousSource: previousSource)
        textView.invalidateTextLayout()
        return true
    }

    private func applyResolvedFontsToExistingText() {
        applyResolvedFontsToExistingText(
            source: textView.string,
            language: model.language,
            revision: model.textRevision
        )
    }

    private func applyResolvedFontsToExistingText(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) {
        let textRange = NSRange(location: 0, length: textStorage.length)
        let base = baseAttributes()
        guard textRange.length > 0,
              let baseFont = base[.font] as? NSFont
        else {
            return
        }

        TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
            textStorage.addAttribute(.font, value: baseFont, range: textRange)
        }

        var didRecomputeSyntaxFontRuns = false
        if hasReusableRecordedHighlightSnapshot(
            source: source,
            language: language,
            revision: revision
        ),
           let baseForeground = base[.foregroundColor] as? NSColor {
            var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: base)
            let runSet = syntaxHighlightRunSet(
                for: lastHighlightTokens,
                targetRange: textRange,
                textLength: textStorage.length,
                resolver: &resolver,
                baseFont: baseFont
            )
            textSystem.styleStore.commitSnapshot(
                runSet: runSet,
                range: textRange,
                revision: revision,
                language: language,
                textLength: textStorage.length,
                baseForeground: baseForeground,
                baseFont: baseFont,
                suppressionRanges: foregroundSuppressionRanges(textLength: textStorage.length)
            )
            didRecomputeSyntaxFontRuns = true
        }
        if !didRecomputeSyntaxFontRuns {
            let invalidatedFontRuns = textSystem.styleStore.updateBaseFont(
                baseFont,
                textLength: textStorage.length,
                clearsFontRuns: true
            )
            invalidateSyntaxRenderingAttributes(for: invalidatedFontRuns)
        }

        clearMaterializedSyntaxHighlightRendering()
        invalidateSyntaxRenderingAttributes(for: textRange)
        textView.invalidateTextLayout()
        invalidateVisibleTextDisplay()
    }

    private func cachedSyntaxFontRunsChanged(
        from previousTheme: SyntaxEditorTheme,
        previousAppearance: SyntaxEditorTheme.Appearance,
        previousFontSizeDelta: Int,
        to nextTheme: SyntaxEditorTheme,
        nextAppearance: SyntaxEditorTheme.Appearance,
        nextFontSizeDelta: Int,
        language: SyntaxLanguage,
        revision: Int? = nil
    ) -> Bool {
        let source = textView.string
        let textLength = textStorage.length
        let revision = revision ?? model.textRevision
        guard let previousRuns = cachedSyntaxFontRuns(
            for: previousTheme,
            language: language,
            appearance: previousAppearance,
            fontSizeDelta: previousFontSizeDelta,
            source: source,
            textLength: textLength,
            revision: revision
        ), let nextRuns = cachedSyntaxFontRuns(
            for: nextTheme,
            language: language,
            appearance: nextAppearance,
            fontSizeDelta: nextFontSizeDelta,
            source: source,
            textLength: textLength,
            revision: revision
        ) else {
            return false
        }

        return !syntaxFontRunsEqual(previousRuns, nextRuns)
    }

    private func cachedSyntaxFontRuns(
        for theme: SyntaxEditorTheme,
        language: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance,
        fontSizeDelta: Int,
        source: String,
        textLength: Int,
        revision: Int
    ) -> [HighlightFontRun]? {
        guard textLength > 0,
              hasReusableRecordedHighlightSnapshot(
                  source: source,
                  language: language,
                  revision: revision
              )
        else {
            return nil
        }

        let resolvedTheme = theme.resolved(for: language, appearance: appearance)
        let baseFont = resolvedBaseFont(for: resolvedTheme, fontSizeDelta: fontSizeDelta)
        var resolver = makeSyntaxHighlightAttributeResolver(
            theme: theme,
            language: language,
            appearance: appearance,
            fontSizeDelta: fontSizeDelta
        )
        let runSet = syntaxHighlightRunSet(
            for: lastHighlightTokens,
            targetRange: NSRange(location: 0, length: textLength),
            textLength: textLength,
            resolver: &resolver,
            baseFont: baseFont
        )
        return runSet.fontRuns
    }

    private func syntaxFontRunsEqual(_ lhs: [HighlightFontRun], _ rhs: [HighlightFontRun]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (leftRun, rightRun) in zip(lhs, rhs) {
            guard NSEqualRanges(leftRun.range, rightRun.range),
                  leftRun.font.isEqual(rightRun.font)
            else {
                return false
            }
        }
        return true
    }

    private func editsAreValid(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
        let textLength = textStorage.length
        return edits.allSatisfy { edit in
            edit.range.location >= 0 && edit.range.location + edit.range.length <= textLength
        }
    }

    private static func highlightMutation(_ change: SyntaxEditorTextChange) -> SyntaxEditorTextChange.Replacement? {
        guard change.replacements.count == 1, let edit = change.replacements.first else { return nil }
        return SyntaxEditorTextChange.Replacement(
            location: edit.range.location,
            length: edit.range.length,
            replacement: edit.replacement
        )
    }

    @discardableResult
    private func applyHighlight(
        _ tokens: [SyntaxEditorHighlighting.Token],
        expectedRevision: Int,
        source expectedSource: String,
        language expectedLanguage: SyntaxLanguage,
        refreshRanges: [NSRange],
        mutation: SyntaxEditorTextChange.Replacement?,
        recordsCache: Bool = true,
        phase: SyntaxEditorHighlighting.Result.Phase = .complete,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) -> Bool {
        guard model.textRevision == expectedRevision else { return false }
        guard model.language == expectedLanguage,
              textView.string == expectedSource
        else {
            pendingHighlightApplication = nil
            return false
        }
        let pendingApplication = PendingHighlightApplication(
            tokens: tokens,
            expectedRevision: expectedRevision,
            source: expectedSource,
            language: expectedLanguage,
            refreshRanges: refreshRanges,
            mutation: mutation,
            recordsCache: recordsCache,
            phase: phase,
            tokenPayload: tokenPayload
        )
        guard textView.selectedRange().length == 0 else {
            pendingHighlightApplication = pendingApplication
            clearMatchingBracketHighlight()
            return false
        }

        pendingHighlightApplication = nil

        let textLength = textStorage.length
        let targetRanges = Self.highlightTargetRanges(
            refreshRanges,
            textLength: textLength
        )
        guard !targetRanges.isEmpty else {
            if recordsCache {
                recordAppliedHighlight(
                    tokens: tokens,
                    source: expectedSource,
                    revision: expectedRevision,
                    language: expectedLanguage,
                    tokenPayload: tokenPayload
                )
            }
            applyMatchingBracketHighlight(force: true)
            recordMaterializedHighlight(
                phase: phase,
                revision: expectedRevision,
                language: expectedLanguage
            )
            return true
        }
        let base = baseAttributes()

        isApplyingHighlight = true
        defer { isApplyingHighlight = false }

        for targetRange in targetRanges {
            installSyntaxHighlightRendering(
                for: tokens,
                targetRange: targetRange,
                textLength: textLength,
                baseAttributes: base,
                revision: expectedRevision,
                language: expectedLanguage
            )
        }
        textView.applyMarkedTextAttributes()
        textView.typingAttributes = base
        applyMatchingBracketHighlight(force: true)
        for targetRange in targetRanges {
            invalidateSyntaxHighlightDisplay(for: targetRange)
        }
        if recordsCache {
            recordAppliedHighlight(
                tokens: tokens,
                source: expectedSource,
                revision: expectedRevision,
                language: expectedLanguage,
                tokenPayload: tokenPayload
            )
        }
        recordMaterializedHighlight(
            phase: phase,
            revision: expectedRevision,
            language: expectedLanguage
        )
        return true
    }

    @discardableResult
    private func applyHighlightFromScheduledTask(
        _ tokens: [SyntaxEditorHighlighting.Token],
        expectedRevision: Int,
        source expectedSource: String,
        language expectedLanguage: SyntaxLanguage,
        refreshRanges: [NSRange],
        mutation: SyntaxEditorTextChange.Replacement?,
        recordsCache: Bool = true,
        phase: SyntaxEditorHighlighting.Result.Phase = .complete,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) async -> Bool {
        guard model.textRevision == expectedRevision else { return false }
        guard model.language == expectedLanguage,
              textView.string == expectedSource
        else {
            pendingHighlightApplication = nil
            return false
        }
        let pendingApplication = PendingHighlightApplication(
            tokens: tokens,
            expectedRevision: expectedRevision,
            source: expectedSource,
            language: expectedLanguage,
            refreshRanges: refreshRanges,
            mutation: mutation,
            recordsCache: recordsCache,
            phase: phase,
            tokenPayload: tokenPayload
        )
        guard textView.selectedRange().length == 0 else {
            pendingHighlightApplication = pendingApplication
            clearMatchingBracketHighlight()
            return false
        }

        pendingHighlightApplication = nil

        let textLength = textStorage.length
        let targetRanges = Self.highlightTargetRanges(
            refreshRanges,
            textLength: textLength
        )
        guard !targetRanges.isEmpty else {
            if recordsCache {
                recordAppliedHighlight(
                    tokens: tokens,
                    source: expectedSource,
                    revision: expectedRevision,
                    language: expectedLanguage,
                    tokenPayload: tokenPayload
                )
            }
            applyMatchingBracketHighlight(force: true)
            recordMaterializedHighlight(
                phase: phase,
                revision: expectedRevision,
                language: expectedLanguage
            )
            return true
        }
        let base = baseAttributes()
        guard !Task.isCancelled else { return false }
        isApplyingHighlight = true
        defer { isApplyingHighlight = false }
        for targetRange in targetRanges {
            guard await installSyntaxHighlightRenderingIncrementally(
                for: tokens,
                targetRange: targetRange,
                textLength: textLength,
                baseAttributes: base,
                expectedRevision: expectedRevision
            ) else { return false }
        }
        guard !Task.isCancelled, model.textRevision == expectedRevision else { return false }

        textView.applyMarkedTextAttributes()
        textView.typingAttributes = base
        applyMatchingBracketHighlight(force: true)
        for targetRange in targetRanges {
            invalidateSyntaxHighlightDisplay(for: targetRange)
        }
        if recordsCache {
            recordAppliedHighlight(
                tokens: tokens,
                source: expectedSource,
                revision: expectedRevision,
                language: expectedLanguage,
                tokenPayload: tokenPayload
            )
        }
        recordMaterializedHighlight(
            phase: phase,
            revision: expectedRevision,
            language: expectedLanguage
        )
        return true
    }

    private func makeSyntaxHighlightAttributeResolver(
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> SyntaxHighlightAttributeResolver {
        SyntaxHighlightAttributeResolver(
            theme: lastAppliedTheme ?? model.theme,
            defaultLanguage: model.language,
            appearance: currentThemeAppearance,
            fontSizeDelta: model.fontSizeDelta
        )
    }

    private func makeSyntaxHighlightAttributeResolver(
        theme: SyntaxEditorTheme,
        language: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance,
        fontSizeDelta: Int
    ) -> SyntaxHighlightAttributeResolver {
        SyntaxHighlightAttributeResolver(
            theme: theme,
            defaultLanguage: language,
            appearance: appearance,
            fontSizeDelta: fontSizeDelta
        )
    }

    private func installSyntaxHighlightRendering(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        textLength: Int,
        baseAttributes: [NSAttributedString.Key: Any],
        revision: Int,
        language: SyntaxLanguage
    ) {
        guard let baseForeground = baseAttributes[.foregroundColor] as? NSColor else {
            return
        }
        var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: baseAttributes)
        let runSet = syntaxHighlightRunSet(
            for: tokens,
            targetRange: targetRange,
            textLength: textLength,
            resolver: &resolver,
            baseFont: baseAttributes[.font] as? NSFont
        )
        let invalidatedDirtyRanges = textSystem.styleStore.commitSnapshot(
            runSet: runSet,
            range: targetRange,
            revision: revision,
            language: language,
            textLength: textLength,
            baseForeground: baseForeground,
            baseFont: baseAttributes[.font] as? NSFont,
            suppressionRanges: foregroundSuppressionRanges(textLength: textLength)
        )
        invalidateSyntaxRenderingAttributes(for: [targetRange] + invalidatedDirtyRanges)
    }

    private func installSyntaxHighlightRenderingIncrementally(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        textLength: Int,
        baseAttributes: [NSAttributedString.Key: Any],
        expectedRevision: Int
    ) async -> Bool {
        guard let baseForeground = baseAttributes[.foregroundColor] as? NSColor else {
            return false
        }
        var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: baseAttributes)
        let runSet = syntaxHighlightRunSet(
            for: tokens,
            targetRange: targetRange,
            textLength: textLength,
            resolver: &resolver,
            baseFont: baseAttributes[.font] as? NSFont
        )
        guard !Task.isCancelled, model.textRevision == expectedRevision else { return false }
        let invalidatedDirtyRanges = textSystem.styleStore.commitSnapshot(
            runSet: runSet,
            range: targetRange,
            revision: expectedRevision,
            language: model.language,
            textLength: textLength,
            baseForeground: baseForeground,
            baseFont: baseAttributes[.font] as? NSFont,
            suppressionRanges: foregroundSuppressionRanges(textLength: textLength)
        )
        invalidateSyntaxRenderingAttributes(for: [targetRange] + invalidatedDirtyRanges)
        return true
    }

    private func invalidateSyntaxRenderingAttributes(for range: NSRange) {
        invalidateSyntaxRenderingAttributes(for: [range])
    }

    private func invalidateSyntaxRenderingAttributes(for ranges: [NSRange]) {
        textView.invalidateSyntaxRenderingAttributes(for: ranges)
    }

    private func foregroundSuppressionRanges(textLength: Int) -> [NSRange] {
        let markedRange = textView.markedRange()
        guard markedRange.location != NSNotFound else { return [] }
        let clamped = SyntaxEditorRangeUtilities.clampedRange(markedRange, utf16Length: textLength)
        return clamped.length > 0 ? [clamped] : []
    }

    private func syncMarkedTextSuppressionRanges() {
        let textLength = textStorage.length
        textSystem.styleStore.updateSuppressionRanges(
            foregroundSuppressionRanges(textLength: textLength),
            textLength: textLength
        )
    }

    private func syntaxHighlightRunSet(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        textLength: Int,
        resolver: inout SyntaxHighlightAttributeResolver,
        baseFont: NSFont?
    ) -> HighlightRunSet {
        let resolvedRuns = syntaxHighlightResolvedRuns(
            for: tokens,
            targetRange: targetRange,
            textLength: textLength,
            resolver: &resolver
        )
        var colorRuns: [HighlightColorRun] = []
        colorRuns.reserveCapacity(resolvedRuns.count)
        var fontRuns: [HighlightFontRun] = []
        fontRuns.reserveCapacity(resolvedRuns.count)

        for run in resolvedRuns {
            if var last = colorRuns.last,
               last.color.isEqual(run.style.attributes.foregroundColor),
               last.range.upperBound >= run.range.location,
               run.range.upperBound >= last.range.location {
                let lowerBound = min(last.range.location, run.range.location)
                let upperBound = max(last.range.upperBound, run.range.upperBound)
                last.range = NSRange(location: lowerBound, length: upperBound - lowerBound)
                colorRuns[colorRuns.count - 1] = last
            } else {
                colorRuns.append(HighlightColorRun(range: run.range, color: run.style.attributes.foregroundColor))
            }
            let font = run.style.attributes.font
            guard baseFont.map({ !font.isEqual($0) }) ?? true
            else {
                continue
            }
            fontRuns.append(HighlightFontRun(range: run.range, font: font))
        }

        return HighlightRunSet(colorRuns: colorRuns, fontRuns: fontRuns)
    }

    private func syntaxHighlightResolvedRuns(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        textLength: Int,
        resolver: inout SyntaxHighlightAttributeResolver
    ) -> [HighlightAssembledRun<SyntaxHighlightResolvedStyle>] {
        HighlightRunAssembler.assembleRuns(
            for: tokens,
            targetRange: targetRange,
            textLength: textLength
        ) { token in
            guard let resolved = resolver.style(for: token.syntaxID, language: token.language) else {
                return nil
            }
            return SyntaxHighlightResolvedStyle(key: resolved.key, attributes: resolved.style)
        } stylesCanCoalesce: { lhs, rhs in
            lhs.key == rhs.key
        }
    }

    private func recordAppliedHighlight(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        revision: Int,
        language: SyntaxLanguage,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload
    ) {
        guard tokenPayload == .fullSnapshot else {
            clearRecordedHighlightTokenSnapshot()
            return
        }
        lastHighlightTokens = tokens
        lastHighlightSource = source
        lastHighlightRevision = revision
        lastHighlightLanguage = language
    }

    private func clearRecordedHighlightTokenSnapshot() {
        lastHighlightTokens = []
        lastHighlightSource = nil
        lastHighlightRevision = nil
        lastHighlightLanguage = nil
    }

    private func recordMaterializedHighlight(
        phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int,
        language: SyntaxLanguage
    ) {
        materializedHighlightPhase = phase
        materializedHighlightRevision = revision
        materializedHighlightLanguage = language
        recordAppliedHighlightPhaseForTesting(phase, revision: revision)
    }

    private func clearMaterializedHighlightState() {
        materializedHighlightPhase = nil
        materializedHighlightRevision = nil
        materializedHighlightLanguage = nil
    }

    private func applyPendingHighlightIfSelectionAllows() {
        guard textView.selectedRange().length == 0,
              let pendingHighlightApplication
        else {
            return
        }

        self.pendingHighlightApplication = nil
        applyHighlight(
            pendingHighlightApplication.tokens,
            expectedRevision: pendingHighlightApplication.expectedRevision,
            source: pendingHighlightApplication.source,
            language: pendingHighlightApplication.language,
            refreshRanges: pendingHighlightApplication.refreshRanges,
            mutation: pendingHighlightApplication.mutation,
            recordsCache: pendingHighlightApplication.recordsCache,
            phase: pendingHighlightApplication.phase,
            tokenPayload: pendingHighlightApplication.tokenPayload
        )
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        let theme = resolvedTheme()
        return [
            .font: resolvedBaseFont(for: theme),
            .foregroundColor: theme.baseForeground,
        ]
    }

    private func storageBaseAttributes() -> [NSAttributedString.Key: Any] {
        baseAttributes()
    }

    private func resolvedBaseFont(for theme: SyntaxEditorTheme.Resolved? = nil) -> NSFont {
        resolvedBaseFont(for: theme, fontSizeDelta: model.fontSizeDelta)
    }

    private func resolvedBaseFont(
        for theme: SyntaxEditorTheme.Resolved? = nil,
        fontSizeDelta: Int
    ) -> NSFont {
        let theme = theme ?? resolvedTheme()
        return theme.base.font.platformFont(fontSizeDelta: fontSizeDelta)
    }

    private var currentThemeAppearance: SyntaxEditorTheme.Appearance {
        effectiveAppearance.syntaxEditorThemeAppearance
    }

    func resolvedTheme() -> SyntaxEditorTheme.Resolved {
        (lastAppliedTheme ?? model.theme).resolved(
            for: model.language,
            appearance: currentThemeAppearance
        )
    }

    private func updateEditorBackgroundColor() {
        updateEditorBackgroundColor(drawsBackground: model.drawsBackground)
    }

    private func updateEditorBackgroundColor(drawsBackground: Bool) {
        let color = resolvedTheme().background
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = color
        textView.backgroundColor = color
    }

    private func applyLineWrappingConfiguration(lineWrappingEnabled: Bool) {
        guard !isApplyingLineWrappingConfiguration else { return }

        isApplyingLineWrappingConfiguration = true
        defer { isApplyingLineWrappingConfiguration = false }

        var layoutGeometryChanged = false

        if scrollView.hasHorizontalScroller == lineWrappingEnabled {
            scrollView.hasHorizontalScroller = !lineWrappingEnabled
            scrollView.tile()
            layoutGeometryChanged = true
        }

        var contentSize = effectiveScrollContentSize
        var estimatedDocumentSize = estimatedTextViewDocumentSize(
            minimumContentSize: contentSize,
            lineWrappingEnabled: lineWrappingEnabled
        )

        if textView.minSize.height != contentSize.height {
            textView.minSize = NSSize(width: 0, height: contentSize.height)
        }

        let maxTextViewSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if textView.maxSize != maxTextViewSize {
            textView.maxSize = maxTextViewSize
        }

        if lineWrappingEnabled {
            if textView.isHorizontallyResizable {
                textView.isHorizontallyResizable = false
                layoutGeometryChanged = true
            }
            if textView.autoresizingMask != [.width] {
                textView.autoresizingMask = [.width]
                layoutGeometryChanged = true
            }

            layoutGeometryChanged = applyWrappedTextGeometry(
                contentSize: contentSize,
                estimatedDocumentSize: estimatedDocumentSize
            ) || layoutGeometryChanged
            if !textContainer.widthTracksTextView {
                textContainer.widthTracksTextView = true
                layoutGeometryChanged = true
            }
            if textContainer.lineBreakMode != .byWordWrapping {
                textContainer.lineBreakMode = .byWordWrapping
                layoutGeometryChanged = true
            }

            if resetHorizontalClipOriginForWrapping() {
                layoutGeometryChanged = true
            }

            scrollView.tile()
            let settledContentSize = effectiveScrollContentSize
            if !settledContentSize.isNearlyEqual(to: contentSize) {
                contentSize = settledContentSize
                estimatedDocumentSize = estimatedTextViewDocumentSize(
                    minimumContentSize: contentSize,
                    lineWrappingEnabled: true
                )
                layoutGeometryChanged = applyWrappedTextGeometry(
                    contentSize: contentSize,
                    estimatedDocumentSize: estimatedDocumentSize
                ) || layoutGeometryChanged
            }
        } else {
            if !textView.isHorizontallyResizable {
                textView.isHorizontallyResizable = true
                layoutGeometryChanged = true
            }
            if !textView.autoresizingMask.isEmpty {
                textView.autoresizingMask = []
                layoutGeometryChanged = true
            }

            let containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            if !textContainer.containerSize.isNearlyEqual(to: containerSize) {
                textContainer.containerSize = containerSize
                layoutGeometryChanged = true
            }
            if textContainer.widthTracksTextView {
                textContainer.widthTracksTextView = false
                layoutGeometryChanged = true
            }
            if textContainer.lineBreakMode != .byClipping {
                textContainer.lineBreakMode = .byClipping
                layoutGeometryChanged = true
            }

            var frame = textView.frame
            if !frame.width.isNearlyEqual(to: estimatedDocumentSize.width)
                || !frame.height.isNearlyEqual(to: estimatedDocumentSize.height)
            {
                frame.size = estimatedDocumentSize
                textView.frame = frame
                layoutGeometryChanged = true
            }
        }

        if layoutGeometryChanged {
            invalidateTextLayoutAfterGeometryChange()
        }
    }

    private func applyWrappedTextGeometry(
        contentSize: NSSize,
        estimatedDocumentSize: NSSize
    ) -> Bool {
        var didChange = false
        let wrappingWidth = max(0, contentSize.width)
        var frame = textView.frame
        let frameHeight = estimatedDocumentSize.height
        if !frame.width.isNearlyEqual(to: wrappingWidth) || !frame.height.isNearlyEqual(to: frameHeight) {
            frame.size = NSSize(width: wrappingWidth, height: frameHeight)
            textView.frame = frame
            didChange = true
        }

        let containerSize = NSSize(width: wrappingWidth, height: CGFloat.greatestFiniteMagnitude)
        if !textContainer.containerSize.isNearlyEqual(to: containerSize) {
            textContainer.containerSize = containerSize
            didChange = true
        }
        return didChange
    }

    private var effectiveScrollContentSize: NSSize {
        let contentSize = scrollView.contentSize
        let contentInsets = scrollView.contentView.contentInsets
        let width = contentSize.width > 0 ? contentSize.width : bounds.width
        let height = contentSize.height > 0 ? contentSize.height : bounds.height
        return NSSize(
            width: max(0, width - max(0, contentInsets.left) - max(0, contentInsets.right)),
            height: max(0, height - max(0, contentInsets.top) - max(0, contentInsets.bottom))
        )
    }

    private func estimatedTextViewDocumentSize(
        minimumContentSize: NSSize,
        lineWrappingEnabled: Bool
    ) -> NSSize {
        let baseFont = textView.font ?? resolvedBaseFont()
        let lineHeight = max(1, ceil(baseFont.ascender - baseFont.descender + baseFont.leading))
        let estimatedColumnWidth = max(1, baseFont.pointSize * 0.65)
        return textView.lineMetrics.estimatedDocumentSize(
            minimumSize: minimumContentSize,
            lineWrappingEnabled: lineWrappingEnabled,
            lineHeight: lineHeight,
            columnWidth: estimatedColumnWidth,
            lineFragmentPadding: textContainer.lineFragmentPadding
        )
    }

    private func resetHorizontalClipOriginForWrapping() -> Bool {
        let clipView = scrollView.contentView
        let targetOriginX = -max(0, clipView.contentInsets.left)
        guard !clipView.bounds.origin.x.isNearlyEqual(to: targetOriginX) else { return false }

        clipView.scroll(to: NSPoint(x: targetOriginX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    private func invalidateTextLayoutAfterGeometryChange() {
        layoutManager.invalidateLayout(for: textSystem.textContentStorage.documentRange)
        textView.layoutVisibleViewport()
        textView.setNeedsDisplayForVisibleTextFragments()
    }

    private func invalidateTextDisplay(forCharacterRanges ranges: [NSRange]) {
        textView.setNeedsDisplayForTextRanges(ranges)
    }

    private func invalidateSyntaxHighlightDisplay(for refreshRange: NSRange) {
        guard let visibleRange = visibleTextCharacterRange() else { return }
        let intersection = SyntaxEditorRangeUtilities.intersection(of: refreshRange, and: visibleRange)
        guard intersection.length > 0 else { return }
        invalidateTextDisplay(forCharacterRanges: [intersection])
    }

    private func clearSyntaxHighlightRendering() {
        let base = baseAttributes()
        if let baseForeground = base[.foregroundColor] as? NSColor {
            textSystem.styleStore.clear(
                textLength: textStorage.length,
                baseForeground: baseForeground,
                baseFont: base[.font] as? NSFont
            )
            invalidateSyntaxRenderingAttributes(for: NSRange(location: 0, length: textStorage.length))
        }
        clearMaterializedHighlightState()
        invalidateVisibleTextDisplay()
    }

    private func resetSyntaxHighlightRenderingState(textLength: Int) {
        textSystem.styleStore.reset(textLength: textLength)
        clearMaterializedHighlightState()
    }

    private func prepareSyntaxHighlightRenderingForPendingTextChange(
        mutation: SyntaxEditorTextChange.Replacement?,
        source: String,
        refreshStartUTF16 _: Int
    ) {
        guard let mutation else {
            clearSyntaxHighlightRendering()
            return
        }
        let invalidatedRange = pendingTextReplacementRange(in: source, mutation: mutation)
        textSystem.styleStore.recordPendingEdit(mutation, currentTextLength: source.utf16.count)
        invalidateSyntaxRenderingAttributes(for: invalidatedRange)
        textView.setNeedsDisplayForTextRanges([invalidatedRange])
    }

    private func pendingTextReplacementRange(
        in source: String,
        mutation: SyntaxEditorTextChange.Replacement
    ) -> NSRange {
        let textLength = source.utf16.count
        let location = min(max(0, mutation.location), textLength)
        let replacementLength = min(max(0, mutation.replacement.utf16.count), textLength - location)
        if replacementLength > 0 {
            return NSRange(location: location, length: replacementLength)
        }
        guard textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let fallbackLocation = min(location, textLength - 1)
        return NSRange(location: fallbackLocation, length: 1)
    }

    private func suspendSyntaxHighlightMaterialization() {
        invalidateVisibleTextDisplay()
    }

    private func clearMaterializedSyntaxHighlightRendering() {
        invalidateVisibleTextDisplay()
    }

    private func invalidateVisibleTextDisplay() {
        guard textStorage.length > 0 else { return }
        visibleTextDisplayInvalidationCount += 1

        guard let visibleRange = visibleTextCharacterRange() else {
            textView.setNeedsDisplayForVisibleTextFragments()
            return
        }
        textView.setNeedsDisplayForTextRanges([visibleRange])
    }

    private func visibleTextCharacterRange() -> NSRange? {
        guard textStorage.length > 0 else { return nil }
        textView.layoutVisibleViewport()
        return textView.visibleCharacterRange()
    }
}

@MainActor
public final class SyntaxEditorViewController: NSViewController {
    public private(set) var model: SyntaxEditorModel
    public let editorView: SyntaxEditorView

    var textView: SyntaxEditorTextInputView {
        editorView.textView
    }

    public var scrollView: NSScrollView {
        editorView
    }

    public init(model: SyntaxEditorModel) {
        self.model = model
        self.editorView = SyntaxEditorView(model: model)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = editorView
    }

    public func update(model nextModel: SyntaxEditorModel) {
        guard model !== nextModel else { return }

        model = nextModel
        editorView.update(model: nextModel)
    }

    internal func synchronizeDocumentForTesting() {
        editorView.synchronizeDocumentForTesting()
    }

    public func textDidChange(_ notification: Notification) {
        editorView.textDidChange(notification)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        editorView.textViewDidChangeSelection(notification)
    }

    func textView(
        _ textView: SyntaxEditorTextInputView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        editorView.textView(
            textView,
            shouldChangeTextIn: affectedCharRange,
            replacementString: replacementString
        )
    }

    func textView(_ textView: SyntaxEditorTextInputView, doCommandBy commandSelector: Selector) -> Bool {
        editorView.textView(textView, doCommandBy: commandSelector)
    }
}

extension NSColor {
    static func syntaxEditorAlpha(_ color: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolvedColor = color.withAlphaComponent(alpha)
            appearance.performAsCurrentDrawingAppearance {
                resolvedColor = color.withAlphaComponent(alpha)
            }
            return resolvedColor
        }
    }
}

private extension NSAppearance {
    var syntaxEditorThemeAppearance: SyntaxEditorTheme.Appearance {
        let match = bestMatch(from: [
            .darkAqua,
            .accessibilityHighContrastDarkAqua,
            .vibrantDark,
            .accessibilityHighContrastVibrantDark,
            .aqua,
            .accessibilityHighContrastAqua,
            .vibrantLight,
            .accessibilityHighContrastVibrantLight,
        ])
        return match == .darkAqua
            || match == .accessibilityHighContrastDarkAqua
            || match == .vibrantDark
            || match == .accessibilityHighContrastVibrantDark
            ? .dark
            : .light
    }
}

private extension NSFont {
    func syntaxEditorFontSizeAdjusted(by delta: Int) -> NSFont {
        withSize(SyntaxEditorTheme.FontSize.pointSize(pointSize, applying: delta))
    }
}

private extension CGFloat {
    func isNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}

private extension NSSize {
    func isNearlyEqual(to other: NSSize, tolerance: CGFloat = 0.5) -> Bool {
        width.isNearlyEqual(to: other.width, tolerance: tolerance)
            && height.isNearlyEqual(to: other.height, tolerance: tolerance)
    }
}
#endif
