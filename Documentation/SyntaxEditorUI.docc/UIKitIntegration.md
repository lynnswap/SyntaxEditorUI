# Integrating with UIKit

Host the editor in an iOS, Mac Catalyst, or visionOS view hierarchy.

## Create a native editor

```swift
import UIKit
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

Present the controller or add it to your app's existing container with normal view-controller containment. Its `editorView` is the editing and scrolling surface. If your container already owns a view controller, create ``SyntaxEditorView-6lnwr`` directly and constrain it to the available space.

Keep document state in ``SyntaxEditorModel``; do not expect an underlying `UITextView`. The native view handles text input and scrolling itself.

## Add an Editor menu

On iOS 26 and later, call this once from app launch, outside a menu-building callback:

```swift
if #available(iOS 26.0, *) {
    UIMainMenuSystem.shared.setBuildConfiguration(
        UIMainMenuSystem.Configuration()
    ) { builder in
        SyntaxEditorMenu.insert(into: builder)
    }
}
```

Apps that already customize menus through `buildMenu(with:)` can call `SyntaxEditorMenu.insert(into:)` from that app-delegate method instead. See Apple's [main menu configuration](https://developer.apple.com/documentation/uikit/uimainmenusystem/setbuildconfiguration(_:buildhandler:)).

Commands act on the focused editor. On iPadOS, first-responder shortcuts may also appear in Help > Other Keyboard Shortcuts. See <doc:Editing> for the shortcut list.

## Support pointer selection

Indirect input is enabled by default on the iOS versions supported by this package. If your app explicitly sets `UIApplicationSupportsIndirectInputEvents` to `NO`, remove that opt-out or set it to `YES` so UIKit can distinguish pointer clicks from direct touches. visionOS always supports indirect input.

See Apple's [indirect input setting](https://developer.apple.com/documentation/bundleresources/information-property-list/uiapplicationsupportsindirectinputevents).

## Compare with a reference document

Keep a comparison model alongside the document model in your app's persistent state:

```swift
let document = SyntaxEditorModel(text: currentText, language: .swift)
let comparison = SyntaxEditorComparisonModel(
    originalText: referenceText,
    modified: document,
    presentation: .inline
)
let controller = SyntaxEditorComparisonViewController(model: comparison)
```

Embed this controller using the same UIKit containment steps as a regular editor controller. You can also use ``SyntaxEditorComparisonView-3ze46`` directly. Its `modifiedEditor` is the existing text input and scroll view, available for native configuration.

Set `comparison.presentation` to `.changeMarkers`, `.inline`, or `.sideBySide`. The modified editor retains its identity, text selection, marked input, and undo history across these changes. The read-only reference follows the document's language, theme, font size, and wrapping settings.

Use `selectNextChange()` and `selectPreviousChange()` to highlight and reveal a change without replacing the modified text selection. `changeCount` is `nil` while the current texts are being compared. The view removes old difference decorations until the new result is available.

Inline deletions use native selectable text views. The parent owns drag scrolling, while native selection autoscroll follows the complete deleted block. Find from a deletion opens the full reference pane. Hiding that pane dismisses its Find interface and returns focus to the modified editor.

The comparison preserves the viewed text position across geometry changes and comparison updates; independent scrolling while a calculation is pending replaces that saved position. Your app supplies the reference text and handles loading and saving. The comparison performs no file or source-control operations.

## Topics

### Native editor

- ``SyntaxEditorView-6lnwr``
- ``SyntaxEditorViewController-j7tv``

### Document comparison

- <doc:ComparingDocuments>
- ``SyntaxEditorComparisonView-3ze46``
- ``SyntaxEditorComparisonViewController-69rtq``
- ``SyntaxEditorComparisonModel``
