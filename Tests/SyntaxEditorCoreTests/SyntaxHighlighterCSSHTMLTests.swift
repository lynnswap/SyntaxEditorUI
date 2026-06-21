import Foundation
import Testing
@testable import SyntaxEditorCore

extension SyntaxHighlighterEngineTests {
    @Test("SyntaxHighlighterEngine produces highlight tokens for CSS")
    func highlighterProducesTokensForCSS() async {
        await expectHighlightTokens(source: "body { color: red; }", language: .css)
    }

    @Test("SyntaxHighlighterEngine emits semantic CSS captures for the reference sample")
    func highlighterEmitsSemanticCSSCapturesForReferenceSample() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = try referenceSampleText(named: "Reference.css")
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)
        let theme = SyntaxEditorTheme.default.resolved(for: .css, appearance: .dark)

        let selectorDeclarationCases: [(text: String, containingText: String)] = [
            ("body", "body {"),
            ("hero", "#hero"),
            ("nav", #"nav a[aria-current="page"]"#),
            ("a", #"nav a[aria-current="page"]"#),
            ("main", "main > section"),
            ("section", "main > section"),
            ("is", "section:is"),
            ("@supports", "@supports (backdrop-filter"),
            ("@keyframes", "@keyframes reveal"),
            ("reveal", "@keyframes reveal"),
        ]
        for testCase in selectorDeclarationCases {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: testCase.text,
                syntaxID: .declarationOther,
                language: .css,
                inOccurrenceOf: testCase.containingText
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.declaration.other")
        }

        let plainSelectorCases: [(text: String, containingText: String)] = [
            ("root", ":root"),
            ("hero", "section:is(.hero"),
            ("summary", ".summary"),
            ("nav", "@supports (backdrop-filter: blur(12px)) {\n    nav"),
            ("grid", ".grid {"),
        ]
        for testCase in plainSelectorCases {
            let ids = syntaxIDs(
                in: tokens,
                source: source,
                text: testCase.text,
                inOccurrenceOf: testCase.containingText
            )
            #expect(ids.contains(.declarationOther) == false)
            #expect(ids.contains(.keyword) == false)
        }

        let plainValueCases: [(text: String, containingText: String)] = [
            ("color-scheme", "color-scheme: light dark"),
            ("--brand-accent", "--brand-accent: #007aff"),
            ("linear-gradient", "linear-gradient(135deg"),
            ("var", "var(--brand-accent)"),
            ("container-type", "container-type: inline-size"),
            ("backdrop-filter", "@supports (backdrop-filter: blur(12px))"),
            ("backdrop-filter", "backdrop-filter: blur(12px);"),
            ("blur", "blur(12px)"),
            ("grid-template-columns", "grid-template-columns: repeat"),
            ("gap", "gap: 14px"),
            ("transform", "transform: translateY(8px)"),
            ("minmax", "minmax(180px"),
            ("vh", "100vh"),
            ("fr", "1fr"),
            ("aria-current", #"nav a[aria-current="page"]"#),
        ]
        for testCase in plainValueCases {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: testCase.text,
                syntaxID: .plain,
                language: .css,
                inOccurrenceOf: testCase.containingText
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.plain")
            #expect(snapshot.resolvedStyle.foreground == theme.base.foreground)
        }

        let keywordCases: [(text: String, containingText: String)] = [
            ("margin", "margin: 0"),
            ("min-height", "min-height: 100vh"),
            ("color", "color: #1d1d1f"),
            ("background", "background: linear-gradient"),
            ("max-width", "max-width: 760px"),
            ("padding", "padding: 24px"),
            ("border-color", "border-color: rgba"),
            ("content", "content: \"Open\""),
            ("opacity", "opacity: 0.86"),
            ("display", "display: grid"),
            ("grid", "display: grid"),
            ("rgba", "rgba(0, 122"),
            ("repeat", "repeat(auto-fit"),
            ("auto", "margin: 0 auto"),
            ("px", "760px"),
            ("deg", "135deg"),
            ("@media", "@media (min-width"),
            ("min-width", "@media (min-width: 720px)"),
            ("button", "button:hover"),
            ("hover", "button:hover"),
            ("after", "::after"),
            ("from", "from {"),
            ("to", "to {"),
        ]
        for testCase in keywordCases {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: testCase.text,
                syntaxID: .keyword,
                language: .css,
                inOccurrenceOf: testCase.containingText
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.keyword")
            #expect(snapshot.resolvedStyle.foreground == theme.keyword.foreground)
        }

        let attributeValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "\"page\"",
            syntaxID: .string,
            language: .css,
            inOccurrenceOf: #"nav a[aria-current="page"]"#
        )
        let childCombinator = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: ">",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: "main > section"
        )
        let hexColor = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "#007aff",
            syntaxID: .number,
            language: .css,
            inOccurrenceOf: "#007aff"
        )
        let percentage = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "0%",
            syntaxID: .number,
            language: .css,
            inOccurrenceOf: "#eef4ff 0%"
        )

        #expect(attributeValue.text == "\"page\"")
        #expect(attributeValue.styleKeys.first == "editor.syntax.string")
        #expect(childCombinator.styleKeys.first == "editor.syntax.plain")
        #expect(hexColor.styleKeys.first == "editor.syntax.number")
        #expect(percentage.styleKeys.first == "editor.syntax.number")
        #expect(syntaxIDs(in: tokens, source: source, text: "#", inOccurrenceOf: "#007aff").contains(.plain) == false)
        #expect(syntaxIDs(in: tokens, source: source, text: "%", inOccurrenceOf: "#eef4ff 0%").contains(.keyword) == false)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine keeps CSS attribute values string-styled while classifying units")
    func highlighterPreservesCSSAttributeValueStringsAndUnitKeywords() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"[data-state=open] { color: red; width: 1fr; padding: 1px; }"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        let attributeValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "open",
            syntaxID: .string,
            language: .css,
            inOccurrenceOf: "[data-state=open]"
        )
        let fractionalUnit = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "fr",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: "1fr"
        )
        let pixelUnit = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "px",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "1px"
        )

        #expect(attributeValue.styleKeys.first == "editor.syntax.string")
        #expect(fractionalUnit.styleKeys.first == "editor.syntax.plain")
        #expect(pixelUnit.styleKeys.first == "editor.syntax.keyword")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine keeps modern CSS at-rules highlighted")
    func highlighterKeepsModernCSSAtRulesHighlighted() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        @layer components { .layered { color: red; } }
        @scope (.root) { .scoped { color: red; } }
        @property --x { syntax: "<color>"; }
        @starting-style { .starting { opacity: 0; } }
        @unknown value;
        @font-face { font-family: system-ui; }
        @page { margin: 0; }
        @-webkit-keyframes fade { from { opacity: 0; } }
        @media (min-width: 1px) { body { color: red; } }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        for atRule in ["@layer", "@scope", "@property", "@starting-style", "@unknown"] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: atRule,
                syntaxID: .declarationOther,
                language: .css,
                inOccurrenceOf: atRule
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.declaration.other")
        }

        for testCase in [
            (text: "components", containingText: "@layer components"),
            (text: "--x", containingText: "@property --x"),
        ] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: testCase.text,
                syntaxID: .declarationOther,
                language: .css,
                inOccurrenceOf: testCase.containingText
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.declaration.other")
        }

        for atRule in ["@font-face", "@page", "@-webkit-keyframes", "@media"] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: atRule,
                syntaxID: .keyword,
                language: .css,
                inOccurrenceOf: atRule
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.keyword")
        }

        for testCase in [
            (text: "layered", containingText: ".layered {"),
            (text: "root", containingText: "@scope (.root)"),
            (text: "scoped", containingText: ".scoped {"),
            (text: "starting", containingText: ".starting {"),
        ] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: testCase.text,
                syntaxID: .plain,
                language: .css,
                inOccurrenceOf: testCase.containingText
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.plain")
        }
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine keeps keyword-valued CSS keyframe names as keywords")
    func highlighterKeepsKeywordValuedCSSKeyframeNamesAsKeywords() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        @keyframes color {
            from { opacity: 0; }
        }
        @keyframes move {
            to { opacity: 1; }
        }
        @keyframes reveal {
            from { opacity: 0; }
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        for name in ["color", "move"] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: name,
                syntaxID: .keyword,
                language: .css,
                inOccurrenceOf: "@keyframes \(name)"
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.keyword")
        }

        let revealName = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "reveal",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@keyframes reveal"
        )
        #expect(revealName.styleKeys.first == "editor.syntax.declaration.other")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine preserves CSS keyframe keywords inside conditional at-rules")
    func highlighterPreservesCSSKeyframeKeywordsInsideConditionalAtRules() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        @media (min-width: 720px) {
            button:hover::after { content: "Open"; }
            @keyframes spin {
                from { opacity: 0; }
                to { opacity: 1; }
            }
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        let fromKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "from",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "from {"
        )
        let toKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "to",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "to {"
        )
        let nestedKeyframesNameIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "spin",
            inOccurrenceOf: "@keyframes spin"
        )
        let buttonKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "button",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "button:hover"
        )
        let hoverKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "hover",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "button:hover"
        )
        let afterKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "after",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "::after"
        )

        #expect(fromKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(toKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(nestedKeyframesNameIDs.contains(.declarationOther) == false)
        #expect(nestedKeyframesNameIDs.contains(.keyword) == false)
        #expect(buttonKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(hoverKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(afterKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine classifies CSS container query nested selectors like Xcode")
    func highlighterClassifiesCSSContainerQueryNestedSelectorsLikeXcode() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        @container (width > 10px) {
            .grid { display: grid; }
        }
        @container sidebar2 style(color: red) {
            .card { --color: red; color: var(--color); }
        }
        @container card (width > 30em) AND style(color: red) {
            .tile { color: red; }
        }
        @container side_bar (width > 10px) {
            .panel { display: grid; }
        }
        @container signed (width > +10px) and style(margin-left: -10px) {
            .signed { display: grid; }
        }
        @container not (width > 10px) {
            .negated { display: grid; }
        }
        @CONTAINER --sidebar (width > 10px) {
            .dash { display: grid; }
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        let containerAtRule = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@container",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@container"
        )
        let queryNumber = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "10",
            syntaxID: .number,
            language: .css,
            inOccurrenceOf: "10px"
        )
        let queryUnit = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "px",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "10px"
        )
        let containerName = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "sidebar2",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "sidebar2 style"
        )
        let containerStyleQuery = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "style",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "style(color"
        )
        let gridSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "grid",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".grid {"
        )
        let customProperty = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "--color",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: "--color: red"
        )
        let containerNameDigitIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "2",
            inOccurrenceOf: "sidebar2 style"
        )
        let customPropertyKeywordIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "color",
            inOccurrenceOf: "--color: red"
        )
        let combinedContainerStyleQueryIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "style",
            inOccurrenceOf: "AND style(color"
        )
        let combinedContainerOperatorIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "AND",
            inOccurrenceOf: ") AND style"
        )
        let combinedContainerSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "tile",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".tile {"
        )
        let underscoredContainerName = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "side_bar",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "side_bar (width"
        )
        let underscoredContainerSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "panel",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".panel {"
        )
        let signedPositiveNumber = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "+10",
            syntaxID: .number,
            language: .css,
            inOccurrenceOf: "+10px"
        )
        let signedNegativeNumber = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "-10",
            syntaxID: .number,
            language: .css,
            inOccurrenceOf: "-10px"
        )
        let signedContainerSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "signed",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".signed {"
        )
        let negatedContainerNot = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "not",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "@container not"
        )
        let negatedContainerSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "negated",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".negated {"
        )
        let uppercaseContainerAtRule = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@CONTAINER",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@CONTAINER"
        )
        let hyphenatedContainerName = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "--sidebar",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "--sidebar (width"
        )
        let uppercaseContainerSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "dash",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".dash {"
        )

        #expect(containerAtRule.styleKeys.first == "editor.syntax.declaration.other")
        #expect(queryNumber.styleKeys.first == "editor.syntax.number")
        #expect(queryUnit.styleKeys.first == "editor.syntax.keyword")
        #expect(containerName.styleKeys.first == "editor.syntax.declaration.other")
        #expect(containerStyleQuery.styleKeys.first == "editor.syntax.declaration.other")
        #expect(gridSelector.styleKeys.first == "editor.syntax.plain")
        #expect(customProperty.styleKeys.first == "editor.syntax.plain")
        #expect(combinedContainerStyleQueryIDs.contains(.declarationOther) == false)
        #expect(combinedContainerStyleQueryIDs.contains(.keyword) == false)
        #expect(combinedContainerOperatorIDs.contains(.declarationOther) == false)
        #expect(combinedContainerSelector.styleKeys.first == "editor.syntax.plain")
        #expect(underscoredContainerName.styleKeys.first == "editor.syntax.declaration.other")
        #expect(underscoredContainerSelector.styleKeys.first == "editor.syntax.plain")
        #expect(signedPositiveNumber.styleKeys.first == "editor.syntax.number")
        #expect(signedNegativeNumber.styleKeys.first == "editor.syntax.number")
        #expect(signedContainerSelector.styleKeys.first == "editor.syntax.plain")
        #expect(negatedContainerNot.styleKeys.first == "editor.syntax.keyword")
        #expect(negatedContainerSelector.styleKeys.first == "editor.syntax.plain")
        #expect(uppercaseContainerAtRule.styleKeys.first == "editor.syntax.declaration.other")
        #expect(hyphenatedContainerName.styleKeys.first == "editor.syntax.declaration.other")
        #expect(uppercaseContainerSelector.styleKeys.first == "editor.syntax.plain")
        #expect(containerNameDigitIDs.contains(.number) == false)
        #expect(customPropertyKeywordIDs.contains(.keyword) == false)
        let selectorIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "grid",
            inOccurrenceOf: ".grid {"
        )
        #expect(selectorIDs.contains(.declarationOther) == false)
        #expect(selectorIDs.contains(.keyword) == false)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine treats CSS comments after conditional at-rules as whitespace")
    func highlighterTreatsCSSCommentsAfterConditionalAtRulesAsWhitespace() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        @media/*x*/ (min-width: 1px) {
            .grid { display: grid; }
        }
        @supports/*x*/ selector(:has(img)) {
            .card { display: grid; }
        }
        @container/*x*/ sidebar style(color: red) {
            .panel { display: grid; }
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        let mediaGridSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "grid",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".grid {"
        )
        let supportsSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "selector",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@supports/*x*/ selector"
        )
        let containerAtRule = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@container",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@container/*x*/"
        )
        let containerName = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "sidebar",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "sidebar style"
        )
        let containerPanelSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "panel",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".panel {"
        )

        #expect(mediaGridSelector.styleKeys.first == "editor.syntax.plain")
        #expect(supportsSelector.styleKeys.first == "editor.syntax.declaration.other")
        #expect(containerAtRule.styleKeys.first == "editor.syntax.declaration.other")
        #expect(containerName.styleKeys.first == "editor.syntax.declaration.other")
        #expect(containerPanelSelector.styleKeys.first == "editor.syntax.plain")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine applies CSS source-local overlays inside HTML style blocks")
    func highlighterAppliesCSSSourceLocalOverlaysInsideHTMLStyleBlocks() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        <style>
        @container (width > 10px) {
            .grid { --color: red; display: grid; }
        }
        </style>
        <div data-note="@container (width > 10px)"></div>
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let nsSource = source as NSString
        let embeddedContainerStart = nsSource.range(of: "@container (width")
        #expect(embeddedContainerStart.location != NSNotFound)
        let embeddedContainerRange = NSRange(
            location: embeddedContainerStart.location,
            length: ("@container" as NSString).length
        )

        let embeddedContainer = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@container",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@container (width"
        )
        let embeddedGridSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "grid",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".grid {"
        )
        let embeddedCustomProperty = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "--color",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: "--color: red"
        )
        let attributeContainerIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "@container",
            inOccurrenceOf: "data-note=\"@container"
        )

        #expect(embeddedContainer.styleKeys.first == "editor.syntax.declaration.other")
        #expect(embeddedGridSelector.styleKeys.first == "editor.syntax.plain")
        #expect(embeddedCustomProperty.styleKeys.first == "editor.syntax.plain")
        #expect(tokens.contains {
            tokenIntersects($0, range: embeddedContainerRange, syntaxID: .declarationOther, language: .css)
        })
        #expect(attributeContainerIDs.contains(.declarationOther) == false)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine keeps HTML text from driving embedded CSS source-local overlays")
    func highlighterConstrainsCSSSourceLocalOverlayScanningToHTMLStyleBlocks() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        <div>@container {
        <style>
        .grid { display: grid; }
        </style>
        }</div>
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)

        let topLevelGridSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "grid",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: ".grid {"
        )

        #expect(topLevelGridSelector.styleKeys.first == "editor.syntax.declaration.other")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine keeps separate HTML style blocks isolated for CSS overlays")
    func highlighterKeepsSeparateHTMLStyleBlocksIsolatedForCSSOverlays() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        <style>@container sidebar</style>
        <style>.grid { display: grid; }</style>
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)

        let incompleteContainerAtRule = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@container",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@container sidebar"
        )
        let incompleteContainerName = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "sidebar",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@container sidebar"
        )
        let secondBlockGridSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "grid",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: ".grid {"
        )
        let displayKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "display",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "display: grid"
        )

        #expect(incompleteContainerAtRule.styleKeys.first == "editor.syntax.declaration.other")
        #expect(incompleteContainerName.styleKeys.first == "editor.syntax.declaration.other")
        #expect(secondBlockGridSelector.styleKeys.first == "editor.syntax.declaration.other")
        #expect(displayKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine scopes CSS pseudo-function declaration overlays")
    func highlighterScopesCSSPseudoFunctionDeclarationOverlays() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        @supports selector(:has(img)) {
            .card { display: grid; }
        }
        @supports not selector(:has(img)) {
            .negated { display: grid; }
        }
        @supports (display: grid) and (color: red) {
            .support-value { display: grid; }
        }
        @media (min-width: 1px) {
            section:is(.hero) { color: red; }
        }
        @MEDIA (min-width: 1px) {
            .caps { display: grid; }
            .parent {
                .child { display: grid; }
            }
            @layer components {
                .layered { display: grid; }
            }
            @scope (.root) {
                .scoped { display: grid; }
            }
        }
        @supports SELECTOR(:HAS(img)) {
            .upper { display: grid; }
        }
        .value {
            --foo: :not(.bar);
        }
        section:is(.hero) { color: red; }
        section:not(.hidden) { color: red; }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.css)

        let supportsSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "selector",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@supports selector"
        )
        let supportsHasIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "has",
            inOccurrenceOf: "selector(:has"
        )
        let supportsArgumentIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "img",
            inOccurrenceOf: ":has(img)"
        )
        let negatedSupportsSelectorIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "selector",
            inOccurrenceOf: "not selector"
        )
        let negatedSupportsNot = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "not",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "@supports not"
        )
        let supportsDisplayKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "display",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "(display: grid)"
        )
        let supportsGridKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "grid",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "(display: grid)"
        )
        let supportsRedKeyword = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "red",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "(color: red)"
        )
        let mediaIsIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "is",
            inOccurrenceOf: "@media (min-width: 1px) {\n    section:is"
        )
        let uppercaseMediaSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "caps",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".caps {"
        )
        let nestedParentSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "parent",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".parent {"
        )
        let nestedChildSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "child",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".child {"
        )
        let layeredSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "layered",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".layered {"
        )
        let scopedSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "scoped",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: ".scoped {"
        )
        let scopePreludeSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "root",
            syntaxID: .plain,
            language: .css,
            inOccurrenceOf: "@scope (.root)"
        )
        let uppercaseSupportsSelector = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "SELECTOR",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "@supports SELECTOR"
        )
        let uppercaseSupportsHasIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "HAS",
            inOccurrenceOf: "SELECTOR(:HAS"
        )
        let uppercaseSupportsArgumentIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "img",
            inOccurrenceOf: ":HAS(img)"
        )
        let valueNotIDs = syntaxIDs(
            in: tokens,
            source: source,
            text: "not",
            inOccurrenceOf: "--foo: :not"
        )
        let topLevelIs = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "is",
            syntaxID: .declarationOther,
            language: .css,
            inOccurrenceOf: "}\nsection:is"
        )
        let topLevelNot = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "not",
            syntaxID: .keyword,
            language: .css,
            inOccurrenceOf: "}\nsection:not"
        )

        #expect(supportsSelector.styleKeys.first == "editor.syntax.declaration.other")
        #expect(supportsHasIDs.contains(.declarationOther) == false)
        #expect(supportsHasIDs.contains(.keyword) == false)
        #expect(supportsArgumentIDs.contains(.declarationOther) == false)
        #expect(negatedSupportsSelectorIDs.contains(.declarationOther) == false)
        #expect(negatedSupportsSelectorIDs.contains(.keyword) == false)
        #expect(negatedSupportsNot.styleKeys.first == "editor.syntax.keyword")
        #expect(supportsDisplayKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(supportsGridKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(supportsRedKeyword.styleKeys.first == "editor.syntax.keyword")
        #expect(mediaIsIDs.contains(.declarationOther) == false)
        #expect(mediaIsIDs.contains(.keyword) == false)
        #expect(uppercaseMediaSelector.styleKeys.first == "editor.syntax.plain")
        #expect(nestedParentSelector.styleKeys.first == "editor.syntax.plain")
        #expect(nestedChildSelector.styleKeys.first == "editor.syntax.plain")
        #expect(layeredSelector.styleKeys.first == "editor.syntax.plain")
        #expect(scopedSelector.styleKeys.first == "editor.syntax.plain")
        #expect(scopePreludeSelector.styleKeys.first == "editor.syntax.plain")
        #expect(uppercaseSupportsSelector.styleKeys.first == "editor.syntax.declaration.other")
        #expect(uppercaseSupportsHasIDs.contains(.declarationOther) == false)
        #expect(uppercaseSupportsHasIDs.contains(.keyword) == false)
        #expect(uppercaseSupportsArgumentIDs.contains(.declarationOther) == false)
        #expect(valueNotIDs.contains(.declarationOther) == false)
        #expect(topLevelIs.styleKeys.first == "editor.syntax.declaration.other")
        #expect(topLevelNot.styleKeys.first == "editor.syntax.keyword")
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine strips stale CSS conditional selector overlays after at-rule edits")
    func highlighterStripsStaleCSSConditionalSelectorOverlaysAfterAtRuleEdits() async throws {
        let source = """
        @media (min-width: 720px) {
            .grid { display: grid; }
        }
        """
        let updatedSource = """
        @layer (min-width: 720px) {
            .grid { display: grid; }
        }
        """
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.css)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.css,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.css)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine emits semantic HTML and injected captures for the reference sample")
    func highlighterEmitsSemanticHTMLCapturesForReferenceSample() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = try referenceSampleText(named: "Reference.html")
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)

        let doctype = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "<!DOCTYPE html>",
            syntaxID: "keyword",
            language: .html
        )
        let tag = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "main",
            syntaxID: "keyword",
            language: .html
        )
        let attribute = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "data-state",
            syntaxID: "attribute",
            language: .html
        )
        let attributeValue = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "\"ready\"",
            syntaxID: "string",
            language: .html
        )
        let bracket = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "<",
            syntaxID: "keyword",
            language: .html,
            inOccurrenceOf: #"<main class="page" id="hero">"#
        )
        let embeddedCSSProperty = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "margin",
            syntaxID: "keyword",
            language: .html,
            inOccurrenceOf: "margin: 0;"
        )
        let embeddedCSSColor = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "#007aff",
            syntaxID: "number",
            language: .html
        )
        let embeddedCSSAttributeValue = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "\"page\"",
            syntaxID: "string",
            language: .html,
            inOccurrenceOf: #"nav a[aria-current="page"]"#
        )
        let embeddedCSS = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "--brand-accent",
            syntaxID: "plain",
            language: .html
        )
        let embeddedJavaScript = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "const",
            syntaxID: "keyword",
            language: .html
        )

        #expect(doctype.styleKeys.first == "editor.syntax.keyword")
        #expect(tag.styleKeys.first == "editor.syntax.keyword")
        #expect(attribute.styleKeys.first == "editor.syntax.attribute")
        #expect(attributeValue.styleKeys.first == "editor.syntax.string")
        #expect(bracket.styleKeys.first == "editor.syntax.keyword")
        #expect(embeddedCSSProperty.styleKeys.first == "editor.syntax.keyword")
        #expect(embeddedCSSColor.styleKeys.first == "editor.syntax.number")
        #expect(embeddedCSSAttributeValue.text == "\"page\"")
        #expect(embeddedCSSAttributeValue.styleKeys.first == "editor.syntax.string")
        #expect(embeddedCSS.styleKeys.first == "editor.syntax.plain")
        #expect(embeddedJavaScript.styleKeys.first == "editor.syntax.keyword")
        let nsSource = source as NSString
        #expect(tokens.contains {
            $0.syntaxID == .string
                && $0.language == .html
                && nsSource.substring(with: $0.range) == "\"ready\""
        })
        let theme = SyntaxEditorTheme.default.resolved(for: .html, appearance: .dark)
        #expect(bracket.resolvedStyle.foreground == theme.keyword.foreground)
        #expect(embeddedCSSProperty.resolvedStyle.foreground == theme.keyword.foreground)
        #expect(embeddedCSSColor.resolvedStyle.foreground == theme.number.foreground)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine incrementally updates HTML injected languages")
    func highlighterIncrementallyUpdatesHTMLInjections() async throws {
        let source = """
        <style>body { color: red; }</style>
        <script>const answer = 42;</script>
        """
        let updatedSource = """
        <style>body { color: red; }</style>
        <script>let answer = 43;</script>
        """
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.html)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.html,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.html)
        let nsSource = updatedSource as NSString
        let stylePropertyRange = nsSource.range(of: "color")
        let scriptKeywordRange = nsSource.range(of: "let")

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: stylePropertyRange, syntaxID: .keyword, language: .css)
        })
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: scriptKeywordRange, syntaxID: .keyword, language: .javascript)
        })
    }

    @Test("SyntaxHighlighterEngine falls back when HTML tag edits can change injections")
    func highlighterResetsForHTMLInjectionBoundaryEdits() async throws {
        let source = "<script>const answer = 42;</script>"
        let updatedSource = "<style>const answer = 42;</script>"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.html)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.html,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.html)

        #expect(mutation.range == NSRange(location: 2, length: 5))
        #expect(refreshRangeUnion(incremental) == NSRange(location: 0, length: updatedSource.utf16.count))
        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
    }

    @Test("SyntaxHighlighterEngine keeps unsupported injections in direct highlighting mode")
    func highlighterKeepsUnsupportedInjectionsDirect() async {
        let engine = SyntaxHighlighterEngine()
        let javascriptTokens = await engine.reset(
            source: "const expression = /abc/;",
            language: SyntaxLanguage.javascript
        ).tokens
        let swiftTokens = await engine.reset(
            source: #"let expression = /abc/"#,
            language: SyntaxLanguage.swift
        ).tokens

        #expect(javascriptTokens.contains { $0.syntaxID == .keyword })
        #expect(swiftTokens.contains { $0.syntaxID == .keyword })
    }

    @Test("SyntaxHighlighterEngine highlights HTML root and embedded languages")
    func highlighterSupportsHTMLInjections() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        😀
        <!-- note -->
        <style>body { color: red; }</style>
        <script>const answer = 42;</script>
        <div class="hero">Hello</div>
        """

        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let nsSource = source as NSString
        let stylePropertyRange = nsSource.range(of: "color")
        let scriptKeywordRange = nsSource.range(of: "const")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains { $0.syntaxID == .comment && $0.language == .html })
        #expect(tokens.contains { $0.syntaxID == .keyword && $0.language == .html })
        #expect(tokens.contains { $0.syntaxID == .attribute && $0.language == .html })
        #expect(tokens.contains {
            tokenIntersects($0, range: stylePropertyRange, syntaxID: .keyword, language: .css)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: scriptKeywordRange, syntaxID: .keyword, language: .javascript)
        })
    }

    @Test("SyntaxHighlighterEngine resolves recursive injected aliases")
    func highlighterSupportsRecursiveInjectedAliases() async {
        let engine = SyntaxHighlighterEngine()
        let source = """
        <script>
        const view = html`<span class="hero">Hello</span>`;
        </script>
        """

        let tokens = await engine.reset(source: source, language: SyntaxLanguage.html).tokens
        let nsSource = source as NSString
        let nestedTagRange = nsSource.range(of: "<span")
        let nestedAttributeRange = nsSource.range(of: "class")

        #expect(tokens.contains {
            tokenIntersects($0, range: nestedTagRange, syntaxID: .keyword, language: .html)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: nestedAttributeRange, syntaxID: .attribute, language: .html)
        })
    }

    @Test("SyntaxHighlighterEngine does not inject unsupported script types")
    func highlighterSkipsUnsupportedScriptTypeInjections() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script type="application/json">{"enabled": true}</script>"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let trueRange = (source as NSString).range(of: "true")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            $0.language == .html && ($0.syntaxID == .keyword || $0.syntaxID == .attribute)
        })
        #expect(tokens.contains {
            tokenIsInjectedKeyword($0, in: trueRange)
        } == false)
    }

    @Test("SyntaxHighlighterEngine does not inject non-JavaScript script types")
    func highlighterSkipsNonJavaScriptScriptTypeInjections() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script type="text/plain">const answer = true;</script>"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let constRange = (source as NSString).range(of: "const")
        let trueRange = (source as NSString).range(of: "true")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            tokenIsInjectedKeyword($0, in: constRange)
        } == false)
        #expect(tokens.contains {
            tokenIsInjectedKeyword($0, in: trueRange)
        } == false)
    }

    @Test("SyntaxHighlighterEngine masks unsupported script types through EOF when closing tags are missing")
    func highlighterMasksUnsupportedScriptTypesThroughEOFWithoutClosingTag() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script type="application/json">{"enabled": true}"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let trueRange = (source as NSString).range(of: "true")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            tokenIsInjectedKeyword($0, in: trueRange)
        } == false)
    }

    @Test("SyntaxHighlighterEngine keeps highlighting supported script content past literal closing tag text")
    func highlighterKeepsHighlightingSupportedScriptContentPastLiteralClosingTagText() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script>const marker = "</script>"; const answer = 42;</script>"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let answerConstRange = (source as NSString).range(of: "const answer")

        #expect(tokens.contains {
            tokenIntersects($0, range: answerConstRange, syntaxID: .keyword, language: .javascript)
        })
    }

    @Test("SyntaxHighlighterEngine keeps highlighting supported script content past repeated literal closing tag text")
    func highlighterKeepsHighlightingSupportedScriptContentPastRepeatedLiteralClosingTagText() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script>const markers = ["</script>", "</script>"]; const answer = 42;</script>"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let answerConstRange = (source as NSString).range(of: "const answer")

        #expect(tokens.contains {
            tokenIntersects($0, range: answerConstRange, syntaxID: .keyword, language: .javascript)
        })
    }

    @Test("SyntaxHighlighterEngine ignores commented-out raw text tags")
    func highlighterIgnoresCommentedOutRawTextTags() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        <!-- <script type="text/plain"> -->
        <div class="hero">Hello</div>
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let divRange = (source as NSString).range(of: "<div")

        #expect(tokens.contains {
            tokenIntersects($0, range: divRange, syntaxID: .keyword, language: .html)
        })
    }

    @Test("SyntaxHighlighterEngine does not stop masking on longer unsupported script closing prefixes")
    func highlighterKeepsMaskingUnsupportedScriptContentPastLongerClosingPrefixes() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script type="application/json">{"marker":"</scripted>","enabled":true}</script>"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let trueRange = (source as NSString).range(of: "true")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            tokenIsInjectedKeyword($0, in: trueRange)
        } == false)
    }

    @Test("SyntaxHighlighterEngine does not inject unsupported script types when start tags contain quoted angle brackets")
    func highlighterSkipsUnsupportedScriptTypeInjectionsWithQuotedAngleBracketInStartTag() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = #"<script data="a>b" type="application/json">{"enabled": true}</script>"#
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let trueRange = (source as NSString).range(of: "true")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            tokenIsInjectedKeyword($0, in: trueRange)
        } == false)
    }

    @Test("SyntaxHighlighterEngine ignores raw-text-like attribute text")
    func highlighterIgnoresRawTextLikeAttributeText() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        <div data='<script type="application/json">'>Container</div>
        <span class="hero">Hello</span>
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
        let spanRange = (source as NSString).range(of: "<span")

        #expect(tokens.contains {
            tokenIntersects($0, range: spanRange, syntaxID: .keyword, language: .html)
        })
    }

    @Test("SyntaxHighlighterEngine skips malformed attribute tokens in unsupported script tags")
    func highlighterSkipsMalformedAttributeTokensInUnsupportedScriptTags() async {
        let engine = sharedSyntaxHighlighterEngine
        let cases = [
            #"<script async !foo type="application/json">{"enabled": true}</script>"#,
            #"<script !foo=http://example.com type="application/json">{"enabled": true}</script>"#,
            #"<script !foo=/assets/ type="application/json">{"enabled": true}</script>"#,
            #"<script !foo="a>b" type="application/json">{"enabled": true}</script>"#,
            #"<script !foo="bar"" type="application/json">{"enabled": true}</script>"#,
            #"<script !foo="bar"type="application/json">{"enabled": true}</script>"#,
            #"<script!type="application/json">{"enabled": true}</script>"#,
        ]

        for source in cases {
            let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
            let trueRange = (source as NSString).range(of: "true")

            #expect(tokens.isEmpty == false)
            #expect(tokens.contains {
                tokenIsInjectedKeyword($0, in: trueRange)
            } == false, "Unexpected injected keyword in unsupported script case: \(source)")
        }
    }

    @Test("SyntaxHighlighterEngine ignores malformed type-like attribute suffixes")
    func highlighterIgnoresMalformedTypeLikeAttributeSuffixes() async {
        let engine = sharedSyntaxHighlighterEngine
        let cases = [
            #"<script !type="application/json">const answer = 42;</script>"#,
            #"<script data!type="application/json">const answer = 42;</script>"#,
            #"<script !foo="bar type="application/json">const answer = 42;</script>"#,
        ]

        for source in cases {
            let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
            let constRange = (source as NSString).range(of: "const")

            #expect(tokens.contains {
                tokenIntersects($0, range: constRange, syntaxID: .keyword, language: .javascript)
            })
        }
    }

    @Test("SyntaxHighlighterEngine treats malformed unquoted unsupported script types as unsupported")
    func highlighterTreatsMalformedUnquotedUnsupportedScriptTypesAsUnsupported() async {
        let engine = sharedSyntaxHighlighterEngine
        let cases = [
            #"<script type=module=foo>const answer = true;</script>"#,
            #"<script type=text/plain/>const answer = true;</script>"#,
        ]

        for source in cases {
            let tokens = await engine.render(source: source, language: SyntaxLanguage.html)
            let constRange = (source as NSString).range(of: "const")

            #expect(tokens.contains {
                tokenIsInjectedKeyword($0, in: constRange)
            } == false)
        }
    }
}
