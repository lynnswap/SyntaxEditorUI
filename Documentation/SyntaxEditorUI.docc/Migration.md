# Migration

Update an app that uses an earlier SyntaxEditorUI release.

Choose the section for the version you are upgrading to. Older sections describe the API at that release; the current API reference is the source of truth for new integrations.

## Unreleased

ObservationBridge is now pinned to 0.14.1. The minimum OS versions are iOS and
Mac Catalyst 18.4, macOS 15.4, and visionOS 2.4.

Prepare observation once during asynchronous app setup, and await completion
before constructing editor views or comparison models:

```swift
try await SyntaxEditorModel.prepare()
```

Preparation errors propagate to the caller. Handle them in your app's startup
flow. Repeated calls share preparation across the process. Existing editor and
comparison initializers remain synchronous after preparation. Creating plain
document models and preparing syntax highlighting do not require this call.

## v0.15.0

These notes apply when upgrading from `v0.14.x` or earlier to `v0.15.0`.

- `SyntaxEditorTextEdit` has been replaced by `SyntaxEditorTextChange.Replacement`.
- `SyntaxEditorTextChange.edits` has been renamed to `replacements`.
- `SyntaxEditorTextChange.revision` has been renamed to `textRevision`.
- `SyntaxEditorModel.latestChange` has been renamed to `latestTextChange`.
- `SyntaxEditorTextChange.Kind.replacement` has been renamed to `wholeDocumentReplacement`.
- Platform color and font aliases now live under `SyntaxEditorTheme` as `SyntaxEditorTheme.Color` and `SyntaxEditorTheme.Font`.
- `SyntaxEditorMenu.makeEditorMenu()` and `SyntaxEditorMenu.makeEditorMenuItem()` have been replaced by `SyntaxEditorMenu.makeMenu()`.
- `SyntaxEditorMenu.insertEditorMenu(into:)` and `SyntaxEditorMenu.insertEditorMenuItem(into:)` have been replaced by `SyntaxEditorMenu.insert(into:)`.
- `SyntaxLanguage.named(_:)` has been replaced by `SyntaxLanguage.init?(identifier:)`.
- `SyntaxLanguage.all` has been removed. Use `SyntaxLanguage.allCases`.

## v0.12.0

These notes apply when upgrading from `v0.11.x` or earlier to `v0.12.0`.

- `SyntaxEditorColorTheme` has been renamed to `SyntaxEditorTheme`.
- `SyntaxEditorModel.colorTheme` and the `colorTheme:` initializer argument have been renamed to `theme` and `theme:`.
- Custom `SyntaxEditorTheme` values must include a `font`. Themes now own editor font size; the editor no longer falls back to a package-level default point size.

## v0.11.0

These notes apply when upgrading from `v0.10.x` or earlier to `v0.11.0`.

- `SyntaxEditorDocument` and `SyntaxEditorConfiguration` have been removed. Create and own a single `SyntaxEditorModel` for text, selection, language, editability, wrapping, theme, background drawing, and font-size state.
- `SyntaxLanguage.plainText` has been added. Update exhaustive switches over `SyntaxLanguage` to handle plain text, and use `.plainText` for editors that should not run syntax highlighting or code-aware editing transforms.
- `textSnapshot()` has been removed. Read, write, and observe `model.text` directly. Use `model.replaceText(_:selectedRange:)` when replacement and selection should be updated together.
- Replace `SyntaxEditor(document:configuration:)` with `SyntaxEditor(model)`.
- Replace `SyntaxEditorView(document:configuration:)` and `SyntaxEditorViewController(document:configuration:)` with `SyntaxEditorView(model:)` and `SyntaxEditorViewController(model:)`.
- `SyntaxEditorDocumentChange` has been renamed to `SyntaxEditorTextChange`. Use `change.kind == .incremental` or `change.kind == .wholeDocumentReplacement` instead of `isWholeDocumentReplacement`.
- UIKit and AppKit `text`, `selectedRange`, and `isEditable` properties remain available and now proxy to the view's `model`.
- On macOS, `SyntaxEditorView` no longer exposes the underlying editor as `NSTextView`. The editor surface is implemented directly with TextKit 2, matching the iOS architecture. Use `SyntaxEditorView.text`, `SyntaxEditorView.selectedRange`, `SyntaxEditorView.isEditable`, and `SyntaxEditorView.model` instead of reaching through `textView`.
- This is a breaking macOS API change: there is no replacement public `NSTextView` accessor. Code that previously customized `editorView.textView` should move editor state to `SyntaxEditorModel` or drive the editor through the public `SyntaxEditorView` properties above.
- `SyntaxEditorViewController.textView` is no longer public on macOS. Access the editor through `SyntaxEditorViewController.editorView` and `model`.

## v0.10.0

These notes apply when upgrading from `v0.9.x` or earlier to `v0.10.0`.

- `SyntaxEditorView.font` has been removed from the public iOS API. Use `SyntaxEditorModel.fontSizeDelta` or the font-size command methods to adjust editor text size.

## v0.8.0

These notes apply when upgrading from `v0.7.x` or earlier to `v0.8.0`.

- `SyntaxEditorColorTheme.xcode` has been removed. Use `SyntaxEditorColorTheme.default`, shorthand `.default`, or `SyntaxEditorColorTheme.preset(_:)` instead.
- `SyntaxEditorColorTheme.id` is now a `String` instead of a `UUID`. If your app stores or compares theme IDs, migrate those values to strings.

## v0.7.0

These notes apply when upgrading from `v0.6.x` or earlier to `v0.7.0`.

- `SyntaxEditorModel` has been replaced by separate `SyntaxEditorDocument` and `SyntaxEditorConfiguration` objects.
- Store editor text in `SyntaxEditorDocument`. Read the current text with `textSnapshot()` and replace it with `replaceText(_:selectedRange:)`.
- Store editor settings in `SyntaxEditorConfiguration`: `language`, `isEditable`, `lineWrappingEnabled`, and `colorTheme`.
- Replace `SyntaxEditor(model:)` with `SyntaxEditor(document:configuration:)`. `SyntaxEditor()` is also available when the default document and configuration are enough.
- Replace `SyntaxEditorView(model:)` and `SyntaxEditorViewController(model:)` with `SyntaxEditorView(document:configuration:)` and `SyntaxEditorViewController(document:configuration:)`.
- If your app observed `SyntaxEditorModel`, observe `SyntaxEditorDocument` for text changes and `SyntaxEditorConfiguration` for configuration changes. `SyntaxEditorDocument` exposes `textRevision` and `latestTextChange` for tracking committed text changes.
- `SyntaxEditorModel` and the model-based initializers have been removed without a compatibility shim.

## v0.5.0

These notes apply when upgrading from `v0.4.x` or earlier to `v0.5.0`.

- Starting with `v0.5.0`, non-UI implementation has moved into the internal `SyntaxEditorCore` target. `SyntaxEditorCore` is not a public package product; clients should keep importing `SyntaxEditorUI` only.
- In `v0.5.0`, `SyntaxEditorModel`, `SyntaxLanguage`, and related non-UI APIs remained available from `SyntaxEditorUI` via module re-export. `SyntaxEditorModel` was removed in `v0.7.0`; see the `v0.7.0` notes above.
- `SyntaxLanguage` is now a concrete enum of supported languages. Use `SyntaxLanguage.javascript` or shorthand `.javascript` instead of `BuiltinSyntaxLanguages.javascript`.
- `BuiltinSyntaxLanguages` has been removed without a compatibility shim.
- Custom `SyntaxLanguage` conformers are no longer supported. `SyntaxLanguage.TreeSitterSupport`, custom query directories, and custom highlight cache keys are no longer public API.
- HTML embedded JavaScript/CSS highlighting remains supported through `SyntaxLanguage.html`.
- Up to `v0.4.x` on iOS, `SyntaxEditorView` embedded a `UITextView` that was exposed through `SyntaxEditorView.textView` and `SyntaxEditorViewController.textView`.
- Starting with `v0.5.0` on iOS, `SyntaxEditorView` is the single native text input and scroll view. Use `SyntaxEditorView` / `SyntaxEditorViewController.editorView` directly for text, selection, editability, wrapping, and scrolling.
