# Integrating with AppKit

Host the editor in a macOS window or view-controller hierarchy.

## Create a native editor

```swift
import AppKit
import SyntaxEditorUI

@MainActor
func makeEditor() -> SyntaxEditorViewController {
    let model = SyntaxEditorModel(
        text: "let answer = 42",
        language: .swift
    )
    return SyntaxEditorViewController(model: model)
}
```

Use the controller as a window's content controller or embed it in your app's existing container. Its `editorView` is also the scroll view. If your container already owns a view controller, create ``SyntaxEditorView-77bw3`` directly.

Keep document state in ``SyntaxEditorModel``. The editor uses TextKit 2 and does not expose an underlying `NSTextView`.

## Add an Editor menu

Insert the editor commands after your application has created its main menu:

```swift
if let mainMenu = NSApp.mainMenu {
    SyntaxEditorMenu.insert(into: mainMenu)
}
```

The commands follow the responder chain to the focused editor. See <doc:Editing> for the shortcuts and ``SyntaxEditorMenu`` for menu construction.

## Find and replace

The editor supports the standard Find commands and an AppKit find bar. Use `Cmd+F` to show Find, `Cmd+G` for the next match, and `Shift+Cmd+G` for the previous match. Editing and replacement remain subject to the model's `isEditable` setting.

## Compare with a reference document

Use the same editor model for editing and saving, and keep a comparison model in your app's document state:

```swift
let document = SyntaxEditorModel(text: currentText, language: .swift)
let comparison = SyntaxEditorComparisonModel(
    originalText: referenceText,
    modified: document,
    presentation: .inline
)
let controller = SyntaxEditorComparisonViewController(model: comparison)
window.contentViewController = controller
```

Change `comparison.presentation` to `.changeMarkers`, `.inline`, or `.sideBySide` without recreating the modified editor. The reference is read-only and follows the modified document's language, theme, font size, and wrapping settings. The app supplies both texts; the comparison does not access files or source control.

Use `selectNextChange()` and `selectPreviousChange()` for navigation. Both return whether a change was selected and preserve the modified document's text selection. `changeCount` is `nil` while the current texts are being compared. Previous difference decorations are removed while a new result is pending.

Inline deleted text supports native selection and copying. Find from a deleted block opens the full reference pane. Each pane in side-by-side presentation has its own Find interface.

The view preserves the viewed text position across geometry changes and comparison updates. Scrolling while a calculation is pending replaces the saved position. Access `controller.editorView.modifiedEditor` to configure its native scroll-view settings, or use ``SyntaxEditorComparisonView`` directly in an existing view hierarchy.

## Topics

### Native editor

- ``SyntaxEditorView-77bw3``
- ``SyntaxEditorViewController-16tjt``

### Document comparison

- ``SyntaxEditorComparisonView``
- ``SyntaxEditorComparisonViewController``
- ``SyntaxEditorComparisonModel``
