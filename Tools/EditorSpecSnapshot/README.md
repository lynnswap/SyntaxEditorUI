# EditorSpecSnapshot

Local tools for deriving reference syntax-coloring expectations from the
developer toolchain installed on this Mac.

The tools use the Xcode that `DEVELOPER_DIR` names, or else the one
`xcode-select` points at. If the standalone Command Line Tools are selected,
they use `/Applications/Xcode.app`. `EditorSpecTool` links against that Xcode's
private frameworks when it is built. Pass `--xcode <Xcode.app>` to read
specifications and themes from another installation.

These tools are intentionally outside the package products. They are for
fixture generation and investigation only; the package runtime must not depend
on private frameworks or local developer-tool installation details.

## Extract supported language specifications

```bash
python3 Tools/EditorSpecSnapshot/xclangspec_snapshot.py --pretty \
  > /tmp/editor-spec-snapshot.json
```

The snapshot includes every `.xclangspec` and `.xcsynspec` entry under
`SourceModel.framework`, every source language metadata plist needed by the
currently supported SyntaxEditorUI languages, and a derived rule closure for
each supported source language. The derived closure follows
`BasedOn`, `Tokenizer`, `IncludeRules`, `Rules`, `Start`, `End`, `AltEnd`,
`AltToken`, and `EntityNameMap` references when they point at known rule
identifiers.

To inspect a single language while still resolving from the full rule index:

```bash
python3 Tools/EditorSpecSnapshot/xclangspec_snapshot.py \
  --language Xcode.SourceCodeLanguage.HTML --pretty
```

Use `--all-languages` only when investigating unsupported languages.

## Generate query word lists

```bash
python3 Tools/EditorSpecSnapshot/generate_highlight_definitions.py
```

This reads the local `.xclangspec` / `.xcsynspec` files and refreshes generated
word-list blocks in the bundled `highlights.scm` resources. Package runtime code
does not carry generated Xcode vocabulary; grammar and query captures own token
classification, while theme code only resolves known editor syntax families.

## Compare Swift and CSS highlighting with Xcode

`EditorSpecTool` is a SwiftPM executable that uses `SyntaxEditorCore` for editor
tokens and Xcode-installed tooling for reference tokens. It is the mechanical
verification path for syntax-color alignment; do not use screenshots or manual
eyeballing as the oracle.

Use `classification-diff` as the primary Swift signal when changing
`highlights.scm` or the Swift grammar fork. It compares
`SyntaxHighlighterEngine` tokens against Xcode's own `SourceEditor.framework`
syntax token provider, backed by `SymbolCacheSupport.framework`, and normalizes
`SourceEditorTokenType.UIKind` values into editor syntax buckets:

```bash
swift run EditorSpecTool classification-diff \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty
```

The classification output compares normalized token classifications, not colors. Each
difference includes the Xcode-side raw `tokenType` / `uiKind` and the
SyntaxEditorUI-side raw capture name. This is the closest direct mechanical
oracle found so far; it avoids screenshot color sampling and avoids
SourceKit-LSP semantic-token overreach.

For separate classification snapshots:

```bash
swift run EditorSpecTool editor-tokens \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty

swift run EditorSpecTool xcode-classification-tokens \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty
```

Rendered-color comparison is still available, but it is secondary and intended
for theme/color regressions. For Swift it maps the same SourceEditor
classification tokens through `SourceEditor.framework/.../Default
(Dark).xccolortheme` or `Default (Light).xccolortheme`:

```bash
swift run EditorSpecTool rendered-diff \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty
```

The SourceEditor token route is used by `xcode-classification-tokens`,
`classification-diff`, `xcode-rendered-tokens`, and `rendered-diff` for Swift
files. It intentionally stays in this local tool and does not expose private
framework details through package runtime APIs. The tool-only Swift interfaces
under `PrivateInterfaces/` were derived from the installed Xcode frameworks
with `MachOSwiftSection`; regenerate them if the local Xcode build changes the
private ABI enough to break compilation.

CSS uses the same `SourceEditorDataSource` probe shape, backed by
`SourceModelSupport.SourceModelLanguageService` instead of SymbolCache. Use it
when checking CSS visual alignment because the older standalone DVT
text-storage path can miss the later SourceEditor classification that Xcode's
editor applies:

```bash
swift run EditorSpecTool classification-diff \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.css \
  --language css --pretty

swift run EditorSpecTool rendered-diff \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.css \
  --language css --pretty
```

`xcode-dvt-rendered-tokens` forces the older DVT text-storage color route even
for Swift. Use it when investigating whether a live Xcode editor screenshot is
showing a rendered-color state that the SourceEditor/SymbolCache token route is
not exposing. On the current Xcode 26.5 install this command runs for Swift,
but DVT logs that it cannot load the Swift language spec and returns broad
plain ranges, so it is an investigation probe rather than a trusted oracle:

```bash
swift run EditorSpecTool xcode-dvt-rendered-tokens \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty
```

`xcode-dvt-language-diagnostics` inspects how DVT resolves Swift source
languages and language specifications in this standalone tool process. Use it
before changing the DVT rendered probe: it currently shows that Swift language
resolution succeeds, but SourceModel's language specifications have to be
registered explicitly before `DVTSourceCodeLanguage.languageSpecification`
stops returning a missing proxy.

```bash
swift run EditorSpecTool xcode-dvt-language-diagnostics \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty
```

`xcode-source-editor-view-diagnostics` checks the runtime surface of
`SourceEditor.SourceEditorView`. It does not call `syntaxType` yet; it verifies
that the class can be instantiated, which Objective-C selectors are exposed,
and whether the Swift-only direct symbols needed for a lower-level probe are
available through `dlsym`.

```bash
swift run EditorSpecTool xcode-source-editor-view-diagnostics \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty
```

## Compare Objective-C highlighting with Xcode

Objective-C does not currently have the same `SourceEditor.framework` /
`SymbolCache` token path used by Swift in this tool. The older DVT text-storage
rendered probe is the closest local signal for what Xcode paints, but it is not
a complete semantic oracle:

```bash
swift run EditorSpecTool xcode-dvt-rendered-tokens \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.m \
  --language objective-c --pretty

swift run EditorSpecTool rendered-diff \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.m \
  --language objective-c --pretty
```

Use `source-model-tokens`, `diff`, `ObjectiveC.xclangspec`, and
`Built-in Syntax Types.xcsynspec` for Objective-C rule and taxonomy
investigation, not as final rendered-color oracles. SourceModel structural items
can expose `xcode.syntax.name.*` nodes such as function names and local
parameter names, while the DVT text-storage rendered output for the same ranges
may still paint plain `identifier` colors. Treat that difference as a real
boundary between rule-model structure and editor rendering, especially before
adding semantic overlays for system types, system functions, constants,
declarations, local variables, or header-defined macros/constants that are not
distinguishable from source-local text.

When aligning Objective-C runtime behavior, prefer a source-local pass: query
captures should own syntax categories that the parse tree can express, and any
Swift-side overlay should be reserved for ranges that cannot be represented by
Tree-sitter queries. Do not infer symbols from companion headers unless that
scope is explicitly reopened.

Objective-C `@property` declaration names are query-owned declaration tokens:
`ObjectiveC.xclangspec` exposes `property.name.actual` as
`xcode.syntax.name.other`, so keep them distinct from local declarations and
method parameters even when other declarators remain plain identifiers.

One deliberate source-local overlay remains for explicit `self.` member chains:
the first known source-local property after `self.` is treated as a project
property/global token, while following members in that same chain are treated as
other property/global tokens. Do not extend that behavior to arbitrary dotted
expressions or local declarations without a fresh Xcode-rendering check.

`source-model-tokens` is useful for inspecting SourceModel rule closures and
non-rendered syntax items:

```bash
swift run EditorSpecTool source-model-tokens \
  --file Tools/Mini/Mini/ReferenceSamples/Reference.swift \
  --language swift --pretty

```

The SourceModel snapshot output is a JSON list of flattened source model items
with source ranges, matched rule identifiers, token names, and
`xcode.syntax.*` node type names. It uses private framework APIs through the
tool-only `SourceModelBridge` target. Keep it as an xclangspec/rule inspection
aid and for non-rendered structural investigations; Swift alignment should use
`classification-diff` because SourceEditor exposes the same token taxonomy used
by Xcode's editor.

Focused Swift fixtures live in `Tools/EditorSpecSnapshot/Fixtures/` for
attribute, preprocessor/macro, and file-local semantic alignment checks. The
current SourceEditor probe reports project-scoped Swift variables for selected
file/member references and external scopes for known type names, but leaves
same-file type/function/macro references plain; keep runtime overlays equally
conservative unless the probe starts reporting those `uiKind` scopes.

Some Swift differences are grammar-boundary differences, not query differences.
The package points at a pinned remote `lynnswap/tree-sitter-swift` fork so
grammar-level fixes are fetchable in fresh checkouts. For example, the fork parses
`#sourceLocation(file:..., line:...)` as `diagnostic` plus nested
`value_arguments`, allowing the query to color the directive keyword, labels,
string, and number separately. Query captures cannot currently address every
punctuation range in the diagnostic node, so the Swift overlay adds
SourceEditor-compatible preprocessor punctuation for directive/source-location
lines. Keep token-boundary fixes in the Swift grammar fork where practical and
use `EditorSpecTool classification-diff` to decide which remaining differences
are worth moving into grammar.

## Swift rule model target

`XclangSpecSyntax` is a package-internal Swift target for modeling
`.xclangspec` / `.xcsynspec` rule files. It parses plist documents, preserves
unknown rule fields, and builds rule-reference closures from `BasedOn`,
`Tokenizer`, `IncludeRules`, `Rules`, `Start`, `End`, `Until`, `AltUntil`,
`AltEnd`, `AltToken`, `EntityNameMap`, and `LanguageEmbeddings`. It also exposes
the installed `Syntax` metadata keys used by Xcode 26.5 specs, including
word scanners, regex matches, capture types, source scanner names, traversal
flags, and indentation/folding flags. Keep private-framework probes in this
tool directory; package runtime code should depend on generated data or the
`XclangSpecSyntax` model, not on Xcode frameworks.
