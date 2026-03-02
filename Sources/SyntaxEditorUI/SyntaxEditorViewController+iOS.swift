#if canImport(UIKit)
import Observation
import ObservationsCompat
import UIKit

@MainActor
@Observable
public final class SyntaxEditorViewController: UIViewController, UITextViewDelegate {
    public private(set) var model: SyntaxEditorModel
    public let textView: UITextView
    @ObservationIgnored
    private let fallbackUndoManager = UndoManager()

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

        let textContainer = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(textContainer)

        self.textView = UITextView(frame: .zero, textContainer: textContainer)

        super.init(nibName: nil, bundle: nil)
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
        view = textView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
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

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else {
            return
        }

        textView.typingAttributes = baseAttributes()
        scheduleHighlight(
            source: textView.text ?? "",
            language: model.language,
            refreshStartUTF16: 0
        )
    }

    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleIndentCommand), discoverabilityTitle: "Indent"),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(handleOutdentCommand), discoverabilityTitle: "Outdent"),
            UIKeyCommand(input: "/", modifierFlags: [.command], action: #selector(handleToggleCommentCommand), discoverabilityTitle: "Toggle Comment"),
            UIKeyCommand(input: "]", modifierFlags: [.command], action: #selector(handleIndentCommand), discoverabilityTitle: "Indent"),
            UIKeyCommand(input: "[", modifierFlags: [.command], action: #selector(handleOutdentCommand), discoverabilityTitle: "Outdent"),
        ]
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingModel, !isApplyingHighlight else {
            pendingEditStartUTF16 = nil
            return
        }

        let nextText = textView.text ?? ""
        if model.text != nextText {
            model.text = nextText
        }

        let editStartUTF16 = pendingEditStartUTF16 ?? textView.selectedRange.location
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

    public func textViewDidChangeSelection(_ textView: UITextView) {
        applyMatchingBracketHighlight()
    }

    public func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard !isApplyingModel, !isApplyingHighlight else {
            return true
        }

        pendingEditStartUTF16 = range.location

        let currentSource = textView.text ?? ""
        if let result = commandEngine.transformInput(
            source: currentSource,
            range: range,
            replacementText: text,
            language: model.language
        ) {
            applyCommandResult(result)
            return false
        }

        return true
    }

    private func configureTextView() {
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.delegate = self
        textView.isEditable = model.isEditable

        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no

        applyLineWrappingConfiguration(lineWrappingEnabled: model.lineWrappingEnabled)
        textView.typingAttributes = baseAttributes()
        textView.inputAccessoryView = makeInputAccessoryView()
    }

    private func makeInputAccessoryView() -> UIView {
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(title: "Tab", style: .plain, target: self, action: #selector(handleIndentCommand)),
            UIBarButtonItem(title: "⇤", style: .plain, target: self, action: #selector(handleOutdentCommand)),
            UIBarButtonItem(title: "//", style: .plain, target: self, action: #selector(handleToggleCommentCommand)),
            .flexibleSpace(),
            UIBarButtonItem(title: "Undo", style: .plain, target: self, action: #selector(handleUndoCommand)),
            UIBarButtonItem(title: "Redo", style: .plain, target: self, action: #selector(handleRedoCommand)),
        ]
        toolbar.sizeToFit()
        return toolbar
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

        let textNeedsUpdate = forceTextUpdate || textView.text != text
        if textNeedsUpdate {
            textView.text = text
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

        let languageChanged = forceLanguageRefresh || lastAppliedLanguage != language
        lastAppliedLanguage = language

        textView.typingAttributes = baseAttributes()
        if languageChanged {
            scheduleHighlight(
                source: textView.text ?? "",
                language: language,
                refreshStartUTF16: 0
            )
        }
    }

    private func applyCommandResult(_ result: EditorCommandResult) {
        let previousText = textView.text ?? ""
        let previousSelection = textView.selectedRange
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
                textView.text = result.text
            }
        }
        textView.selectedRange = result.selectedRange
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

        let textLength = (textView.text as NSString?)?.length ?? 0
        guard mutation.range.location + mutation.range.length <= textLength else {
            return nil
        }

        guard let start = textView.position(
            from: textView.beginningOfDocument,
            offset: mutation.range.location
        ),
            let end = textView.position(
                from: start,
                offset: mutation.range.length
            ),
            let textRange = textView.textRange(from: start, to: end)
        else {
            return nil
        }

        textView.replace(textRange, withText: mutation.replacement)

        return mutation
    }

    @objc private func handleIndentCommand() {
        let source = textView.text ?? ""
        guard let result = commandEngine.indentSelection(
            source: source,
            selection: textView.selectedRange
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handleOutdentCommand() {
        let source = textView.text ?? ""
        guard let result = commandEngine.outdentSelection(
            source: source,
            selection: textView.selectedRange
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handleToggleCommentCommand() {
        let source = textView.text ?? ""
        guard let result = commandEngine.toggleComment(
            source: source,
            selection: textView.selectedRange,
            language: model.language
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handleUndoCommand() {
        let handled = UIApplication.shared.sendAction(
            Selector(("undo:")),
            to: nil,
            from: self,
            for: nil
        )
        if !handled {
            activeUndoManager?.undo()
        }
    }

    @objc private func handleRedoCommand() {
        let handled = UIApplication.shared.sendAction(
            Selector(("redo:")),
            to: nil,
            from: self,
            for: nil
        )
        if !handled {
            activeUndoManager?.redo()
        }
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
        guard textView.text == expectedSource else { return }

        let textStorage = textView.textStorage
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
        let source = textView.text ?? ""
        let textStorage = textView.textStorage
        let textLength = textStorage.length

        textStorage.beginEditing()

        for range in matchedBracketRanges {
            let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
            guard clamped.length > 0 else { continue }
            textStorage.removeAttribute(.backgroundColor, range: clamped)
        }

        let newRanges = BracketMatcher.matchedRanges(
            in: source,
            caretUTF16Offset: textView.selectedRange.location
        )

        for range in newRanges {
            let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
            guard clamped.length > 0 else { continue }
            textStorage.addAttribute(
                .backgroundColor,
                value: UIColor.syntaxEditor(dynamic: SyntaxEditorHighlightTheme.bracketBackground).withAlphaComponent(0.24),
                range: clamped
            )
        }

        textStorage.endEditing()
        matchedBracketRanges = newRanges
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.syntaxEditor(dynamic: SyntaxEditorHighlightTheme.baseForeground),
        ]
    }

    private func styleAttributes(for captureName: String) -> [NSAttributedString.Key: Any] {
        guard let pair = SyntaxEditorHighlightTheme.colorPair(for: captureName) else {
            return [:]
        }
        return [.foregroundColor: UIColor.syntaxEditor(dynamic: pair)]
    }

    private func applyLineWrappingConfiguration(lineWrappingEnabled: Bool) {
        if lineWrappingEnabled {
            textView.textContainer.widthTracksTextView = true
            textView.textContainer.lineBreakMode = .byWordWrapping
        } else {
            textView.textContainer.widthTracksTextView = false
            textView.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer.lineBreakMode = .byClipping
        }
    }
}

private extension UIColor {
    static func syntaxEditor(dynamic pair: SyntaxEditorHexColorPair) -> UIColor {
        UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return syntaxEditor(hex: pair.dark)
            }
            return syntaxEditor(hex: pair.light)
        }
    }

    static func syntaxEditor(hex: UInt32) -> UIColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
#endif
