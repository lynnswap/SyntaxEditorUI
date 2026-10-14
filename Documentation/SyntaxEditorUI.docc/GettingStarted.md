# Getting started

Create an editor backed by one observable model.

## Add the package

Add [SyntaxEditorUI](https://github.com/lynnswap/SyntaxEditorUI) as a Swift package dependency in Xcode, select its **SyntaxEditorUI** product for your app target, and import `SyntaxEditorUI`.

## Create a SwiftUI editor

Keep the model in `@State` so the editor retains the same document state when SwiftUI reevaluates the view.

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

For native integration, see <doc:UIKitIntegration> or <doc:AppKitIntegration>. Both platforms accept the same ``SyntaxEditorModel``.

## Optional observation preparation

Editors and comparisons prepare observation when they first need it. You can
warm up the shared runtime during asynchronous app setup:

```swift
try await SyntaxEditorModel.prepare()
```

Repeated calls reuse prepared runtime handles. Editors and comparisons can also
be created while preparation runs. Their synchronous initializers perform any
remaining runtime lookup, or wait for the required work already in progress.
Preparing earlier moves that work off the main actor. An explicit preparation
call reports errors and cancellation to its caller.

## Own the document state

The model holds text, a UTF-16 selection range, language, editability, wrapping, and appearance. Read and update it on the main actor. Views observe it and send edits back to it.

Your app owns file access, persistence, and document identity. Read `model.text` when saving, and use `model.replaceContents(text:language:selectedRange:)` when loading text together with its language. SyntaxEditorUI does not read or write files.

`model.textRevision` advances when text changes. Changing only the selection or language does not advance it. `model.latestTextChange` describes the most recent text change; it is not a queue of every edit. See ``SyntaxEditorModel`` and ``SyntaxEditorTextChange`` for the mutation contract.

## Switch documents

Create a separate model when documents need independent state. Passing a different model to ``SyntaxEditor``, or calling `update(model:)` on a native editor, rebinds that editor and clears its undo history.

There is no explicit close operation. Remove the editor from its container and release the model when your app no longer needs the document.
