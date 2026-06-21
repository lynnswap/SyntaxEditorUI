#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    @objc func syntaxEditorShiftRight(_ sender: Any?) {
        _ = shortcutHandler?(.indent)
    }

    @objc func syntaxEditorShiftLeft(_ sender: Any?) {
        _ = shortcutHandler?(.outdent)
    }

    @objc func syntaxEditorCommentSelection(_ sender: Any?) {
        _ = shortcutHandler?(.toggleComment)
    }

    @objc func syntaxEditorToggleLineWrapping(_ sender: Any?) {
        _ = shortcutHandler?(.toggleLineWrapping)
    }

    @objc func syntaxEditorIncreaseFontSize(_ sender: Any?) {
        _ = shortcutHandler?(.increaseFontSize)
    }

    @objc func syntaxEditorDecreaseFontSize(_ sender: Any?) {
        _ = shortcutHandler?(.decreaseFontSize)
    }

    @objc func syntaxEditorResetFontSize(_ sender: Any?) {
        _ = shortcutHandler?(.resetFontSize)
    }


    override func menu(for event: NSEvent) -> NSMenu? {
        guard isSelectable else { return nil }
        unsafe window?.makeFirstResponder(self)
        return makeContextualEditMenu()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return undoManager?.canUndo ?? false
        }
        if item.action == #selector(redo(_:)) {
            return undoManager?.canRedo ?? false
        }
        if item.action == #selector(copy(_:)) {
            return canCopySelection
        }
        if item.action == #selector(cut(_:)) {
            return canCutSelection
        }
        if item.action == #selector(paste(_:)) {
            return canPaste
        }
        if item.action == #selector(delete(_:)) {
            return isEditable && selectedRangeStorage.length > 0
        }
        if item.action == #selector(selectAll(_:)) {
            return isSelectable
        }
        if let command = SyntaxEditorMenu.Command(selector: item.action),
           let action = EditorShortcutAction(command: command) {
            let canHandle = shortcutValidator?(action) ?? true
            if command == .wrapLines, let menuItem = item as? NSMenuItem {
                menuItem.state = lineWrappingStateProvider?() == true ? .on : .off
            }
            return canHandle
        }
        return true
    }

    private func makeContextualEditMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeContextualEditMenuItem(title: "Cut", action: #selector(cut(_:))))
        menu.addItem(makeContextualEditMenuItem(title: "Copy", action: #selector(copy(_:))))
        menu.addItem(makeContextualEditMenuItem(title: "Paste", action: #selector(paste(_:))))
        return menu
    }

    private func makeContextualEditMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let window = unsafe self.window,
           window.firstResponder !== self {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""

        if key.lowercased() == "l",
           modifiers.contains(.command),
           modifiers.contains(.control),
           modifiers.contains(.shift),
           !modifiers.contains(.option),
           shortcutHandler?(.toggleLineWrapping) == true {
            return true
        }

        if key == "0",
           modifiers.contains(.command),
           modifiers.contains(.control),
           !modifiers.contains(.option),
           !modifiers.contains(.shift),
           shortcutHandler?(.resetFontSize) == true {
            return true
        }

        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option)
        else {
            return super.performKeyEquivalent(with: event)
        }

        if key == "+" || key == "=" {
            return shortcutHandler?(.increaseFontSize) == true || super.performKeyEquivalent(with: event)
        }
        if key == "-" {
            return shortcutHandler?(.decreaseFontSize) == true || super.performKeyEquivalent(with: event)
        }
        if key == "/" {
            return shortcutHandler?(.toggleComment) == true || super.performKeyEquivalent(with: event)
        }
        if key == "]" {
            return shortcutHandler?(.indent) == true || super.performKeyEquivalent(with: event)
        }
        if key == "[" {
            return shortcutHandler?(.outdent) == true || super.performKeyEquivalent(with: event)
        }
        if key.lowercased() == "c", canCopySelection {
            copy(nil)
            return true
        }
        if key.lowercased() == "x", canCutSelection {
            cut(nil)
            return true
        }
        if key.lowercased() == "v", canPaste {
            paste(nil)
            return true
        }
        if key.lowercased() == "a", isSelectable {
            selectAll(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if commandHandler?(selector) == true {
            return
        }

        switch selector {
        case #selector(selectAll(_:)):
            selectAll(nil)
        case #selector(insertNewline(_:)):
            insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        case #selector(deleteBackward(_:)):
            deleteBackward()
        case #selector(deleteForward(_:)):
            deleteForward()
        case #selector(moveLeft(_:)):
            moveSelection(direction: .left, destination: .character, extending: false, confined: false)
        case #selector(moveLeftAndModifySelection(_:)):
            moveSelection(direction: .left, destination: .character, extending: true, confined: false)
        case #selector(moveRight(_:)):
            moveSelection(direction: .right, destination: .character, extending: false, confined: false)
        case #selector(moveRightAndModifySelection(_:)):
            moveSelection(direction: .right, destination: .character, extending: true, confined: false)
        case #selector(moveUp(_:)):
            moveSelection(direction: .up, destination: .character, extending: false, confined: false)
        case #selector(moveUpAndModifySelection(_:)):
            moveSelection(direction: .up, destination: .character, extending: true, confined: false)
        case #selector(moveDown(_:)):
            moveSelection(direction: .down, destination: .character, extending: false, confined: false)
        case #selector(moveDownAndModifySelection(_:)):
            moveSelection(direction: .down, destination: .character, extending: true, confined: false)
        case #selector(moveWordLeft(_:)):
            moveSelection(direction: .left, destination: .word, extending: false, confined: false)
        case #selector(moveWordLeftAndModifySelection(_:)):
            moveSelection(direction: .left, destination: .word, extending: true, confined: false)
        case #selector(moveWordRight(_:)):
            moveSelection(direction: .right, destination: .word, extending: false, confined: false)
        case #selector(moveWordRightAndModifySelection(_:)):
            moveSelection(direction: .right, destination: .word, extending: true, confined: false)
        case #selector(moveWordForward(_:)):
            moveSelection(direction: .forward, destination: .word, extending: false, confined: false)
        case #selector(moveWordForwardAndModifySelection(_:)):
            moveSelection(direction: .forward, destination: .word, extending: true, confined: false)
        case #selector(moveWordBackward(_:)):
            moveSelection(direction: .backward, destination: .word, extending: false, confined: false)
        case #selector(moveWordBackwardAndModifySelection(_:)):
            moveSelection(direction: .backward, destination: .word, extending: true, confined: false)
        case #selector(moveToBeginningOfLine(_:)),
             #selector(moveToLeftEndOfLine(_:)):
            moveSelection(direction: .backward, destination: .line, extending: false, confined: true)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)),
             #selector(moveToLeftEndOfLineAndModifySelection(_:)):
            moveSelection(direction: .backward, destination: .line, extending: true, confined: true)
        case #selector(moveToEndOfLine(_:)),
             #selector(moveToRightEndOfLine(_:)):
            moveSelection(direction: .forward, destination: .line, extending: false, confined: true)
        case #selector(moveToEndOfLineAndModifySelection(_:)),
             #selector(moveToRightEndOfLineAndModifySelection(_:)):
            moveSelection(direction: .forward, destination: .line, extending: true, confined: true)
        case #selector(moveToBeginningOfDocument(_:)):
            moveSelection(direction: .backward, destination: .document, extending: false, confined: false)
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)):
            moveSelection(direction: .backward, destination: .document, extending: true, confined: false)
        case #selector(moveToEndOfDocument(_:)):
            moveSelection(direction: .forward, destination: .document, extending: false, confined: false)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)):
            moveSelection(direction: .forward, destination: .document, extending: true, confined: false)
        default:
            break
        }
    }

    override func selectAll(_ sender: Any?) {
        guard isSelectable else { return }
        setSelectedRange(NSRange(location: 0, length: storage.length))
    }

    @objc func copy(_ sender: Any?) {
        copySelectionToPasteboard()
    }

    @objc func cut(_ sender: Any?) {
        guard isEditable,
              copySelectionToPasteboard()
        else {
            return
        }
        replaceText(
            in: selectedRangeStorage,
            with: "",
            selectedRange: NSRange(location: selectedRangeStorage.location, length: 0)
        )
    }

    @objc func paste(_ sender: Any?) {
        guard isEditable,
              let pastedString = NSPasteboard.general.string(forType: .string)
        else {
            return
        }
        let range = selectedRangeStorage
        replaceText(
            in: range,
            with: pastedString,
            selectedRange: NSRange(location: range.location + pastedString.utf16.count, length: 0)
        )
    }

    @objc func delete(_ sender: Any?) {
        guard isEditable,
              selectedRangeStorage.length > 0
        else {
            return
        }
        replaceText(
            in: selectedRangeStorage,
            with: "",
            selectedRange: NSRange(location: selectedRangeStorage.location, length: 0)
        )
    }

    private func deleteBackward() {
        if selectedRangeStorage.length > 0 {
            replaceText(in: selectedRangeStorage, with: "", selectedRange: NSRange(location: selectedRangeStorage.location, length: 0))
        } else if selectedRangeStorage.location > 0 {
            let source = string as NSString
            let range = source.rangeOfComposedCharacterSequence(at: selectedRangeStorage.location - 1)
            replaceText(in: range, with: "", selectedRange: NSRange(location: range.location, length: 0))
        }
    }

    private func deleteForward() {
        if selectedRangeStorage.length > 0 {
            replaceText(in: selectedRangeStorage, with: "", selectedRange: NSRange(location: selectedRangeStorage.location, length: 0))
        } else if selectedRangeStorage.location < storage.length {
            let source = string as NSString
            let range = source.rangeOfComposedCharacterSequence(at: selectedRangeStorage.location)
            replaceText(in: range, with: "", selectedRange: NSRange(location: range.location, length: 0))
        }
    }

    private var canCopySelection: Bool {
        isSelectable && selectedRangeStorage.length > 0
    }

    private var canCutSelection: Bool {
        isEditable && canCopySelection
    }

    private var canPaste: Bool {
        isEditable && NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue])
    }

    @discardableResult
    private func copySelectionToPasteboard() -> Bool {
        guard canCopySelection else { return false }
        let clampedRange = SyntaxEditorRangeUtilities.clampedRange(
            selectedRangeStorage,
            utf16Length: storage.length
        )
        guard clampedRange.length > 0 else { return false }

        let selectedString = (storage.string as NSString).substring(with: clampedRange)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(selectedString, forType: .string)
    }
}
#endif
