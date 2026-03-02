#if canImport(AppKit)
import AppKit
import Observation
import ObservationsCompat

private enum MacEditorShortcutAction {
    case indent
    case outdent
    case toggleComment
}

private final class SyntaxEditorNativeTextView: NSTextView {
    var shortcutHandler: ((MacEditorShortcutAction) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option)
        else {
            return super.performKeyEquivalent(with: event)
        }

        let key = event.charactersIgnoringModifiers ?? ""

        if key == "/" {
            if shortcutHandler?(.toggleComment) == true {
                return true
            }
        }

        if key == "]" {
            if shortcutHandler?(.indent) == true {
                return true
            }
        }

        if key == "[" {
            if shortcutHandler?(.outdent) == true {
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
@Observable
public final class SyntaxEditorViewController: NSViewController, NSTextViewDelegate {
    public private(set) var model: SyntaxEditorModel
    public let textView: NSTextView
    public let scrollView: NSScrollView
    @ObservationIgnored
    private let fallbackUndoManager = UndoManager()
    @ObservationIgnored
    private let textStorage: NSTextStorage
    @ObservationIgnored
    private let textContainer: NSTextContainer

    @ObservationIgnored
    private let highlighter = SyntaxHighlighterEngine()
    @ObservationIgnored
    private let commandEngine = EditorCommandEngine()
    @ObservationIgnored
    private var highlightTask: Task<Void, Never>?
    @ObservationIgnored
    private var isApplyingModel = false
    @ObservationIgnored
    private var isApplyingHighlight = false
    @ObservationIgnored
    private var lastAppliedLanguage: SyntaxLanguage?
    @ObservationIgnored
    private var pendingEditStartUTF16: Int?
    @ObservationIgnored
    private var matchedBracketRanges: [NSRange] = []
    @ObservationIgnored
    private var isApplyingUndoRedo = false

    public init(model: SyntaxEditorModel) {
        self.model = model

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        layoutManager.addTextContainer(textContainer)

        let nativeTextView = SyntaxEditorNativeTextView(frame: .zero, textContainer: textContainer)
        self.textStorage = textStorage
        self.textContainer = textContainer
        self.textView = nativeTextView
        self.scrollView = NSScrollView(frame: .zero)

        super.init(nibName: nil, bundle: nil)

        nativeTextView.shortcutHandler = { [weak self] action in
            guard let self else { return false }
            return self.handleShortcut(action)
        }

        startModelObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        highlightTask?.cancel()
    }

    public override func loadView() {
        view = scrollView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureScrollView()
        configureTextView()
        applyObservedText(
            model.text,
            forceTextUpdate: true
        )
        applyObservedEditorState(
            language: model.language,
            isEditable: model.isEditable,
            lineWrappingEnabled: model.lineWrappingEnabled,
            forceLanguageRefresh: true
        )
    }

    public func textDidChange(_ notification: Notification) {
        guard !isApplyingModel, !isApplyingHighlight else {
            pendingEditStartUTF16 = nil
            return
        }

        let nextText = textView.string
        if model.text != nextText {
            model.text = nextText
        }

        let editStartUTF16 = pendingEditStartUTF16 ?? textView.selectedRange().location
        pendingEditStartUTF16 = nil
        let refreshStartUTF16 = SyntaxEditorRangeUtilities.lineStartUTF16Offset(
            in: nextText,
            around: editStartUTF16
        )
        scheduleHighlight(
            source: nextText,
            language: model.language,
            refreshStartUTF16: refreshStartUTF16
        )
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        applyMatchingBracketHighlight()
    }

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard !isApplyingModel, !isApplyingHighlight else {
            return true
        }

        pendingEditStartUTF16 = affectedCharRange.location

        guard let replacementString else {
            return true
        }

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

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            return runIndentCommand()
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
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !model.lineWrappingEnabled
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
    }

    private func configureTextView() {
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = model.isEditable
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        applyLineWrappingConfiguration(lineWrappingEnabled: model.lineWrappingEnabled)

        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = baseAttributes()
    }

    private var activeUndoManager: UndoManager? {
        textView.undoManager ?? fallbackUndoManager
    }

    private func startModelObservation() {
        // ObservationsCompat automatically retains observation handles for the owner (`model`).
        _ = model.observe(\.text, options: [.removeDuplicates]) { [weak self] text in
            guard let self else { return }
            self.applyObservedText(text)
        }

        _ = model.observe([\.language, \.isEditable, \.lineWrappingEnabled]) { [weak self] in
            guard let self else { return }
            self.applyObservedEditorState(
                language: self.model.language,
                isEditable: self.model.isEditable,
                lineWrappingEnabled: self.model.lineWrappingEnabled
            )
        }
    }

    private func applyObservedText(_ text: String, forceTextUpdate: Bool = false) {
        isApplyingModel = true
        defer { isApplyingModel = false }

        let textNeedsUpdate = forceTextUpdate || textView.string != text
        if textNeedsUpdate {
            textView.string = text
        }

        textView.typingAttributes = baseAttributes()
        if textNeedsUpdate {
            scheduleHighlight(
                source: text,
                language: model.language,
                refreshStartUTF16: 0
            )
        }
    }

    private func applyObservedEditorState(
        language: SyntaxLanguage,
        isEditable: Bool,
        lineWrappingEnabled: Bool,
        forceLanguageRefresh: Bool = false
    ) {
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        applyLineWrappingConfiguration(lineWrappingEnabled: lineWrappingEnabled)
        scrollView.hasHorizontalScroller = !lineWrappingEnabled

        let languageChanged = forceLanguageRefresh || lastAppliedLanguage != language
        lastAppliedLanguage = language

        textView.typingAttributes = baseAttributes()
        if languageChanged {
            scheduleHighlight(
                source: textView.string,
                language: language,
                refreshStartUTF16: 0
            )
        }
    }

    private func applyCommandResult(_ result: EditorCommandResult) {
        let previousText = textView.string
        let previousSelection = textView.selectedRange()
        let textChanged = previousText != result.text
        var appliedMutation: TextMutation?

        if textChanged, !isApplyingUndoRedo {
            registerUndoAction(
                restore: EditorUndoState(
                    text: previousText,
                    selectedRange: previousSelection,
                    refreshStartUTF16: 0
                ),
                counterpart: EditorUndoState(
                    text: result.text,
                    selectedRange: result.selectedRange,
                    refreshStartUTF16: result.refreshStartUTF16
                )
            )
        }

        isApplyingModel = true
        if textChanged {
            appliedMutation = applyTextMutation(
                previousText: previousText,
                nextText: result.text
            )
            if appliedMutation == nil {
                textView.string = result.text
            }
        }
        textView.setSelectedRange(result.selectedRange)
        textView.typingAttributes = baseAttributes()
        isApplyingModel = false

        pendingEditStartUTF16 = nil

        if textChanged, model.text != result.text {
            model.text = result.text
        }

        if textChanged {
            let refreshStartUTF16: Int
            if let appliedMutation {
                let mutationLineStart = SyntaxEditorRangeUtilities.lineStartUTF16Offset(
                    in: result.text,
                    around: appliedMutation.range.location
                )
                refreshStartUTF16 = min(result.refreshStartUTF16, mutationLineStart)
            } else {
                refreshStartUTF16 = 0
            }

            scheduleHighlight(
                source: result.text,
                language: model.language,
                refreshStartUTF16: refreshStartUTF16
            )
        } else {
            applyMatchingBracketHighlight()
        }
    }

    private func registerUndoAction(restore: EditorUndoState, counterpart: EditorUndoState) {
        guard restore != counterpart else { return }
        guard let activeUndoManager = activeUndoManager else { return }

        activeUndoManager.registerUndo(withTarget: self) { target in
            target.applyUndoAction(restore: restore, counterpart: counterpart)
        }

        if !activeUndoManager.isUndoing, !activeUndoManager.isRedoing {
            activeUndoManager.setActionName("Edit")
        }
    }

    private func applyUndoAction(restore: EditorUndoState, counterpart: EditorUndoState) {
        registerUndoAction(restore: counterpart, counterpart: restore)

        isApplyingUndoRedo = true
        applyCommandResult(
            EditorCommandResult(
                text: restore.text,
                selectedRange: restore.selectedRange,
                refreshStartUTF16: restore.refreshStartUTF16
            )
        )
        isApplyingUndoRedo = false
    }

    private func applyTextMutation(
        previousText: String,
        nextText: String
    ) -> TextMutation? {
        guard let mutation = TextMutation.diff(from: previousText, to: nextText) else {
            return nil
        }

        let textLength = textStorage.length
        guard mutation.range.location + mutation.range.length <= textLength else {
            return nil
        }

        guard textView.shouldChangeText(in: mutation.range, replacementString: mutation.replacement) else {
            return nil
        }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: mutation.range, with: mutation.replacement)
        textStorage.endEditing()
        textView.didChangeText()

        return mutation
    }

    private func handleShortcut(_ action: MacEditorShortcutAction) -> Bool {
        switch action {
        case .indent:
            return runIndentCommand()
        case .outdent:
            return runOutdentCommand()
        case .toggleComment:
            return runToggleCommentCommand()
        }
    }

    private func runIndentCommand() -> Bool {
        let source = textView.string
        guard let result = commandEngine.indentSelection(
            source: source,
            selection: textView.selectedRange()
        ) else {
            return false
        }
        applyCommandResult(result)
        return true
    }

    private func runOutdentCommand() -> Bool {
        let source = textView.string
        guard let result = commandEngine.outdentSelection(
            source: source,
            selection: textView.selectedRange()
        ) else {
            return false
        }
        applyCommandResult(result)
        return true
    }

    private func runToggleCommentCommand() -> Bool {
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

    private func scheduleHighlight(
        source: String,
        language: SyntaxLanguage,
        refreshStartUTF16: Int = 0
    ) {
        let expectedSource = source
        let utf16Length = expectedSource.utf16.count
        let clampedRefreshStart = min(max(0, refreshStartUTF16), utf16Length)
        let refreshRange = NSRange(
            location: clampedRefreshStart,
            length: utf16Length - clampedRefreshStart
        )

        highlightTask?.cancel()

        let highlighter = self.highlighter
        highlightTask = Task { [weak self] in
            let tokens = await highlighter.render(source: expectedSource, language: language)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.applyHighlight(
                tokens,
                expectedSource: expectedSource,
                refreshRange: refreshRange
            )
        }
    }

    private func applyHighlight(
        _ tokens: [SyntaxHighlightToken],
        expectedSource: String,
        refreshRange: NSRange
    ) {
        guard textView.string == expectedSource else { return }

        let textLength = textStorage.length
        let targetRange = SyntaxEditorRangeUtilities.clampedRange(refreshRange, utf16Length: textLength)
        guard targetRange.length > 0 else {
            applyMatchingBracketHighlight()
            return
        }
        let base = baseAttributes()

        isApplyingHighlight = true
        defer { isApplyingHighlight = false }

        textStorage.beginEditing()
        textStorage.setAttributes(base, range: targetRange)

        for token in tokens {
            let clamped = SyntaxEditorRangeUtilities.clampedRange(token.range, utf16Length: textLength)
            let intersection = SyntaxEditorRangeUtilities.intersection(of: clamped, and: targetRange)
            guard intersection.length > 0 else { continue }

            var attributes = base
            for (key, value) in styleAttributes(for: token.captureName) {
                attributes[key] = value
            }
            textStorage.setAttributes(attributes, range: intersection)
        }

        textStorage.endEditing()
        textView.typingAttributes = base
        applyMatchingBracketHighlight()
    }

    private func applyMatchingBracketHighlight() {
        let source = textView.string
        let textLength = textStorage.length

        textStorage.beginEditing()

        for range in matchedBracketRanges {
            let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
            guard clamped.length > 0 else { continue }
            textStorage.removeAttribute(.backgroundColor, range: clamped)
        }

        let newRanges = BracketMatcher.matchedRanges(
            in: source,
            caretUTF16Offset: textView.selectedRange().location
        )

        for range in newRanges {
            let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
            guard clamped.length > 0 else { continue }
            textStorage.addAttribute(
                .backgroundColor,
                value: NSColor.syntaxEditor(dynamic: SyntaxEditorHighlightTheme.bracketBackground).withAlphaComponent(0.24),
                range: clamped
            )
        }

        textStorage.endEditing()
        matchedBracketRanges = newRanges
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.syntaxEditor(dynamic: SyntaxEditorHighlightTheme.baseForeground),
        ]
    }

    private func styleAttributes(for captureName: String) -> [NSAttributedString.Key: Any] {
        guard let pair = SyntaxEditorHighlightTheme.colorPair(for: captureName) else {
            return [:]
        }
        return [.foregroundColor: NSColor.syntaxEditor(dynamic: pair)]
    }

    private func applyLineWrappingConfiguration(lineWrappingEnabled: Bool) {
        if lineWrappingEnabled {
            textView.isHorizontallyResizable = false
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
            textContainer.lineBreakMode = .byWordWrapping
        } else {
            textView.isHorizontallyResizable = true
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = false
            textContainer.lineBreakMode = .byClipping
        }
    }
}

private extension NSColor {
    static func syntaxEditor(dynamic pair: SyntaxEditorHexColorPair) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            let isDark = match == .darkAqua || match == .vibrantDark
            return syntaxEditor(hex: isDark ? pair.dark : pair.light)
        }
    }

    static func syntaxEditor(hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
    }
}
#endif
