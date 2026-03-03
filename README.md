# SyntaxEditorUI

`SyntaxEditorUI` is a lightweight cross-platform code editor package for iOS/macOS.

## Features

- `@Observable` state model (`SyntaxEditorModel`)
- SwiftUI entry point (`SyntaxEditorView`)
- UIKit/AppKit controller API (`SyntaxEditorViewController`)
- tree-sitter based syntax highlighting for:
  - CSS
  - JavaScript
  - JSON
- Core editing capabilities:
  - Auto-pair insertion: `() [] {} "" '' ```
  - Smart newline indentation (4 spaces)
  - Line indent / outdent (`Tab`, `Shift-Tab`, `Cmd+]`, `Cmd+[`)
  - Comment toggle (`Cmd+/`) for JavaScript and CSS
  - JSON comment toggle is intentionally no-op
  - Pair-aware backspace deletion
  - Matching bracket highlight
- iOS input accessory actions: `Undo`, `Redo`, `Dismiss Keyboard`

## Shortcuts

- `Tab`: Indent
- `Shift-Tab`: Outdent
- `Cmd+]`: Indent
- `Cmd+[` : Outdent
- `Cmd+/`: Toggle comment (JavaScript/CSS)
- `Cmd+Z`: Undo
- `Shift+Cmd+Z`: Redo

## Testing

```bash
xcodebuild -scheme SyntaxEditorUI -destination 'platform=macOS' test
xcodebuild -scheme SyntaxEditorUI -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test
```
