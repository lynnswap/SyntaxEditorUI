# Comparing documents

Compare reference text with the current document while keeping the current document editable.

## Create a comparison

A ``SyntaxEditorComparisonModel`` combines reference text with a ``SyntaxEditorModel`` for the current document. Pass your existing document model as `modified` to keep its text, selection, and settings.

In SwiftUI, retain the comparison model in persistent state and pass it to ``SyntaxEditorComparison``:

```swift
import SwiftUI
import SyntaxEditorUI

@MainActor
struct ComparisonScreen: View {
    @State private var comparison = SyntaxEditorComparisonModel(
        originalText: "let count = 1\n",
        modified: SyntaxEditorModel(
            text: "let count = 2\n",
            language: .swift
        )
    )

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Previous Change") {
                    comparison.selectPreviousChange()
                }
                Button("Next Change") {
                    comparison.selectNextChange()
                }
            }
            .disabled(comparison.changeCount == nil)

            if let count = comparison.changeCount {
                Text(count == 0 ? "No changes" : "\(count) changes")
            } else {
                ProgressView("Comparing")
            }

            SyntaxEditorComparison(comparison)
        }
    }
}
```

Use the model on the main actor. The comparison updates when either document changes. The native editors use public TextKit 2 APIs; the comparison model calculates differences asynchronously.

## Choose a presentation

Set `comparison.presentation` to choose how the documents appear:

| Presentation | Display |
| --- | --- |
| `.changeMarkers` | The current document with change markers in its margin. |
| `.inline` | The current document with deleted reference text in separate, read-only blocks. This is the default. |
| `.sideBySide` | The current document on the left and the reference on the right, with corresponding vertical scrolling. |

Changing the presentation keeps the same native editor for the current document. Its selection, active text input, and undo history remain intact. Presentation changes do not recalculate the differences.

## Observe results and navigate

`changeCount` is `nil` while the current texts are being compared, including after either text changes. A value of zero means the texts are identical. A positive value counts groups of adjacent added and removed lines. Very large, ambiguous regions may appear as one group.

`selectNextChange()` and `selectPreviousChange()` select and reveal a change without replacing the current document's text selection. With no selected change, navigation starts from the current selection's location. The methods return `false` when no change is available in that direction, including while comparison is pending, and do not wrap at the ends.

`selectedChangeIndex` is the selected group's zero-based index, or `nil` when no group is selected. A text change clears the selected group.

## Edit, select, and save

Edit the current document through `comparison.modified`, just as you would use a standalone editor model. Set `comparison.modified.isEditable = false` to make the current document read-only as well. Programmatic text updates remain available.

The reference is always read-only in the comparison view. Its displayed text supports selection and copying, including text in inline deleted blocks. Reference selection is separate from the current document's selection.

Find in the current editor searches the current document. Invoking Find from inline deleted text switches to `.sideBySide` and directs the operation to the complete reference document. The reference remains read-only, and the current editor retains its state.

Read `comparison.modified.text` when your app saves the current document. Inline deleted blocks and display spacing are not part of that text. Assign `comparison.originalText` to replace the reference without modifying the current document or clearing its undo history. The app supplies both texts and handles loading and persistence.

The reference follows the current model's language, theme, font size, wrapping, and background settings. Configure those through `comparison.modified`; see <doc:LanguagesAndThemes>.

## Keep your reading position

Comparison views keep the viewed text position as text reflows or comparison results arrive. Scrolling while a calculation is pending replaces the saved position. Replacing the reference or rebinding the comparison model does not restore a pending position from the old reference.

## Try the examples

Run **Mini** from the workspace. The **Comparison** preset includes added, removed, and modified code. **Large Comparison** compares a 10,000-line reference with a 1,000-line deletion and changes farther down the document.

Use the presentation control and Previous/Next buttons to inspect the changes. **Use Current as Reference** takes a new reference snapshot; **Restore Sample Reference** brings back the preset's reference. Both operations preserve the current document.

## Use a native comparison view

AppKit and UIKit provide `SyntaxEditorComparisonView(model:)` and `SyntaxEditorComparisonViewController(model:)`. This factory works on either platform:

```swift
import SyntaxEditorUI

@MainActor
func makeComparisonController(
    originalText: String,
    modified: SyntaxEditorModel
) -> SyntaxEditorComparisonViewController {
    let comparison = SyntaxEditorComparisonModel(
        originalText: originalText,
        modified: modified,
        presentation: .sideBySide
    )
    return SyntaxEditorComparisonViewController(model: comparison)
}
```

Host the controller using normal platform containment, or create the comparison view directly. The controller's `editorView` is the comparison container. Its `modifiedEditor` property exposes the current `SyntaxEditorView` for native configuration.

Call `update(model:)` to display another comparison model. Passing the same instance has no effect. Rebinding to a different modified document clears that editor's undo history; switching presentation or replacing only `originalText` does not.

See <doc:AppKitIntegration> and <doc:UIKitIntegration> for platform hosting and menu setup.

## Topics

### Comparison state and presentation

- ``SyntaxEditorComparisonModel``
- ``SyntaxEditorComparison``

### Related guides

- <doc:GettingStarted>
- <doc:AppKitIntegration>
- <doc:UIKitIntegration>
- <doc:Editing>
