import Foundation
import Observation
import Testing
@testable import SyntaxEditorCore

func requireObservable<T: Observable>(_ value: T) {}

func applying(_ result: EditorCommandEngine.Result?, to source: String) -> String? {
    guard let result else { return nil }
    return applyingIfValid(result.edits, to: source)
}

func applying(_ result: EditorCommandEngine.Result, to source: String) -> String {
    SyntaxEditorModel.applying(result.edits, to: source)
}

func applying(_ edit: SyntaxLanguage.EditResult?, to source: String) -> String? {
    guard let edit else { return nil }
    return applyingIfValid(edit.edits, to: source)
}

func applying(_ edit: SyntaxLanguage.EditResult, to source: String) -> String {
    SyntaxEditorModel.applying(edit.edits, to: source)
}

func applyingIfValid(_ edits: [SyntaxEditorTextChange.Replacement], to source: String) -> String? {
    let length = source.utf16.count
    guard edits.allSatisfy({ edit in
        edit.range.location >= 0
            && edit.range.length >= 0
            && edit.range.location + edit.range.length <= length
    }) else {
        return nil
    }
    return SyntaxEditorModel.applying(edits, to: source)
}

func highlightTokensMatch(_ lhs: [SyntaxEditorHighlighting.Token], _ rhs: [SyntaxEditorHighlighting.Token]) -> Bool {
    sortHighlightTokens(lhs) == sortHighlightTokens(rhs)
}

func collectHighlightPhases(_ stream: AsyncStream<SyntaxEditorHighlighting.Result>) async -> [SyntaxEditorHighlighting.Result] {
    var results: [SyntaxEditorHighlighting.Result] = []
    for await result in stream {
        results.append(result)
    }
    return results
}

func sortHighlightTokens(_ tokens: [SyntaxEditorHighlighting.Token]) -> [SyntaxEditorHighlighting.Token] {
    tokens.sorted {
        if $0.range.location != $1.range.location {
            return $0.range.location < $1.range.location
        }
        if $0.range.length != $1.range.length {
            return $0.range.length < $1.range.length
        }
        return $0.rawCaptureName < $1.rawCaptureName
    }
}

func refreshRangeUnion(_ result: SyntaxEditorHighlighting.Result) -> NSRange {
    refreshRangeUnion(result.refreshRanges)
}

func refreshRangeUnion(_ ranges: [NSRange]) -> NSRange {
    guard let first = ranges.first else {
        return NSRange(location: 0, length: 0)
    }
    var lower = first.location
    var upper = first.upperBound
    for range in ranges.dropFirst() {
        lower = min(lower, range.location)
        upper = max(upper, range.upperBound)
    }
    return NSRange(location: lower, length: upper - lower)
}

func tokenIntersects(
    _ token: SyntaxEditorHighlighting.Token,
    range: NSRange,
    syntaxID: EditorSourceSyntax.ID? = nil,
    language: SyntaxLanguage? = nil
) -> Bool {
    if let syntaxID, token.syntaxID != syntaxID {
        return false
    }
    if let language, token.language != language {
        return false
    }
    return SyntaxEditorRangeUtilities.intersection(of: token.range, and: range).length > 0
}

func tokenIsInjectedKeyword(_ token: SyntaxEditorHighlighting.Token, in range: NSRange) -> Bool {
    (token.language == .javascript || token.language == .json)
        && token.syntaxID == .keyword
        && SyntaxEditorRangeUtilities.intersection(of: token.range, and: range).length > 0
}

struct HighlightSemanticSnapshot {
    let text: String
    let rawCaptureName: String
    let syntaxID: EditorSourceSyntax.ID
    let styleKeys: [String]
    let resolvedStyle: SyntaxEditorTheme.TextStyle
}

func referenceSampleText(named filename: String) throws -> String {
    let repositoryRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sampleURL = repositoryRootURL
        .appendingPathComponent("Tools/Mini/Mini/ReferenceSamples", isDirectory: true)
        .appendingPathComponent(filename)
    return try String(contentsOf: sampleURL, encoding: .utf8)
}

func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func highlightQueryURL(language: SyntaxLanguage) -> URL {
    let directoryName = switch language {
    case .plainText:
        preconditionFailure("Plain text does not have highlight queries.")
    case .css:
        "CSSQueries"
    case .html:
        "HTMLQueries"
    case .javascript:
        "JavaScriptQueries"
    case .json:
        "JSONQueries"
    case .objectiveC:
        "ObjectiveCQueries"
    case .swift:
        "SwiftQueries"
    case .toml:
        "TOMLQueries"
    case .xml:
        "XMLQueries"
    }
    return repositoryRootURL()
        .appendingPathComponent("Sources/SyntaxEditorCore/Resources", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
        .appendingPathComponent("highlights.scm")
}

func canonicalCaptureLanguageName(for language: SyntaxLanguage) -> String {
    switch language {
    case .plainText:
        "plaintext"
    case .css:
        "css"
    case .html:
        "html"
    case .javascript:
        "javascript"
    case .json:
        "json"
    case .objectiveC:
        "objectivec"
    case .swift:
        "swift"
    case .toml:
        "toml"
    case .xml:
        "xml"
    }
}

func languageImplementationDirectoryName(for language: SyntaxLanguage) -> String {
    switch language {
    case .plainText:
        "PlainText"
    case .css:
        "CSS"
    case .html:
        "HTML"
    case .javascript:
        "JavaScript"
    case .json:
        "JSON"
    case .objectiveC:
        "ObjectiveC"
    case .swift:
        "Swift"
    case .toml:
        "TOML"
    case .xml:
        "XML"
    }
}

func captureNames(inQuerySource source: String) -> [String] {
    var captures: [String] = []
    var index = source.startIndex
    var isInString = false
    var isEscaped = false
    var isInLineComment = false

    while index < source.endIndex {
        let character = source[index]

        if isInLineComment {
            if character == "\n" {
                isInLineComment = false
            }
            index = source.index(after: index)
            continue
        }

        if isInString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInString = false
            }
            index = source.index(after: index)
            continue
        }

        if character == ";" {
            isInLineComment = true
            index = source.index(after: index)
            continue
        }
        if character == "\"" {
            isInString = true
            index = source.index(after: index)
            continue
        }
        guard character == "@" else {
            index = source.index(after: index)
            continue
        }

        var end = source.index(after: index)
        while end < source.endIndex {
            let next = source[end]
            guard next.isLetter || next.isNumber || next == "." || next == "_" || next == "-" else {
                break
            }
            end = source.index(after: end)
        }
        if end > source.index(after: index) {
            captures.append(String(source[source.index(after: index)..<end]))
        }
        index = end
    }

    return captures
}

func semanticSnapshot(
    in tokens: [SyntaxEditorHighlighting.Token],
    source: String,
    text: String,
    syntaxID: EditorSourceSyntax.ID,
    language: SyntaxLanguage,
    inOccurrenceOf containingText: String? = nil
) throws -> HighlightSemanticSnapshot {
    let nsSource = source as NSString
    let searchRange: NSRange
    if let containingText {
        searchRange = nsSource.range(of: containingText)
        #expect(searchRange.location != NSNotFound)
    } else {
        searchRange = NSRange(location: 0, length: nsSource.length)
    }
    let expectedRange = nsSource.range(of: text, options: [], range: searchRange)
    #expect(expectedRange.location != NSNotFound)
    let matchedToken = tokens.first {
        $0.syntaxID == syntaxID
            && SyntaxEditorRangeUtilities.intersection(of: $0.range, and: expectedRange).length > 0
    }
    if matchedToken == nil {
        let nearby = tokens
            .filter { SyntaxEditorRangeUtilities.intersection(of: $0.range, and: searchRange).length > 0 }
            .map { token in
                "\(nsSource.substring(with: token.range)):\(token.rawCaptureName)"
            }
            .joined(separator: ", ")
        Issue.record("Could not find \(syntaxID.rawValue) for \(text) in \(containingText ?? source). Nearby: \(nearby)")
    }
    let token = try #require(matchedToken)
    let tokenText = nsSource.substring(with: token.range)
    let styleKeys = try #require(SyntaxEditorHighlightTheme.semanticStyleKeys(
        for: token.syntaxID,
        language: language
    ))
    let style = try #require(SyntaxEditorHighlightTheme.style(
        for: token.syntaxID,
        in: .default,
        language: language,
        appearance: .dark
    ))
    return HighlightSemanticSnapshot(
        text: tokenText,
        rawCaptureName: token.rawCaptureName,
        syntaxID: token.syntaxID,
        styleKeys: styleKeys,
        resolvedStyle: style
    )
}

func syntaxIDs(
    in tokens: [SyntaxEditorHighlighting.Token],
    source: String,
    text: String,
    inOccurrenceOf containingText: String
) -> [EditorSourceSyntax.ID] {
    let nsSource = source as NSString
    let searchRange = nsSource.range(of: containingText)
    #expect(searchRange.location != NSNotFound)
    let expectedRange = nsSource.range(of: text, options: [], range: searchRange)
    #expect(expectedRange.location != NSNotFound)

    return tokens
        .filter { SyntaxEditorRangeUtilities.intersection(of: $0.range, and: expectedRange).length > 0 }
        .map(\.syntaxID)
}

func effectiveSemanticSnapshot(
    in tokens: [SyntaxEditorHighlighting.Token],
    source: String,
    text: String,
    syntaxID: EditorSourceSyntax.ID,
    language: SyntaxLanguage,
    inOccurrenceOf containingText: String
) throws -> HighlightSemanticSnapshot {
    let nsSource = source as NSString
    let searchRange = nsSource.range(of: containingText)
    #expect(searchRange.location != NSNotFound)
    let expectedRange = nsSource.range(of: text, options: [], range: searchRange)
    #expect(expectedRange.location != NSNotFound)

    let overlappingTokens = tokens.filter {
        SyntaxEditorRangeUtilities.intersection(of: $0.range, and: expectedRange).length > 0
    }
    let matchedToken = overlappingTokens.last
    if matchedToken?.syntaxID != syntaxID {
        let nearby = tokens
            .filter { SyntaxEditorRangeUtilities.intersection(of: $0.range, and: searchRange).length > 0 }
            .map { token in
                "\(nsSource.substring(with: token.range)):\(token.rawCaptureName)"
            }
            .joined(separator: ", ")
        Issue.record("Could not find effective \(syntaxID.rawValue) token for \(text) in \(containingText). Nearby: \(nearby)")
    }

    let token = try #require(matchedToken)
    #expect(token.syntaxID == syntaxID)
    let tokenText = nsSource.substring(with: token.range)
    let styleKeys = try #require(SyntaxEditorHighlightTheme.semanticStyleKeys(
        for: token.syntaxID,
        language: language
    ))
    let style = try #require(SyntaxEditorHighlightTheme.style(
        for: token.syntaxID,
        in: .default,
        language: language,
        appearance: .dark
    ))
    return HighlightSemanticSnapshot(
        text: tokenText,
        rawCaptureName: token.rawCaptureName,
        syntaxID: token.syntaxID,
        styleKeys: styleKeys,
        resolvedStyle: style
    )
}

extension SyntaxHighlighterEngine {
    func reset(source: String, language: SyntaxLanguage) async -> SyntaxEditorHighlighting.Result {
        await reset(source: source, language: language, revision: 0)
    }

    func update(
        previousSource: String,
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement
    ) async -> SyntaxEditorHighlighting.Result {
        _ = previousSource
        let result = await update(source: source, language: language, mutation: mutation, revision: 1)
        guard result.tokenPayload == .replacement else {
            return result
        }
        let currentTokens = await currentTokensForTesting()
        return SyntaxEditorHighlighting.Result(
            tokens: currentTokens,
            source: result.source,
            language: result.language,
            revision: result.revision,
            refreshRanges: result.refreshRanges,
            phase: result.phase,
            tokenPayload: .fullSnapshot
        )
    }
}

let sharedSyntaxHighlighterEngine = SyntaxHighlighterEngine()

extension SyntaxHighlighterEngineTests {
    func expectHighlightTokens(source: String, language: SyntaxLanguage) async {
        let engine = sharedSyntaxHighlighterEngine
        let tokens = await engine.render(source: source, language: language)
        #expect(tokens.isEmpty == false)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    func expectPreparedLanguagesRender(_ languages: [SyntaxLanguage]) async {
        let engine = SyntaxHighlighterEngine()
        for language in languages {
            let tokens = await engine.render(source: smokeSource(for: language), language: language)
            #expect(tokens.isEmpty == false)
            #expect(tokens.allSatisfy { $0.range.length > 0 })
        }
    }

    func smokeSource(for language: SyntaxLanguage) -> String {
        switch language {
        case .plainText:
            "plain text"
        case .css:
            "body { color: red; }"
        case .html:
            "<script>const answer = 42;</script><style>body { color: red; }</style>"
        case .javascript:
            "const answer = 42;"
        case .json:
            "{\"enabled\": true, \"count\": 1}"
        case .objectiveC:
            "@interface ReferenceObject\n@property(nonatomic) NSInteger count;\n@end"
        case .swift:
            "let answer = 42"
        case .toml:
            "title = \"Reference\"\n"
        case .xml:
            "<root attr=\"value\">text</root>"
        }
    }
}
