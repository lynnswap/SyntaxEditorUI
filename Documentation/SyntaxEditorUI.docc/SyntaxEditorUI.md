# ``SyntaxEditorUI``

Build editable code and plain-text views, including document comparisons, with SwiftUI, UIKit, and AppKit.

## Overview

Import `SyntaxEditorUI` and create a ``SyntaxEditorModel`` for each document. Pass the model to ``SyntaxEditor`` in SwiftUI or choose a native editor for your platform.

Await ``SyntaxEditorModel/prepare()`` during app setup before creating editor views
or comparison models. The package requires Swift 6.3 or later, with iOS 18.4+,
Mac Catalyst 18.4+, visionOS 2.4+, or macOS 15.4+. The app owns loading and saving;
the model owns the current editor state.

## Topics

### Essentials

- <doc:GettingStarted>
- ``SyntaxEditor``

### Editor state

- ``SyntaxEditorModel``
- ``SyntaxEditorModel/prepare()``
- ``SyntaxEditorTextChange``

### Document comparison

- <doc:ComparingDocuments>
- ``SyntaxEditorComparisonModel``
- ``SyntaxEditorComparison``

### UIKit

- <doc:UIKitIntegration>
- ``SyntaxEditorView-6lnwr``
- ``SyntaxEditorViewController-j7tv``
- ``SyntaxEditorComparisonView-3ze46``
- ``SyntaxEditorComparisonViewController-69rtq``

### AppKit

- <doc:AppKitIntegration>
- ``SyntaxEditorView-77bw3``
- ``SyntaxEditorViewController-16tjt``
- ``SyntaxEditorComparisonView-2w0hh``
- ``SyntaxEditorComparisonViewController-5esrd``

### Languages and appearance

- <doc:LanguagesAndThemes>
- ``SyntaxLanguage``
- ``SyntaxEditorTheme``
- ``SyntaxEditorHighlighting``

### Editing commands

- <doc:Editing>
- ``SyntaxEditorMenu``

### Upgrading

- <doc:Migration>
