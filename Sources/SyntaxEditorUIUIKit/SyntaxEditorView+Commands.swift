#if canImport(UIKit)
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView {
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if isUndoAction(action) {
            return model.isEditable && (activeUndoManager?.canUndo ?? false)
        }

        if isRedoAction(action) {
            return model.isEditable && (activeUndoManager?.canRedo ?? false)
        }

        if isLineWrappingCommandAction(action) {
            return true
        }

        if isFontSizeCommandAction(action) {
            return true
        }

        if action == #selector(handlePasteCommand) {
            return model.isEditable
        }

        if action == #selector(handleInsertTabCommand) {
            return model.isEditable
        }

        if isEditorCommandAction(action) {
            return model.isEditable && model.language.supportsCodeEditingCommands
        }

        switch action {
        case #selector(UIResponderStandardEditActions.useSelectionForFind(_:)):
            return isFindInteractionEnabled && findInteraction != nil && selectedRange.length > 0
        case #selector(UIResponderStandardEditActions.copy(_:)):
            return isSelectable && selectedRange.length > 0
        case #selector(UIResponderStandardEditActions.cut(_:)),
             #selector(UIResponderStandardEditActions.delete(_:)):
            return model.isEditable && selectedRange.length > 0
        case #selector(UIResponderStandardEditActions.paste(_:)):
            return model.isEditable && UIPasteboard.general.hasStrings
        case #selector(UIResponderStandardEditActions.selectAll(_:)):
            return isSelectable && !text.isEmpty
        default:
            if isFindAndReplaceCommandAction(action) {
                return model.isEditable && isFindInteractionEnabled && findInteraction != nil
            }
            if isFindCommandAction(action) {
                return isFindInteractionEnabled && findInteraction != nil
            }
            return super.canPerformAction(action, withSender: sender)
        }
    }

    public override func validate(_ command: UICommand) {
        super.validate(command)

        guard let editorCommand = SyntaxEditorMenu.Command(selector: command.action) else {
            return
        }

        command.attributes = canPerformAction(command.action, withSender: command) ? [] : .disabled
        command.state = editorCommand == .wrapLines && model.lineWrappingEnabled ? .on : .off
    }

    public override func copy(_ sender: Any?) {
        guard selectedRange.length > 0,
              let selectedText = string(in: selectedRange)
        else {
            return
        }
        UIPasteboard.general.string = selectedText
    }

    public override func cut(_ sender: Any?) {
        guard model.isEditable, selectedRange.length > 0 else { return }
        copy(sender)
        applyUserReplacement(in: selectedRange, replacement: "", deletionIntent: .unspecified)
    }

    public override func paste(_ sender: Any?) {
        guard model.isEditable,
              let pastedText = UIPasteboard.general.string
        else {
            return
        }
        insertPastedText(pastedText)
    }

    func insertPastedText(_ pastedText: String) {
        guard model.isEditable else { return }
        insertText(pastedText)
    }

    public override func delete(_ sender: Any?) {
        guard model.isEditable else { return }
        if selectedRange.length > 0 {
            applyUserReplacement(in: selectedRange, replacement: "", deletionIntent: .unspecified)
        } else {
            deleteBackward()
        }
    }

    public override func selectAll(_ sender: Any?) {
        guard isSelectable else { return }
        selectedRange = NSRange(location: 0, length: text.utf16.count)
    }

    public override func find(_ sender: Any?) {
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    public override func findAndReplace(_ sender: Any?) {
        guard model.isEditable else { return }
        findInteraction?.presentFindNavigator(showingReplace: true)
    }

    public override func findNext(_ sender: Any?) {
        findInteraction?.findNext()
    }

    public override func findPrevious(_ sender: Any?) {
        findInteraction?.findPrevious()
    }

    public override func useSelectionForFind(_ sender: Any?) {
        guard selectedRange.length > 0,
              let selectedText = string(in: selectedRange)
        else {
            return
        }
        findInteraction?.searchText = selectedText
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    @objc private func undo(_ sender: Any?) {
        handleUndoCommand()
    }

    @objc private func redo(_ sender: Any?) {
        handleRedoCommand()
    }

    func configureUndoObservation() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleUndoManagerStateDidChange),
            name: .NSUndoManagerDidCloseUndoGroup,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleUndoManagerStateDidChange),
            name: .NSUndoManagerDidUndoChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleUndoManagerStateDidChange),
            name: .NSUndoManagerDidRedoChange,
            object: nil
        )
    }

    @objc
    func handleUndoManagerStateDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === guardedUndoManager else { return }
        refreshKeyboardAccessoryState()
    }

    func editorKeyCommands() -> [UIKeyCommand]? {
        let supportsCodeEditingCommands = model.isEditable && model.language.supportsCodeEditingCommands
        var commands = SyntaxEditorMenu.makeKeyCommands(includeEditingCommands: supportsCodeEditingCommands)

        guard model.isEditable else {
            return commands
        }

        commands.append(
            makeKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleInsertTabCommand), title: "Insert Tab")
        )

        if supportsCodeEditingCommands {
            commands.append(
                makeKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(handleOutdentCommand), title: "Outdent")
            )
        }

        commands.append(contentsOf: [
            makeKeyCommand(
                input: "v",
                modifierFlags: [.command],
                action: #selector(handlePasteCommand),
                title: "Paste"
            ),
        ])
        return commands
    }

    func isEditorCommandAction(_ action: Selector) -> Bool {
        if let command = SyntaxEditorMenu.Command(selector: action) {
            return command.isEditingCommand
        }

        return action == #selector(handleInsertTabCommand)
            || action == #selector(handleOutdentCommand)
    }

    func isLineWrappingCommandAction(_ action: Selector) -> Bool {
        SyntaxEditorMenu.Command(selector: action) == .wrapLines
    }

    func isFontSizeCommandAction(_ action: Selector) -> Bool {
        switch SyntaxEditorMenu.Command(selector: action) {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize:
            true
        case .shiftRight, .shiftLeft, .commentSelection, .wrapLines, nil:
            false
        }
    }

    func isFindCommandAction(_ action: Selector) -> Bool {
        action == #selector(UIResponderStandardEditActions.find(_:))
            || action == #selector(UIResponderStandardEditActions.findNext(_:))
            || action == #selector(UIResponderStandardEditActions.findPrevious(_:))
    }

    func isFindAndReplaceCommandAction(_ action: Selector) -> Bool {
        action == #selector(UIResponderStandardEditActions.findAndReplace(_:))
    }

    func isUndoAction(_ action: Selector) -> Bool {
        NSStringFromSelector(action) == "undo:"
    }

    func isRedoAction(_ action: Selector) -> Bool {
        let actionName = NSStringFromSelector(action)
        return actionName == "redo:"
    }

    func makeKeyCommand(
        input: String,
        modifierFlags: UIKeyModifierFlags,
        action: Selector,
        title: String
    ) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifierFlags, action: action)
        command.discoverabilityTitle = title
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    #if !os(visionOS)
    func makeInputAccessoryView() -> UIView {
        let accessoryModel = SyntaxEditorKeyboardAccessoryModel(
            onUndo: { [weak self] in
                self?.handleUndoCommand()
            },
            onRedo: { [weak self] in
                self?.handleRedoCommand()
            },
            onDismissKeyboard: { [weak self] in
                self?.handleDismissKeyboardCommand()
            }
        )
        keyboardAccessoryModel = accessoryModel
        return SyntaxEditorKeyboardAccessoryView(model: accessoryModel)
    }
    #endif

    var activeUndoManager: UndoManager? {
        guardedUndoManager
    }

    func refreshKeyboardAccessoryState() {
        #if !os(visionOS)
        guard let keyboardAccessoryModel else { return }
        keyboardAccessoryModel.isUndoable = model.isEditable && (activeUndoManager?.canUndo ?? false)
        keyboardAccessoryModel.isRedoable = model.isEditable && (activeUndoManager?.canRedo ?? false)
        #endif
    }
    @objc public func syntaxEditorShiftRight(_ sender: Any?) {
        handleIndentCommand()
    }

    @objc public func syntaxEditorShiftLeft(_ sender: Any?) {
        handleOutdentCommand()
    }

    @objc public func syntaxEditorCommentSelection(_ sender: Any?) {
        handleToggleCommentCommand()
    }

    @objc public func syntaxEditorToggleLineWrapping(_ sender: Any?) {
        handleToggleLineWrappingCommand()
    }

    @objc public func syntaxEditorIncreaseFontSize(_ sender: Any?) {
        handleIncreaseFontSizeCommand()
    }

    @objc public func syntaxEditorDecreaseFontSize(_ sender: Any?) {
        handleDecreaseFontSizeCommand()
    }

    @objc public func syntaxEditorResetFontSize(_ sender: Any?) {
        handleResetFontSizeCommand()
    }

    @objc private func handleIndentCommand() {
        guard model.isEditable, model.language.supportsCodeEditingCommands else { return }

        guard let result = commandEngine.indentSelection(
            source: text,
            selection: selectedRange,
            language: model.language
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handleInsertTabCommand() {
        guard model.isEditable else { return }

        guard model.language.supportsCodeEditingCommands else {
            insertText("\t")
            return
        }

        guard let result = commandEngine.insertTab(
            source: text,
            selection: selectedRange,
            language: model.language
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handleOutdentCommand() {
        guard model.isEditable, model.language.supportsCodeEditingCommands else { return }

        guard let result = commandEngine.outdentSelection(
            source: text,
            selection: selectedRange,
            language: model.language
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handleToggleCommentCommand() {
        guard model.isEditable, model.language.supportsCodeEditingCommands else { return }

        guard let result = commandEngine.toggleComment(
            source: text,
            selection: selectedRange,
            language: model.language
        ) else {
            return
        }
        applyCommandResult(result)
    }

    @objc private func handlePasteCommand() {
        paste(nil)
    }

    @objc private func handleToggleLineWrappingCommand() {
        model.lineWrappingEnabled.toggle()
    }

    @objc private func handleIncreaseFontSizeCommand() {
        model.increaseFontSize()
    }

    @objc private func handleDecreaseFontSizeCommand() {
        model.decreaseFontSize()
    }

    @objc private func handleResetFontSizeCommand() {
        model.resetFontSize()
    }

    @objc private func handleUndoCommand() {
        guard model.isEditable else {
            refreshKeyboardAccessoryState()
            return
        }

        activeUndoManager?.undo()
        refreshKeyboardAccessoryState()
    }

    @objc private func handleRedoCommand() {
        guard model.isEditable else {
            refreshKeyboardAccessoryState()
            return
        }

        activeUndoManager?.redo()
        refreshKeyboardAccessoryState()
    }

    @objc private func handleDismissKeyboardCommand() {
        window?.endEditing(true)
    }
}
#endif
