# SyntaxEditorUI

Editable code and plain-text views for SwiftUI, UIKit, and AppKit, backed by one observable editor model.

Includes syntax highlighting, find, undo, keyboard shortcuts, common code-editing commands, and document comparison with margin markers, inline deletions, or side-by-side panes. Supported languages include ARM Assembly, CSS, HTML, JavaScript, JSON, Objective-C, Swift, TOML, and XML.

## Requirements

- Swift 6.3+
- iOS 18+, Mac Catalyst 18+, or visionOS 2+
- macOS 15+

## Installation

Add [SyntaxEditorUI](https://github.com/lynnswap/SyntaxEditorUI) as a Swift package dependency in Xcode, then add the **SyntaxEditorUI** product to your application target.

## Quick start

```swift
import SwiftUI
import SyntaxEditorUI

struct EditorView: View {
    @State private var model = SyntaxEditorModel(
        text: "const answer = 42;",
        language: .javascript
    )

    var body: some View {
        SyntaxEditor(model)
            .onChange(of: model.text) {
                print("Edited text:", model.text)
            }
    }
}
```

Keep one model per document. The editor reads and updates that model; your app handles loading and saving text.

For native UI, pass the same model to `SyntaxEditorView(model:)` or `SyntaxEditorViewController(model:)`. Use `.plainText` for editing without syntax highlighting or code-aware transforms.

To compare a reference with an existing document, create `SyntaxEditorComparisonModel(originalText: referenceText, modified: model)` and display `SyntaxEditorComparison(comparison)` in SwiftUI. Native platforms also provide comparison views and controllers. See [Comparing documents](Documentation/SyntaxEditorUI.docc/ComparingDocuments.md) for presentation, navigation, and saving.

## Documentation

See the [DocC documentation](https://lynnswap.github.io/SyntaxEditorUI/) for platform integration, language and theme configuration, editing commands, and API references.

For upgrades from an earlier release, see [Migration notes](Documentation/SyntaxEditorUI.docc/Migration.md).

## Example and development

Open `SyntaxEditorUI.xcworkspace` and run **Mini** on an iOS Simulator or My Mac to try the supported languages and themes. Choose **Comparison** or **Large Comparison** to switch comparison presentations, navigate changes, and update the reference snapshot.

See [Contributing](CONTRIBUTING.md) for tests, benchmarks, and local documentation builds.

## License

[MIT](LICENSE).
