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

    func makeContextualEditMenu() -> NSMenu {
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

    func deleteBackward() {
        if selectedRangeStorage.length > 0 {
            replaceText(in: selectedRangeStorage, with: "", selectedRange: NSRange(location: selectedRangeStorage.location, length: 0))
        } else if selectedRangeStorage.location > 0 {
            let source = string as NSString
            let range = source.rangeOfComposedCharacterSequence(at: selectedRangeStorage.location - 1)
            replaceText(in: range, with: "", selectedRange: NSRange(location: range.location, length: 0))
        }
    }

    func deleteForward() {
        if selectedRangeStorage.length > 0 {
            replaceText(in: selectedRangeStorage, with: "", selectedRange: NSRange(location: selectedRangeStorage.location, length: 0))
        } else if selectedRangeStorage.location < storage.length {
            let source = string as NSString
            let range = source.rangeOfComposedCharacterSequence(at: selectedRangeStorage.location)
            replaceText(in: range, with: "", selectedRange: NSRange(location: range.location, length: 0))
        }
    }

    var canCopySelection: Bool {
        isSelectable && selectedRangeStorage.length > 0
    }

    var canCutSelection: Bool {
        isEditable && canCopySelection
    }

    var canPaste: Bool {
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
