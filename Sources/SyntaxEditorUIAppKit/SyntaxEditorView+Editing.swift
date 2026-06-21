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

  extension SyntaxEditorView {

    public func textDidChange(_ notification: Notification) {
      textDidChange()
    }

    func textDidChange() {
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
      case .incremental(let pendingMutation):
        mutation = pendingMutation
        change = model.commitTextReplacements(
          [
            SyntaxEditorTextChange.Replacement(
              range: NSRange(location: pendingMutation.location, length: pendingMutation.length),
              replacement: pendingMutation.replacement
            )
          ],
          selectedRange: textView.selectedRange()
        )
      case .fullReset:
        mutation = nil
        change = model.replaceText(nextText, selectedRange: textView.selectedRange())
      case .none:
        mutation = SyntaxEditorTextChange.Replacement.singleReplacement(
          from: previousText, to: nextText)
        if let mutation {
          change = model.commitTextReplacements(
            [
              SyntaxEditorTextChange.Replacement(
                range: NSRange(location: mutation.location, length: mutation.length),
                replacement: mutation.replacement
              )
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

    func textSelectionDidChange() {
      if !isApplyingModel {
        model.selectedRange = textView.selectedRange()
      }
      if !isApplyingCommandSelection {
        commandEngine.invalidateTransientState()
      }
      applyMatchingBracketHighlight()
      applyPendingHighlightIfSelectionAllows()
    }

    func textShouldChange(inRanges affectedRanges: [NSRange], replacementStrings: [String]) -> Bool
    {
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

    func textView(_ textView: SyntaxEditorTextInputView, doCommandBy commandSelector: Selector)
      -> Bool
    {
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

    var activeUndoManager: UndoManager? {
      textView.undoManager ?? fallbackUndoManager
    }

    private func applyCommandResult(_ result: EditorCommandEngine.Result) {
      guard model.isEditable else {
        return
      }

      let previousText = textView.string
      let previousSelection = textView.selectedRange()
      let textChanged = !result.edits.isEmpty
      let nextText =
        textChanged
        ? SyntaxEditorModel.applying(result.edits, to: previousText)
        : previousText

      let undoState:
        (restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState)? =
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

    private func registerUndoAction(
      restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState
    ) {
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
          )
        ]
        restoreEdits = SyntaxEditorModel.inverseReplacements(for: edits, in: previousText)
      } else {
        edits = [
          SyntaxEditorTextChange.Replacement(
            range: NSRange(location: 0, length: previousText.utf16.count),
            replacement: nextText
          )
        ]
        restoreEdits = [
          SyntaxEditorTextChange.Replacement(
            range: NSRange(location: 0, length: nextText.utf16.count),
            replacement: previousText
          )
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

    private func applyUndoAction(
      restore: EditorCommandEngine.UndoState, counterpart: EditorCommandEngine.UndoState
    ) {
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
      guard
        textView.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
      else {
        return false
      }

      guard applyStorageTextEdits(edits) else { return false }
      textView.didChangeTextNotification()
      return true
    }

    func canHandleShortcut(_ action: EditorShortcutAction) -> Bool {
      switch action {
      case .indent, .outdent, .toggleComment:
        model.isEditable && model.language.supportsCodeEditingCommands
      case .toggleLineWrapping, .increaseFontSize, .decreaseFontSize, .resetFontSize:
        true
      }
    }

    func handleShortcut(_ action: EditorShortcutAction) -> Bool {
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
      guard
        let result = commandEngine.insertTab(
          source: source,
          selection: textView.selectedRange(),
          language: model.language
        )
      else {
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
      guard
        let result = commandEngine.indentSelection(
          source: source,
          selection: textView.selectedRange(),
          language: model.language
        )
      else {
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
      guard
        let result = commandEngine.outdentSelection(
          source: source,
          selection: textView.selectedRange(),
          language: model.language
        )
      else {
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
      guard
        let result = commandEngine.toggleComment(
          source: source,
          selection: textView.selectedRange(),
          language: model.language
        )
      else {
        return false
      }
      applyCommandResult(result)
      return true
    }

    private func runToggleLineWrappingCommand() -> Bool {
      model.lineWrappingEnabled.toggle()
      return true
    }

  }
#endif
