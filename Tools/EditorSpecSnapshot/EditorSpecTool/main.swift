import Foundation
import SourceModelBridge
import SyntaxEditorCore

#if canImport(AppKit)
import AppKit
#endif

#if canImport(SourceEditor) && canImport(SourceModelSupport) && canImport(SymbolCache) && canImport(SymbolCacheIndexing) && canImport(SymbolCacheSupport)
import SourceEditor
import SourceModelSupport
import SymbolCache
import SymbolCacheIndexing
import SymbolCacheSupport
#endif

/// The Xcode the tool reads from unless `--xcode` names another: the one whose
/// frameworks this process loaded, so resources and themes come from the same
/// installation as the code that interprets them.
private let defaultToolchainAppPath: String = {
    let sourceModel = Bundle.allFrameworks.first {
        $0.bundleURL.lastPathComponent == "SourceModel.framework"
    }
    // <Xcode.app>/Contents/SharedFrameworks/SourceModel.framework
    guard let app = sourceModel?.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent(),
        app.pathExtension == "app"
    else {
        return "/Applications/Xcode.app"
    }
    return app.path
}()

private enum SemanticDepth: String, Sendable {
    case currentFile = "current-file"
    case sdk
}

private struct SnapshotRange: Codable, Hashable, Sendable {
    let location: Int
    let length: Int

    var upperBound: Int {
        location + length
    }

    func contains(_ other: SnapshotRange) -> Bool {
        location <= other.location && other.upperBound <= upperBound
    }
}

private struct EditorTokenRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let syntaxID: String
    let language: String
    let rawCaptureName: String
}

private struct SourceModelTokenRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let syntaxID: String
    let specificationIdentifier: String
    let tokenName: String
}

private struct RenderedColorRecord: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    let hex: String
    let rgbaHex: String
    let colorSpace: String
}

private struct XcodeRenderedTokenRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let syntaxID: String
    let nodeType: Int?
    let tokenType: String?
    let tokenModifiers: [String]?
    let color: RenderedColorRecord
}

private struct XcodeSemanticTokenRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let tokenType: String
    let tokenModifiers: [String]
    let syntaxID: String
    let color: RenderedColorRecord
}

private struct XcodeClassificationTokenRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let tokenType: String
    let uiKind: String?
    let syntaxID: String
}

private struct EditorRenderedTokenRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let syntaxID: String
    let language: String
    let rawCaptureName: String
    let color: RenderedColorRecord
}

private struct DiffRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let sourceSyntaxID: String
    let editorSyntaxID: String
    let sourceModel: SourceModelTokenRecord?
    let editor: EditorTokenRecord?
}

private struct RenderedDiffRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let xcodeSyntaxID: String
    let editorSyntaxID: String
    let xcodeColor: RenderedColorRecord?
    let editorColor: RenderedColorRecord
    let xcode: XcodeRenderedTokenRecord?
    let editor: EditorRenderedTokenRecord
}

private struct ClassificationDiffRecord: Codable, Sendable {
    let range: SnapshotRange
    let text: String
    let xcodeSyntaxID: String
    let editorSyntaxID: String
    let xcode: XcodeClassificationTokenRecord?
    let editor: EditorTokenRecord?
}

private struct DiffSummary: Codable, Sendable {
    let comparedSegments: Int
    let differences: Int
    let matches: Int
}

private struct RenderedDiffOutput: Codable, Sendable {
    let source: [String: String]
    let summary: DiffSummary
    let differences: [RenderedDiffRecord]
    let matches: [RenderedDiffRecord]
}

private struct ClassificationDiffOutput: Codable, Sendable {
    let source: [String: String]
    let summary: DiffSummary
    let differences: [ClassificationDiffRecord]
    let matches: [ClassificationDiffRecord]
}

private struct DiffOutput: Codable, Sendable {
    let source: [String: String]
    let summary: DiffSummary
    let differences: [DiffRecord]
    let matches: [DiffRecord]
}

private struct XcodeRenderedTokenOutput: Codable, Sendable {
    let source: [String: String]
    let tokens: [XcodeRenderedTokenRecord]
}

private struct XcodeSemanticTokenOutput: Codable, Sendable {
    let source: [String: String]
    let tokens: [XcodeSemanticTokenRecord]
}

private struct XcodeClassificationTokenOutput: Codable, Sendable {
    let source: [String: String]
    let tokens: [XcodeClassificationTokenRecord]
}

private struct EditorTokenOutput: Codable, Sendable {
    let source: [String: String]
    let tokens: [EditorTokenRecord]
}

private enum ToolError: Error, CustomStringConvertible {
    case usage
    case missingArgument(String)
    case invalidLanguage(String)
    case invalidRange(SnapshotRange)
    case sourceModel(String)
    case xcodeTool(String)

    var description: String {
        switch self {
        case .usage:
            """
            Usage:
              swift run EditorSpecTool editor-tokens --file <path> [--language swift] [--pretty]
              swift run EditorSpecTool source-model-tokens --file <path> [--language swift] [--xcode <Xcode.app>] [--pretty] [--no-text]
              swift run EditorSpecTool xcode-classification-tokens --file <path> [--language swift|css|objectiveC] [--xcode <Xcode.app>] [--semantic-depth current-file|sdk] [--pretty] [--no-text]
              swift run EditorSpecTool xcode-semantic-tokens --file <path> [--language swift] [--xcode <Xcode.app>] [--xcode-theme default-dark] [--appearance dark] [--pretty] [--no-text]
              swift run EditorSpecTool xcode-rendered-tokens --file <path> [--language swift|css|objectiveC] [--xcode <Xcode.app>] [--semantic-depth current-file|sdk] [--xcode-theme default-dark] [--pretty] [--no-text]
              swift run EditorSpecTool xcode-dvt-rendered-tokens --file <path> [--language objectiveC] [--xcode <Xcode.app>] [--xcode-theme default-dark] [--pretty] [--no-text]
              swift run EditorSpecTool xcode-dvt-language-diagnostics --file <path> [--language swift] [--xcode <Xcode.app>] [--pretty]
              swift run EditorSpecTool xcode-source-editor-view-diagnostics --file <path> [--language swift] [--xcode <Xcode.app>] [--pretty]
              swift run EditorSpecTool diff --file <path> [--language swift|css] [--xcode <Xcode.app>] [--pretty] [--include-matches]
              swift run EditorSpecTool classification-diff --file <path> [--language swift|css|objectiveC] [--xcode <Xcode.app>] [--semantic-depth current-file|sdk] [--pretty] [--include-matches]
              swift run EditorSpecTool rendered-diff --file <path> [--language swift|css|objectiveC] [--xcode <Xcode.app>] [--semantic-depth current-file|sdk] [--xcode-theme default-dark] [--appearance dark] [--pretty] [--include-matches]
            """
        case let .missingArgument(argument):
            "Missing value for \(argument)"
        case let .invalidLanguage(value):
            "Unsupported language: \(value)"
        case let .invalidRange(range):
            "Range is outside the source text: \(range.location):\(range.length)"
        case let .sourceModel(message):
            message
        case let .xcodeTool(message):
            message
        }
    }
}

@main
private enum EditorSpecTool {
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.isEmpty == false else {
                throw ToolError.usage
            }
            let command = arguments.removeFirst()
            let options = try Options(arguments)

            switch command {
            case "editor-tokens":
                try await writeJSON(editorTokenOutput(options: options), pretty: options.pretty)
            case "source-model-tokens":
                try writeSourceModelSnapshot(options: options)
            case "xcode-classification-tokens":
                try await writeJSON(xcodeClassificationTokenOutput(options: options), pretty: options.pretty)
            case "xcode-semantic-tokens":
                try await writeJSON(xcodeSemanticTokenOutput(options: options), pretty: options.pretty)
            case "xcode-rendered-tokens":
                try await writeJSON(xcodeRenderedTokenOutput(options: options), pretty: options.pretty)
            case "xcode-dvt-rendered-tokens":
                try writeJSON(xcodeDVTRenderedTokenOutput(options: options), pretty: options.pretty)
            case "xcode-dvt-language-diagnostics":
                try writeLanguageDiagnostics(options: options)
            case "xcode-source-editor-view-diagnostics":
                try writeSourceEditorViewDiagnostics(options: options)
            case "diff":
                try await writeJSON(diffOutput(options: options), pretty: options.pretty)
            case "classification-diff":
                try await writeJSON(classificationDiffOutput(options: options), pretty: options.pretty)
            case "rendered-diff":
                try await writeJSON(renderedDiffOutput(options: options), pretty: options.pretty)
            case "--help", "-h":
                throw ToolError.usage
            default:
                throw ToolError.usage
            }
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            Foundation.exit(1)
        }
    }

    private static func editorTokenOutput(options: Options) async throws -> EditorTokenOutput {
        let source = try sourceText(options.filePath)
        let tokens = try await editorTokens(source: source, language: options.language)
        return EditorTokenOutput(
            source: [
                "file": options.filePath,
                "language": options.language.identifier,
            ],
            tokens: tokens
        )
    }

    private static func xcodeRenderedTokenOutput(options: Options) async throws -> XcodeRenderedTokenOutput {
        let source = try sourceText(options.filePath)
        return XcodeRenderedTokenOutput(
            source: sourceMetadata(
                filePath: options.filePath,
                language: options.language,
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearance: options.appearanceName,
                semanticDepth: options.semanticDepth
            ),
            tokens: try await xcodeRenderedTokens(options: options, source: source, includeText: options.includeText)
        )
    }

    @MainActor
    private static func xcodeDVTRenderedTokenOutput(options: Options) throws -> XcodeRenderedTokenOutput {
        let source = try sourceText(options.filePath)
        let snapshot = try xcodeRenderedSnapshot(options: options, includeText: options.includeText)
        return XcodeRenderedTokenOutput(
            source: sourceMetadata(
                filePath: options.filePath,
                language: options.language,
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearance: options.appearanceName,
                semanticDepth: options.semanticDepth
            ),
            tokens: xcodeRenderedTokens(from: snapshot, source: source)
        )
    }

    private static func xcodeSemanticTokenOutput(options: Options) async throws -> XcodeSemanticTokenOutput {
        guard options.language.identifier == SyntaxLanguage.swift.identifier else {
            throw ToolError.invalidLanguage(options.language.identifier)
        }

        let source = try sourceText(options.filePath)
        return XcodeSemanticTokenOutput(
            source: sourceMetadata(
                filePath: options.filePath,
                language: options.language,
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearance: options.appearanceName,
                semanticDepth: options.semanticDepth
            ),
            tokens: try await xcodeSwiftSemanticTokens(options: options, source: source, includeText: options.includeText)
        )
    }

    private static func xcodeClassificationTokenOutput(options: Options) async throws -> XcodeClassificationTokenOutput {
        let source = try sourceText(options.filePath)
        return XcodeClassificationTokenOutput(
            source: sourceMetadata(
                filePath: options.filePath,
                language: options.language,
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearance: options.appearanceName,
                semanticDepth: options.semanticDepth
            ),
            tokens: try await xcodeClassificationTokens(options: options, source: source, includeText: options.includeText)
        )
    }

    private static func writeSourceModelSnapshot(options: Options) throws {
        let snapshot = try sourceModelSnapshot(options: options, includeText: options.includeText)
        let writingOptions: JSONSerialization.WritingOptions = options.pretty
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: writingOptions)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeSourceEditorViewDiagnostics(options: Options) throws {
        let languageIdentifier = try sourceModelBridgeLanguageIdentifier(for: options.language)
        let diagnostics = try SourceModelBridge.sourceEditorViewDiagnostics(
            filePath: options.filePath,
            language: languageIdentifier,
            toolchainAppPath: options.xcodePath
        )
        let writingOptions: JSONSerialization.WritingOptions = options.pretty
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: diagnostics, options: writingOptions)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeLanguageDiagnostics(options: Options) throws {
        let languageIdentifier = try sourceModelBridgeLanguageIdentifier(for: options.language)
        let diagnostics = try SourceModelBridge.languageDiagnostics(
            filePath: options.filePath,
            language: languageIdentifier,
            toolchainAppPath: options.xcodePath
        )
        let writingOptions: JSONSerialization.WritingOptions = options.pretty
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: diagnostics, options: writingOptions)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func classificationDiffOutput(options: Options) async throws -> ClassificationDiffOutput {
        let source = try sourceText(options.filePath)
        let sourceLength = utf16Length(source)
        let xcodeTokens = try await xcodeClassificationTokens(options: options, source: source, includeText: true)
        let editorTokens = try await editorTokens(source: source, language: options.language)
        let boundaries = sortedClassificationBoundaries(
            sourceUTF16Length: sourceLength,
            xcodeTokens: xcodeTokens,
            editorTokens: editorTokens
        )

        var differences: [ClassificationDiffRecord] = []
        var matches: [ClassificationDiffRecord] = []
        var matchCount = 0
        var comparedSegments = 0

        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let range = SnapshotRange(location: start, length: end - start)
            guard range.length > 0 else { continue }
            let text = try utf16Slice(source, range: range)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }

            let xcodeToken = effectiveXcodeClassificationToken(in: xcodeTokens, covering: range)
            let editorToken = effectiveEditorToken(in: editorTokens, covering: range)
            let xcodeSyntaxID = xcodeToken?.syntaxID ?? "plain"
            let editorSyntaxID = editorToken?.syntaxID ?? "plain"
            comparedSegments += 1

            let record = ClassificationDiffRecord(
                range: range,
                text: text,
                xcodeSyntaxID: xcodeSyntaxID,
                editorSyntaxID: editorSyntaxID,
                xcode: xcodeToken,
                editor: editorToken
            )

            guard xcodeSyntaxID == editorSyntaxID else {
                differences.append(record)
                continue
            }

            matchCount += 1
            if options.includeMatches {
                matches.append(record)
            }
        }

        return ClassificationDiffOutput(
            source: sourceMetadata(
                filePath: options.filePath,
                language: options.language,
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearance: options.appearanceName,
                semanticDepth: options.semanticDepth
            ),
            summary: DiffSummary(
                comparedSegments: comparedSegments,
                differences: differences.count,
                matches: matchCount
            ),
            differences: differences,
            matches: matches
        )
    }

    private static func renderedDiffOutput(options: Options) async throws -> RenderedDiffOutput {
        let source = try sourceText(options.filePath)
        let sourceLength = utf16Length(source)
        let xcodeTokens = try await xcodeRenderedTokens(options: options, source: source, includeText: true)
        let editorTokens = try await editorRenderedTokens(source: source, language: options.language, appearance: options.appearance)
        let boundaries = sortedRenderedBoundaries(sourceUTF16Length: sourceLength, xcodeTokens: xcodeTokens, editorTokens: editorTokens)
        let xcodePlainColor = try xcodeThemeColorRecord(
            syntaxID: "plain",
            colors: xcodeThemeColors(
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearanceName: options.appearanceName
            )
        )

        var differences: [RenderedDiffRecord] = []
        var matches: [RenderedDiffRecord] = []
        var matchCount = 0
        var comparedSegments = 0

        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let range = SnapshotRange(location: start, length: end - start)
            guard range.length > 0 else { continue }
            let text = try utf16Slice(source, range: range)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }

            let xcodeToken = effectiveXcodeRenderedToken(in: xcodeTokens, covering: range)
            let editorToken = effectiveEditorRenderedToken(in: editorTokens, covering: range, source: source, language: options.language, appearance: options.appearance)
            let xcodeColor = xcodeToken?.color ?? xcodePlainColor
            comparedSegments += 1

            let record = RenderedDiffRecord(
                range: range,
                text: text,
                xcodeSyntaxID: xcodeToken?.syntaxID ?? "plain",
                editorSyntaxID: editorToken.syntaxID,
                xcodeColor: xcodeColor,
                editorColor: editorToken.color,
                xcode: xcodeToken,
                editor: editorToken
            )

            guard xcodeColor.rgbaHex.lowercased() == editorToken.color.rgbaHex.lowercased() else {
                differences.append(record)
                continue
            }

            matchCount += 1
            if options.includeMatches {
                matches.append(record)
            }
        }

        return RenderedDiffOutput(
            source: sourceMetadata(
                filePath: options.filePath,
                language: options.language,
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearance: options.appearanceName,
                semanticDepth: options.semanticDepth
            ),
            summary: DiffSummary(
                comparedSegments: comparedSegments,
                differences: differences.count,
                matches: matchCount
            ),
            differences: differences,
            matches: matches
        )
    }

    private static func diffOutput(options: Options) async throws -> DiffOutput {
        if options.language == .css {
            return try await diffOutputFromClassification(options: options)
        }

        let source = try sourceText(options.filePath)
        let sourceLength = utf16Length(source)
        let sourceSnapshot = try sourceModelSnapshot(options: options, includeText: true)
        let sourceTokens = sourceModelTokens(from: sourceSnapshot, sourceUTF16Length: sourceLength)
        let editorTokens = try await editorTokens(source: source, language: options.language)
        let boundaries = sortedBoundaries(sourceTokens: sourceTokens, editorTokens: editorTokens)

        var differences: [DiffRecord] = []
        var matches: [DiffRecord] = []
        var matchCount = 0
        var comparedSegments = 0

        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let range = SnapshotRange(location: start, length: end - start)
            guard range.length > 0 else { continue }
            let text = try utf16Slice(source, range: range)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }

            let sourceToken = effectiveSourceModelToken(in: sourceTokens, covering: range)
            let editorToken = effectiveEditorToken(in: editorTokens, covering: range)
            let sourceSyntaxID = sourceToken?.syntaxID ?? "plain"
            let editorSyntaxID = editorToken?.syntaxID ?? "plain"
            comparedSegments += 1

            guard sourceSyntaxID != editorSyntaxID else {
                matchCount += 1
                if options.includeMatches {
                    matches.append(DiffRecord(
                        range: range,
                        text: text,
                        sourceSyntaxID: sourceSyntaxID,
                        editorSyntaxID: editorSyntaxID,
                        sourceModel: sourceToken,
                        editor: editorToken
                    ))
                }
                continue
            }

            differences.append(DiffRecord(
                range: range,
                text: text,
                sourceSyntaxID: sourceSyntaxID,
                editorSyntaxID: editorSyntaxID,
                sourceModel: sourceToken,
                editor: editorToken
            ))
        }

        return DiffOutput(
            source: [
                "file": options.filePath,
                "language": options.language.identifier,
                "xcode": options.xcodePath,
            ],
            summary: DiffSummary(
                comparedSegments: comparedSegments,
                differences: differences.count,
                matches: matchCount
            ),
            differences: differences,
            matches: matches
        )
    }

    private static func diffOutputFromClassification(options: Options) async throws -> DiffOutput {
        let classificationOutput = try await classificationDiffOutput(options: options)
        return DiffOutput(
            source: classificationOutput.source,
            summary: classificationOutput.summary,
            differences: classificationOutput.differences.map(diffRecord(from:)),
            matches: classificationOutput.matches.map(diffRecord(from:))
        )
    }

    private static func diffRecord(from record: ClassificationDiffRecord) -> DiffRecord {
        DiffRecord(
            range: record.range,
            text: record.text,
            sourceSyntaxID: record.xcodeSyntaxID,
            editorSyntaxID: record.editorSyntaxID,
            sourceModel: sourceModelToken(from: record.xcode),
            editor: record.editor
        )
    }

    private static func sourceModelToken(from token: XcodeClassificationTokenRecord?) -> SourceModelTokenRecord? {
        guard let token else {
            return nil
        }
        return SourceModelTokenRecord(
            range: token.range,
            text: token.text,
            syntaxID: token.syntaxID,
            specificationIdentifier: "SourceEditor.\(token.tokenType)",
            tokenName: token.uiKind ?? token.tokenType
        )
    }

    private static func sourceText(_ filePath: String) throws -> String {
        try String(contentsOfFile: filePath, encoding: .utf8)
    }

    private static func sourceModelSnapshot(options: Options, includeText: Bool) throws -> NSDictionary {
        let languageIdentifier = try sourceModelBridgeLanguageIdentifier(for: options.language)
        let snapshot = try SourceModelBridge.snapshot(
            filePath: options.filePath,
            language: languageIdentifier,
            toolchainAppPath: options.xcodePath,
            includeText: includeText
        )
        return snapshot as NSDictionary
    }

    @MainActor
    private static func xcodeRenderedTokens(
        options: Options,
        source: String,
        includeText: Bool
    ) throws -> [XcodeRenderedTokenRecord] {
        if options.language.identifier == SyntaxLanguage.swift.identifier {
            return try xcodeSwiftSemanticTokens(options: options, source: source, includeText: includeText)
                .map { token in
                    XcodeRenderedTokenRecord(
                        range: token.range,
                        text: token.text,
                        syntaxID: token.syntaxID,
                        nodeType: nil,
                        tokenType: token.tokenType,
                        tokenModifiers: token.tokenModifiers,
                        color: token.color
                    )
                }
        }

        if options.language == .css || options.language == .objectiveC {
            let classificationTokens = try xcodeClassificationTokens(
                options: options,
                source: source,
                includeText: includeText
            )
            let xcodeThemeColors = try xcodeThemeColors(
                xcodePath: options.xcodePath,
                xcodeThemeName: options.xcodeThemeName,
                appearanceName: options.appearanceName
            )
            return try classificationTokens
                .map { token in
                    XcodeRenderedTokenRecord(
                        range: token.range,
                        text: token.text,
                        syntaxID: token.syntaxID,
                        nodeType: nil,
                        tokenType: token.tokenType,
                        tokenModifiers: token.uiKind.map { [$0] },
                        color: try xcodeThemeColorRecord(
                            syntaxID: token.syntaxID,
                            colors: xcodeThemeColors
                        )
                    )
                }
        }

        let snapshot = try xcodeRenderedSnapshot(options: options, includeText: includeText)
        return xcodeRenderedTokens(from: snapshot, source: source)
    }

    @MainActor
    private static func xcodeRenderedSnapshot(options: Options, includeText: Bool) throws -> NSDictionary {
        let languageIdentifier = try sourceModelBridgeLanguageIdentifier(for: options.language)
        let snapshot = try SourceModelBridge.renderedSnapshot(
            filePath: options.filePath,
            language: languageIdentifier,
            toolchainAppPath: options.xcodePath,
            themeName: options.xcodeThemeName,
            includeText: includeText
        )
        return snapshot as NSDictionary
    }

    private static func sourceModelBridgeLanguageIdentifier(for language: SyntaxLanguage) throws -> String {
        switch language {
        case .plainText:
            throw ToolError.invalidLanguage(language.identifier)
        default:
            return language.identifier
        }
    }

    private static func editorTokens(source: String, language: SyntaxLanguage) async throws -> [EditorTokenRecord] {
        try await SyntaxHighlighterEngine()
            .render(source: source, language: language)
            .map { token in
                let range = SnapshotRange(location: token.range.location, length: token.range.length)
                return EditorTokenRecord(
                    range: range,
                    text: try utf16Slice(source, range: range),
                    syntaxID: token.syntaxID.rawValue,
                    language: token.language?.identifier ?? language.identifier,
                    rawCaptureName: token.rawCaptureName
                )
            }
    }

    private static func editorRenderedTokens(
        source: String,
        language: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance
    ) async throws -> [EditorRenderedTokenRecord] {
        try await editorTokens(source: source, language: language).map { token in
            EditorRenderedTokenRecord(
                range: token.range,
                text: token.text,
                syntaxID: token.syntaxID,
                language: token.language,
                rawCaptureName: token.rawCaptureName,
                color: editorColorRecord(
                    syntaxID: token.syntaxID,
                    language: SyntaxLanguage(identifier: token.language) ?? language,
                    fallbackLanguage: language,
                    appearance: appearance
                )
            )
        }
    }

    @MainActor
    private static func xcodeClassificationTokens(
        options: Options,
        source: String,
        includeText: Bool
    ) throws -> [XcodeClassificationTokenRecord] {
        if options.language.identifier == SyntaxLanguage.swift.identifier {
            return try xcodeSwiftClassificationTokens(
                options: options,
                source: source,
                includeText: includeText
            )
        }

        guard options.language == .css || options.language == .objectiveC else {
            throw ToolError.invalidLanguage(options.language.identifier)
        }

        return try xcodeGenericClassificationTokens(
            options: options,
            source: source,
            includeText: includeText
        )
    }

    private static func sourceEditorClassificationSupports(language: SyntaxLanguage) -> Bool {
        language == .swift || language == .css || language == .objectiveC
    }

    @MainActor
    private static func xcodeSwiftSemanticTokens(
        options: Options,
        source: String,
        includeText: Bool
    ) throws -> [XcodeSemanticTokenRecord] {
        let classificationTokens = try xcodeSwiftClassificationTokens(
            options: options,
            source: source,
            includeText: includeText
        )
        let xcodeThemeColors = try xcodeThemeColors(
            xcodePath: options.xcodePath,
            xcodeThemeName: options.xcodeThemeName,
            appearanceName: options.appearanceName
        )

        return try classificationTokens.map { token in
            XcodeSemanticTokenRecord(
                range: token.range,
                text: token.text,
                tokenType: token.tokenType,
                tokenModifiers: token.uiKind.map { [$0] } ?? [],
                syntaxID: token.syntaxID,
                color: try xcodeThemeColorRecord(
                    syntaxID: token.syntaxID,
                    colors: xcodeThemeColors
                )
            )
        }
    }

    @MainActor
    private static func xcodeSwiftClassificationTokens(
        options: Options,
        source: String,
        includeText: Bool
    ) throws -> [XcodeClassificationTokenRecord] {
        #if canImport(SourceEditor) && canImport(SourceModelSupport) && canImport(SymbolCache) && canImport(SymbolCacheIndexing) && canImport(SymbolCacheSupport)
        let dataSource = sourceEditorSwiftDataSource(options: options, source: source)
        return try sourceEditorClassificationTokens(dataSource: dataSource, source: source, includeText: includeText)
        #else
        throw ToolError.xcodeTool("SourceEditor.framework token probe is available on macOS only.")
        #endif
    }

    @MainActor
    private static func xcodeGenericClassificationTokens(
        options: Options,
        source: String,
        includeText: Bool
    ) throws -> [XcodeClassificationTokenRecord] {
        #if canImport(SourceEditor) && canImport(SourceModelSupport) && canImport(SymbolCache) && canImport(SymbolCacheIndexing) && canImport(SymbolCacheSupport)
        let dataSource: SourceEditorDataSource
        if options.language == .objectiveC {
            dataSource = try sourceEditorObjectiveCDataSource(options: options, source: source)
        } else {
            dataSource = try sourceEditorGenericDataSource(options: options, source: source)
        }
        return try sourceEditorClassificationTokens(dataSource: dataSource, source: source, includeText: includeText)
        #else
        throw ToolError.xcodeTool("SourceEditor.framework token probe is available on macOS only.")
        #endif
    }

    #if canImport(SourceEditor) && canImport(SourceModelSupport) && canImport(SymbolCache) && canImport(SymbolCacheIndexing) && canImport(SymbolCacheSupport)
    private static func sourceEditorClassificationTokens(
        dataSource: SourceEditorDataSource,
        source: String,
        includeText: Bool
    ) throws -> [XcodeClassificationTokenRecord] {
        let lineStarts = utf16LineStartOffsets(source)
        let buffer: SourceEditorBuffer = dataSource
        let tokenProvider = dataSource.languageService

        var records: [XcodeClassificationTokenRecord] = []
        var seenRanges = Set<SnapshotRange>()
        for line in 0..<buffer.lineCount {
            guard line < lineStarts.count else {
                continue
            }
            let lineUTF16Length = (buffer.lineContentForLine(line) as NSString).length
            tokenProvider.enumerateSyntaxTokensOnLine(line) { token, lineRange in
                guard lineRange.lowerBound >= 0,
                      lineRange.upperBound <= lineUTF16Length,
                      lineRange.lowerBound < lineRange.upperBound
                else {
                    return
                }

                let semanticToken = tokenProvider.syntaxTypeAtPosition(
                    SourceEditorPosition(line: line, col: lineRange.lowerBound),
                    includingSemanticsAndDocumentation: true
                )?.0 ?? token
                let range = SnapshotRange(
                    location: lineStarts[line] + lineRange.lowerBound,
                    length: lineRange.upperBound - lineRange.lowerBound
                )
                let info = sourceEditorTokenInfo(semanticToken)
                seenRanges.insert(range)
                records.append(XcodeClassificationTokenRecord(
                    range: range,
                    text: includeText ? ((try? utf16Slice(source, range: range)) ?? "") : "",
                    tokenType: info.tokenType,
                    uiKind: info.uiKind,
                    syntaxID: info.syntaxID
                ))
            }
        }

        if records.isEmpty {
            records = sourceEditorScannedClassificationTokens(
                tokenProvider: tokenProvider,
                buffer: buffer,
                source: source,
                lineStarts: lineStarts,
                includeText: includeText,
                seenRanges: &seenRanges
            )
        }

        return records
    }

    private static func sourceEditorScannedClassificationTokens(
        tokenProvider: SourceEditorLanguageService,
        buffer: SourceEditorBuffer,
        source: String,
        lineStarts: [Int],
        includeText: Bool,
        seenRanges: inout Set<SnapshotRange>
    ) -> [XcodeClassificationTokenRecord] {
        var records: [XcodeClassificationTokenRecord] = []
        for line in 0..<buffer.lineCount {
            guard line < lineStarts.count else {
                continue
            }
            let lineUTF16Length = (buffer.lineContentForLine(line) as NSString).length
            var column = 0
            while column < lineUTF16Length {
                let position = SourceEditorPosition(line: line, col: column)
                guard let (optionalToken, positionRange) = tokenProvider.syntaxTypeAtPosition(
                    position,
                    includingSemanticsAndDocumentation: true
                ),
                    let token = optionalToken,
                    let range = snapshotRange(
                        from: positionRange,
                        lineStarts: lineStarts,
                        sourceUTF16Length: utf16Length(source)
                    ),
                    range.length > 0,
                    seenRanges.contains(range) == false
                else {
                    column += 1
                    continue
                }

                let info = sourceEditorTokenInfo(token)
                records.append(XcodeClassificationTokenRecord(
                    range: range,
                    text: includeText ? ((try? utf16Slice(source, range: range)) ?? "") : "",
                    tokenType: info.tokenType,
                    uiKind: info.uiKind,
                    syntaxID: info.syntaxID
                ))
                seenRanges.insert(range)

                if positionRange.upperBound.line == line {
                    column = max(positionRange.upperBound.col, column + 1)
                } else {
                    break
                }
            }
        }
        return records
    }

    private static func snapshotRange(
        from range: Range<SourceEditorPosition>,
        lineStarts: [Int],
        sourceUTF16Length: Int
    ) -> SnapshotRange? {
        guard range.lowerBound.line >= 0,
              range.lowerBound.line < lineStarts.count,
              range.upperBound.line >= 0,
              range.upperBound.line < lineStarts.count
        else {
            return nil
        }
        let location = lineStarts[range.lowerBound.line] + range.lowerBound.col
        let end = lineStarts[range.upperBound.line] + range.upperBound.col
        guard location >= 0,
              end > location,
              end <= sourceUTF16Length
        else {
            return nil
        }
        return SnapshotRange(location: location, length: end - location)
    }

    private static func sourceEditorSwiftDataSource(options: Options, source: String) -> SourceEditorDataSource {
        let baseLanguage = GenericLanguage(
            name: "Swift",
            identifier: "xcode.lang.swift",
            languageService: SymbolCacheLanguageService.self,
            lineDataFactory: DefaultSourceEditorLineDataFactory(),
            editableRangeSnapshot: nil
        )
        let language = SymbolCacheEditorLanguage(delegateLanguage: baseLanguage)
        let symbolCacheComposite = sourceEditorSymbolCacheComposite(options: options)
        let documentSettings = BasicSymbolCacheDocumentSettings(symbolCacheComposite: symbolCacheComposite)
        let dataSourceWithSettings = SourceEditorDataSource(
            name: URL(fileURLWithPath: options.filePath).lastPathComponent,
            language: language,
            usingMutableString: NSMutableString(string: source),
            formattingOptions: SourceEditorFormattingOptions(),
            documentSettings: documentSettings
        )
        if let languageService = dataSourceWithSettings.languageService as? SymbolCacheLanguageService {
            languageService.symbolCacheComposite = symbolCacheComposite
            languageService.documentSettingsChanged(options.filePath)
        }
        return dataSourceWithSettings
    }

    private static func sourceEditorGenericDataSource(options: Options, source: String) throws -> SourceEditorDataSource {
        let languageIdentifier = try sourceEditorLanguageIdentifier(for: options.language)
        let language = SourceModelEditorLanguage(
            name: options.language.displayName,
            identifier: languageIdentifier,
            languageService: SourceModelLanguageService.self,
            lineDataFactory: DefaultSourceEditorLineDataFactory(),
            editableRangeSnapshot: nil
        )
        return SourceEditorDataSource(
            name: URL(fileURLWithPath: options.filePath).lastPathComponent,
            language: language,
            usingMutableString: NSMutableString(string: source),
            formattingOptions: SourceEditorFormattingOptions(),
            documentSettings: nil
        )
    }

    private static func sourceEditorObjectiveCDataSource(options: Options, source: String) throws -> SourceEditorDataSource {
        let languageIdentifier = try sourceEditorLanguageIdentifier(for: options.language)
        let baseLanguage = SourceModelEditorLanguage(
            name: options.language.displayName,
            identifier: languageIdentifier,
            languageService: SourceModelLanguageService.self,
            lineDataFactory: DefaultSourceEditorLineDataFactory(),
            editableRangeSnapshot: nil
        )
        let language = SymbolCacheEditorLanguage(delegateLanguage: baseLanguage)
        let symbolCacheComposite = sourceEditorSymbolCacheComposite(options: options)
        let documentSettings = BasicSymbolCacheDocumentSettings(symbolCacheComposite: symbolCacheComposite)
        let dataSource = SourceEditorDataSource(
            name: URL(fileURLWithPath: options.filePath).lastPathComponent,
            language: language,
            usingMutableString: NSMutableString(string: source),
            formattingOptions: SourceEditorFormattingOptions(),
            documentSettings: documentSettings
        )
        if let languageService = dataSource.languageService as? SymbolCacheLanguageService {
            languageService.symbolCacheComposite = symbolCacheComposite
            languageService.documentSettingsChanged(options.filePath)
        }
        return dataSource
    }

    private static func sourceEditorLanguageIdentifier(for language: SyntaxLanguage) throws -> String {
        switch language {
        case .plainText:
            throw ToolError.invalidLanguage(language.identifier)
        case .css:
            return "xcode.lang.css"
        case .assemblyARM:
            return "xcode.lang.asm.arm"
        case .html:
            return "xcode.lang.html"
        case .javascript:
            return "xcode.lang.javascript"
        case .json:
            return "xcode.lang.json"
        case .objectiveC:
            return "xcode.lang.objc"
        case .swift:
            return "xcode.lang.swift"
        case .toml:
            return "xcode.lang.toml"
        case .xml:
            return "xcode.lang.xml"
        }
    }

    private static func sourceEditorSymbolCacheComposite(options: Options) -> ToolSymbolCacheComposite {
        let fileURL = URL(fileURLWithPath: options.filePath)
        let symbolCache = FileParsingSymbolCache.makeDefaultSymbolCache(
            name: "EditorSpecTool",
            basePath: nil
        )
        symbolCache.parse(fileURLs: [fileURL], canceled: { false }) { _ in }
        var providers: [SymbolCacheProvider] = [symbolCache.snapshot()]
        if options.semanticDepth == .sdk {
            providers.append(contentsOf: sdkSymbolCacheProviders(options: options, fileSymbolCache: symbolCache))
        }
        return ToolSymbolCacheComposite(providers: providers)
    }

    // SymbolCacheIndexing exposes SDKSymbolCache's provider conformance in its
    // swiftinterface, but not as a linkable descriptor in current Xcode builds.
    @inline(never)
    @_optimize(none)
    private static func sdkSymbolCacheProviders(
        options: Options,
        fileSymbolCache: FileParsingSymbolCache
    ) -> [SymbolCacheProvider] {
        do {
            let sdkURL = try macOSSDKURL()
            let storage = SymbolCacheSDKStorage(
                ioManager: SymbolCacheSDKIOManager(
                    baseURL: sdkCacheBaseURL(),
                    onlySerializeSwift: true
                )
            )
            let loader = SymbolCacheSDKLoader(
                sdkURL: sdkURL,
                toolchainModulesURL: swiftToolchainModulesURL(xcodePath: options.xcodePath),
                variantName: nil,
                storage: storage,
                onlyLoadFromCache: false,
                useRelativePaths: false
            )
            loader.addPlatformDeveloperSearchPaths(
                developerDirectory: URL(fileURLWithPath: options.xcodePath)
                    .appendingPathComponent("Contents/Developer", isDirectory: true)
            )

            var imports = Set((try? swiftImports(in: sourceText(options.filePath))) ?? [])
            imports.insert("_Concurrency")
            let loadTypes = [SymbolCacheSDKLoadType.stdLib]
                + imports.sorted().map(SymbolCacheSDKLoadType.module)
            var providers: [SymbolCacheProvider] = [loader.modulesSymbolCache]
            for loadType in loadTypes {
                switch loader.load(request: SDKLoadingRequest(type: loadType)) {
                case let .success(response):
                    providers.append(contentsOf: response.symbolCaches)
                case .failure:
                    continue
                }
            }
            return providers
        } catch {
            return []
        }
    }

    private static func macOSSDKURL() throws -> URL {
        URL(fileURLWithPath: try xcrunOutput(arguments: ["--sdk", "macosx", "--show-sdk-path"]), isDirectory: true)
    }

    private static func swiftToolchainModulesURL(xcodePath: String) -> URL? {
        if let swiftPath = try? xcrunOutput(arguments: ["--toolchain", "XcodeDefault", "--find", "swift"]) {
            let usrURL = URL(fileURLWithPath: swiftPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let modulesURL = usrURL.appendingPathComponent("lib/swift/macosx", isDirectory: true)
            if FileManager.default.fileExists(atPath: modulesURL.path) {
                return modulesURL
            }
        }

        let fallback = URL(fileURLWithPath: xcodePath)
            .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", isDirectory: true)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private static func sdkCacheBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntaxEditorUI-EditorSpecTool-SDKSymbolCache", isDirectory: true)
    }

    private static func swiftImports(in source: String) -> [String] {
        let pattern = #"(?m)^\s*import\s+(?:(?:class|struct|enum|protocol|func|let|var)\s+)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsSource = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                return nsSource.substring(with: match.range(at: 1)).split(separator: ".").first.map(String.init)
            }
    }

    private static func xcrunOutput(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !output.isEmpty {
            return output
        }

        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ToolError.xcodeTool(error.isEmpty ? "xcrun \(arguments.joined(separator: " ")) failed." : error)
    }

    private final class ToolSymbolCacheComposite: SymbolCacheComposite {
        let tokenStore: SymbolCacheProviderTokenStore

        init(providers: [SymbolCacheProvider]) {
            tokenStore = SymbolCacheProviderTokenStore(providers: providers)
        }

        var projectProviderSet: Set<UInt32>? {
            nil
        }

        var projectStateCache: SymbolCacheProjectStateCache? {
            nil
        }

        var projectSymbolCaches: [FileParsingSymbolCache] {
            []
        }

        func updateProjectStateIfNeeded() {}
        func fileWasOpened(filePath: String) {}
        func fileWasClosed(filePath: String) {}
    }

    private static func sourceEditorTokenInfo(
        _ token: SourceEditorTokenType
    ) -> (tokenType: String, uiKind: String?, syntaxID: String) {
        switch token {
        case let .identifier(data):
            return sourceEditorTokenInfo(tokenType: "identifier", uiKind: data?.uiKind, fallbackSyntaxID: "plain")
        case let .keyword(data):
            return sourceEditorTokenInfo(tokenType: "keyword", uiKind: data?.uiKind, fallbackSyntaxID: "keyword")
        case .number:
            return (tokenType: "number", uiKind: nil, syntaxID: "number")
        case .boolean:
            return (tokenType: "boolean", uiKind: nil, syntaxID: "keyword")
        case .string:
            return (tokenType: "string", uiKind: nil, syntaxID: "string")
        case let .objectLiteral(data):
            return sourceEditorTokenInfo(tokenType: "objectLiteral", uiKind: data?.uiKind, fallbackSyntaxID: "identifier.macro.system")
        case let .comment(data):
            return sourceEditorTokenInfo(tokenType: "comment", uiKind: data?.uiKind, fallbackSyntaxID: "comment")
        case .url:
            return (tokenType: "url", uiKind: nil, syntaxID: "url")
        case .placeholder:
            return (tokenType: "placeholder", uiKind: nil, syntaxID: "plain")
        case .character:
            return (tokenType: "character", uiKind: nil, syntaxID: "character")
        case .preprocessorStatement:
            return (tokenType: "preprocessorStatement", uiKind: nil, syntaxID: "preprocessor")
        case let .languageSpecific(data):
            return sourceEditorTokenInfo(tokenType: "languageSpecific", uiKind: data?.uiKind, fallbackSyntaxID: "plain")
        @unknown default:
            return (tokenType: "unknown", uiKind: nil, syntaxID: "plain")
        }
    }

    private static func sourceEditorTokenInfo(
        tokenType: String,
        uiKind: SourceEditorTokenType.UIKind?,
        fallbackSyntaxID: String
    ) -> (tokenType: String, uiKind: String?, syntaxID: String) {
        guard let uiKind else {
            return (tokenType: tokenType, uiKind: nil, syntaxID: fallbackSyntaxID)
        }
        return (
            tokenType: tokenType,
            uiKind: sourceEditorUIKindName(uiKind),
            syntaxID: sourceEditorSyntaxID(uiKind: uiKind) ?? fallbackSyntaxID
        )
    }

    private static func sourceEditorSyntaxID(uiKind: SourceEditorTokenType.UIKind) -> String? {
        switch uiKind {
        case .keyword:
            return "keyword"
        case .attribute:
            return "attribute"
        case .comment:
            return "comment"
        case .documentationComment:
            return "comment.doc"
        case .documentationCommentKeyword:
            return "comment.doc.keyword"
        case .mark:
            return "mark"
        case .typeDeclaration:
            return "declaration.type"
        case .otherDeclaration:
            return "declaration.other"
        case let .className(scope):
            return scope == .project ? "identifier.class" : "identifier.class.system"
        case let .typeName(scope):
            return scope == .project ? "identifier.type" : "identifier.type.system"
        case let .functionMethodName(scope):
            return scope == .project ? "identifier.function" : "identifier.function.system"
        case let .constant(scope):
            return scope == .project ? "identifier.constant" : "identifier.constant.system"
        case let .instanceGlobalVariable(scope):
            return scope == .project ? "identifier.variable" : "identifier.variable.system"
        case let .preprocessorMacro(scope):
            return scope == .project ? "identifier.macro" : "identifier.macro.system"
        case .markupCode:
            return "markup.code"
        case .markupAside:
            return "markup.aside.kind"
        case .markdownHeader:
            return "markup.header"
        case .disabled:
            return "disabled"
        @unknown default:
            return nil
        }
    }

    private static func sourceEditorUIKindName(_ uiKind: SourceEditorTokenType.UIKind) -> String {
        switch uiKind {
        case .keyword:
            return "keyword"
        case .attribute:
            return "attribute"
        case .comment:
            return "comment"
        case .documentationComment:
            return "documentationComment"
        case .documentationCommentKeyword:
            return "documentationCommentKeyword"
        case .mark:
            return "mark"
        case .typeDeclaration:
            return "typeDeclaration"
        case .otherDeclaration:
            return "otherDeclaration"
        case let .className(scope):
            return "className.\(sourceEditorScopeName(scope))"
        case let .typeName(scope):
            return "typeName.\(sourceEditorScopeName(scope))"
        case let .functionMethodName(scope):
            return "functionMethodName.\(sourceEditorScopeName(scope))"
        case let .constant(scope):
            return "constant.\(sourceEditorScopeName(scope))"
        case let .instanceGlobalVariable(scope):
            return "instanceGlobalVariable.\(sourceEditorScopeName(scope))"
        case let .preprocessorMacro(scope):
            return "preprocessorMacro.\(sourceEditorScopeName(scope))"
        case let .markdownHeader(level):
            return "markdownHeader.\(level)"
        case .markupCode:
            return "markupCode"
        case .markupAside:
            return "markupAside"
        case .disabled:
            return "disabled"
        @unknown default:
            return "unknown"
        }
    }

    private static func sourceEditorScopeName(_ scope: SourceEditorTokenType.UIKind.Scope) -> String {
        switch scope {
        case .project:
            return "project"
        case .external:
            return "external"
        @unknown default:
            return "unknown"
        }
    }
    #endif

    private static func sourceModelTokens(
        from snapshot: NSDictionary,
        sourceUTF16Length: Int
    ) -> [SourceModelTokenRecord] {
        guard let items = snapshot["items"] as? [NSDictionary] else {
            return []
        }

        return items.compactMap { item in
            guard let rangeDictionary = item["range"] as? NSDictionary,
                  let location = rangeDictionary["location"] as? Int,
                  let length = rangeDictionary["length"] as? Int,
                  length > 0
            else {
                return nil
            }

            let syntaxID = normalizedSyntaxID(item["syntaxType"] as? String)
            if location == 0 && length >= sourceUTF16Length && syntaxID == "plain" {
                return nil
            }

            return SourceModelTokenRecord(
                range: SnapshotRange(location: location, length: length),
                text: item["text"] as? String ?? "",
                syntaxID: syntaxID,
                specificationIdentifier: item["specificationIdentifier"] as? String ?? "",
                tokenName: item["tokenName"] as? String ?? ""
            )
        }
    }

    private static func xcodeRenderedTokens(from snapshot: NSDictionary, source: String) -> [XcodeRenderedTokenRecord] {
        guard let items = snapshot["items"] as? [NSDictionary] else {
            return []
        }

        return items.compactMap { item in
            guard let rangeDictionary = item["range"] as? NSDictionary,
                  let location = rangeDictionary["location"] as? Int,
                  let length = rangeDictionary["length"] as? Int,
                  length > 0,
                  let colorDictionary = item["color"] as? NSDictionary,
                  let color = renderedColorRecord(from: colorDictionary)
            else {
                return nil
            }

            let range = SnapshotRange(location: location, length: length)
            return XcodeRenderedTokenRecord(
                range: range,
                text: item["text"] as? String ?? (try? utf16Slice(source, range: range)) ?? "",
                syntaxID: normalizedSyntaxID(item["syntaxType"] as? String),
                nodeType: item["nodeType"] as? Int,
                tokenType: nil,
                tokenModifiers: nil,
                color: color
            )
        }
    }

    private static func sortedBoundaries(
        sourceTokens: [SourceModelTokenRecord],
        editorTokens: [EditorTokenRecord]
    ) -> [Int] {
        var boundaries = Set<Int>()
        for token in sourceTokens {
            boundaries.insert(token.range.location)
            boundaries.insert(token.range.upperBound)
        }
        for token in editorTokens {
            boundaries.insert(token.range.location)
            boundaries.insert(token.range.upperBound)
        }
        return boundaries.sorted()
    }

    private static func sortedRenderedBoundaries(
        sourceUTF16Length: Int,
        xcodeTokens: [XcodeRenderedTokenRecord],
        editorTokens: [EditorRenderedTokenRecord]
    ) -> [Int] {
        var boundaries: Set<Int> = [0, sourceUTF16Length]
        for token in xcodeTokens {
            boundaries.insert(token.range.location)
            boundaries.insert(token.range.upperBound)
        }
        for token in editorTokens {
            boundaries.insert(token.range.location)
            boundaries.insert(token.range.upperBound)
        }
        return boundaries.sorted()
    }

    private static func sortedClassificationBoundaries(
        sourceUTF16Length: Int,
        xcodeTokens: [XcodeClassificationTokenRecord],
        editorTokens: [EditorTokenRecord]
    ) -> [Int] {
        var boundaries: Set<Int> = [0, sourceUTF16Length]
        for token in xcodeTokens {
            boundaries.insert(token.range.location)
            boundaries.insert(token.range.upperBound)
        }
        for token in editorTokens {
            boundaries.insert(token.range.location)
            boundaries.insert(token.range.upperBound)
        }
        return boundaries.sorted()
    }

    private static func effectiveSourceModelToken(
        in tokens: [SourceModelTokenRecord],
        covering range: SnapshotRange
    ) -> SourceModelTokenRecord? {
        tokens
            .filter { $0.range.contains(range) }
            .min {
                if $0.range.length != $1.range.length {
                    return $0.range.length < $1.range.length
                }
                if $0.specificationIdentifier != $1.specificationIdentifier {
                    return $0.specificationIdentifier < $1.specificationIdentifier
                }
                return $0.tokenName < $1.tokenName
            }
    }

    private static func effectiveXcodeRenderedToken(
        in tokens: [XcodeRenderedTokenRecord],
        covering range: SnapshotRange
    ) -> XcodeRenderedTokenRecord? {
        tokens
            .filter { $0.range.contains(range) }
            .min {
                if $0.range.length != $1.range.length {
                    return $0.range.length < $1.range.length
                }
                return $0.syntaxID < $1.syntaxID
            }
    }

    private static func effectiveXcodeClassificationToken(
        in tokens: [XcodeClassificationTokenRecord],
        covering range: SnapshotRange
    ) -> XcodeClassificationTokenRecord? {
        tokens
            .filter { $0.range.contains(range) }
            .min {
                if $0.range.length != $1.range.length {
                    return $0.range.length < $1.range.length
                }
                if $0.tokenType != $1.tokenType {
                    return $0.tokenType < $1.tokenType
                }
                return $0.syntaxID < $1.syntaxID
            }
    }

    private static func effectiveEditorToken(
        in tokens: [EditorTokenRecord],
        covering range: SnapshotRange
    ) -> EditorTokenRecord? {
        tokens.last { $0.range.contains(range) }
    }

    private static func effectiveEditorRenderedToken(
        in tokens: [EditorRenderedTokenRecord],
        covering range: SnapshotRange,
        source: String,
        language: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance
    ) -> EditorRenderedTokenRecord {
        if let token = tokens.last(where: { $0.range.contains(range) }) {
            return token
        }
        return EditorRenderedTokenRecord(
            range: range,
            text: (try? utf16Slice(source, range: range)) ?? "",
            syntaxID: "plain",
            language: language.identifier,
            rawCaptureName: EditorSourceSyntax.Capture.rawCaptureName(syntaxID: .plain, language: language),
            color: editorColorRecord(
                syntaxID: "plain",
                language: language,
                fallbackLanguage: language,
                appearance: appearance
            )
        )
    }

    private static func normalizedSyntaxID(_ value: String?) -> String {
        var result = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "plain"
        for prefix in ["xcode.syntax.", "editor.syntax."] {
            if result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                break
            }
        }
        return result.isEmpty ? "plain" : result
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private static func utf16LineStartOffsets(_ text: String) -> [Int] {
        let nsText = text as NSString
        var offsets = [0]
        for index in 0..<nsText.length where nsText.character(at: index) == 10 {
            offsets.append(index + 1)
        }
        return offsets
    }

    private static func utf16Slice(_ text: String, range: SnapshotRange) throws -> String {
        let nsText = text as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.upperBound <= nsText.length
        else {
            throw ToolError.invalidRange(range)
        }
        return nsText.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func sourceMetadata(
        filePath: String,
        language: SyntaxLanguage,
        xcodePath: String,
        xcodeThemeName: String,
        appearance: String,
        semanticDepth: SemanticDepth? = nil
    ) -> [String: String] {
        var metadata = [
            "file": filePath,
            "language": language.identifier,
            "xcode": xcodePath,
            "xcodeTheme": xcodeThemeName,
            "appearance": appearance,
        ]
        if let semanticDepth {
            metadata["semanticDepth"] = semanticDepth.rawValue
        }
        return metadata
    }

    private static func renderedColorRecord(from dictionary: NSDictionary) -> RenderedColorRecord? {
        guard let red = dictionary["red"] as? Double,
              let green = dictionary["green"] as? Double,
              let blue = dictionary["blue"] as? Double,
              let alpha = dictionary["alpha"] as? Double
        else {
            return nil
        }

        return RenderedColorRecord(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha,
            hex: dictionary["hex"] as? String ?? "",
            rgbaHex: dictionary["rgbaHex"] as? String ?? "",
            colorSpace: dictionary["colorSpace"] as? String ?? ""
        )
    }

    private static func editorColorRecord(
        syntaxID: String,
        language: SyntaxLanguage,
        fallbackLanguage: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance
    ) -> RenderedColorRecord {
        let theme = SyntaxEditorTheme.default
        let resolvedTheme = theme.resolved(for: fallbackLanguage, appearance: appearance)
        let color = SyntaxEditorHighlightTheme.color(
            for: syntaxID,
            in: theme,
            language: language,
            appearance: appearance
        ) ?? resolvedTheme.base.foreground
        return renderedColorRecord(from: color)
    }

    private static func xcodeThemeColors(
        xcodePath: String,
        xcodeThemeName: String,
        appearanceName: String
    ) throws -> [String: RenderedColorRecord] {
        let themeFileName = sourceEditorThemeFileName(
            xcodeThemeName: xcodeThemeName,
            appearanceName: appearanceName
        )
        let themePath = "\(xcodePath)/Contents/SharedFrameworks/SourceEditor.framework/Versions/A/Resources/\(themeFileName)"
        guard let theme = NSDictionary(contentsOfFile: themePath),
              let syntaxColors = theme["DVTSourceTextSyntaxColors"] as? NSDictionary
        else {
            throw ToolError.xcodeTool("Could not load Xcode SourceEditor theme at \(themePath).")
        }

        var colors: [String: RenderedColorRecord] = [:]
        for (key, value) in syntaxColors {
            guard let key = key as? String,
                  let colorString = value as? String,
                  let color = renderedColorRecord(xcodeThemeColorString: colorString)
            else {
                continue
            }
            colors[key] = color
        }

        guard colors["xcode.syntax.plain"] != nil else {
            throw ToolError.xcodeTool("Xcode SourceEditor theme at \(themePath) does not define xcode.syntax.plain.")
        }
        return colors
    }

    private static func sourceEditorThemeFileName(
        xcodeThemeName: String,
        appearanceName: String
    ) -> String {
        let trimmedThemeName = xcodeThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedThemeName.hasSuffix(".xccolortheme") {
            return trimmedThemeName
        }

        switch trimmedThemeName.lowercased() {
        case "default-light", "default (light)":
            return "Default (Light).xccolortheme"
        case "default-dark", "default (dark)":
            return "Default (Dark).xccolortheme"
        default:
            if trimmedThemeName.isEmpty {
                return appearanceName == "light"
                    ? "Default (Light).xccolortheme"
                    : "Default (Dark).xccolortheme"
            }
            return "\(trimmedThemeName).xccolortheme"
        }
    }

    private static func xcodeThemeColorRecord(
        syntaxID: String,
        colors: [String: RenderedColorRecord]
    ) throws -> RenderedColorRecord {
        let colorKey = "xcode.syntax.\(syntaxID)"
        guard let color = colors[colorKey] ?? colors["xcode.syntax.plain"] else {
            throw ToolError.xcodeTool("Could not resolve Xcode theme color for \(colorKey).")
        }
        return color
    }

    private static func renderedColorRecord(xcodeThemeColorString: String) -> RenderedColorRecord? {
        let components = xcodeThemeColorString
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard components.count >= 4 else {
            return nil
        }

        let red = components[0]
        let green = components[1]
        let blue = components[2]
        let alpha = components[3]
        let redByte = Int((red * 255).rounded())
        let greenByte = Int((green * 255).rounded())
        let blueByte = Int((blue * 255).rounded())
        let alphaByte = Int((alpha * 255).rounded())
        let hex = "#\(byteHex(redByte))\(byteHex(greenByte))\(byteHex(blueByte))"

        return RenderedColorRecord(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha,
            hex: hex,
            rgbaHex: "\(hex)\(byteHex(alphaByte))",
            colorSpace: "genericRGB"
        )
    }

    private static func renderedColorRecord(from color: SyntaxEditorTheme.Color) -> RenderedColorRecord {
#if canImport(AppKit)
        let converted = color.usingColorSpace(.genericRGB) ?? color.usingColorSpace(.sRGB) ?? color
        let red = Double(converted.redComponent)
        let green = Double(converted.greenComponent)
        let blue = Double(converted.blueComponent)
        let alpha = Double(converted.alphaComponent)
        let redByte = Int((red * 255).rounded())
        let greenByte = Int((green * 255).rounded())
        let blueByte = Int((blue * 255).rounded())
        let alphaByte = Int((alpha * 255).rounded())
        let hex = "#\(byteHex(redByte))\(byteHex(greenByte))\(byteHex(blueByte))"
        return RenderedColorRecord(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha,
            hex: hex,
            rgbaHex: "\(hex)\(byteHex(alphaByte))",
            colorSpace: converted.colorSpace.localizedName ?? ""
        )
#else
        return RenderedColorRecord(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1,
            hex: "#000000",
            rgbaHex: "#000000FF",
            colorSpace: ""
        )
#endif
    }

    private static func byteHex(_ value: Int) -> String {
        let clamped = min(255, max(0, value))
        let string = String(clamped, radix: 16, uppercase: true)
        return string.count == 1 ? "0\(string)" : string
    }

    private static func writeJSON<T: Encodable>(_ value: T, pretty: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct Options: Sendable {
    let filePath: String
    let language: SyntaxLanguage
    let xcodePath: String
    let semanticDepth: SemanticDepth
    let xcodeThemeName: String
    let appearance: SyntaxEditorTheme.Appearance
    let appearanceName: String
    let pretty: Bool
    let includeText: Bool
    let includeMatches: Bool

    init(_ rawArguments: [String]) throws {
        var filePath: String?
        var language = SyntaxLanguage.swift
        var xcodePath = defaultToolchainAppPath
        var semanticDepth = SemanticDepth.currentFile
        var xcodeThemeName: String?
        var appearanceName = "dark"
        var pretty = false
        var includeText = true
        var includeMatches = false

        var index = 0
        while index < rawArguments.count {
            let argument = rawArguments[index]
            switch argument {
            case "--file":
                index += 1
                guard index < rawArguments.count else {
                    throw ToolError.missingArgument(argument)
                }
                filePath = rawArguments[index]
            case "--language":
                index += 1
                guard index < rawArguments.count else {
                    throw ToolError.missingArgument(argument)
                }
                guard let resolved = SyntaxLanguage(identifier: rawArguments[index]) else {
                    throw ToolError.invalidLanguage(rawArguments[index])
                }
                language = resolved
            case "--xcode":
                index += 1
                guard index < rawArguments.count else {
                    throw ToolError.missingArgument(argument)
                }
                xcodePath = rawArguments[index]
            case "--semantic-depth":
                index += 1
                guard index < rawArguments.count else {
                    throw ToolError.missingArgument(argument)
                }
                guard let resolved = SemanticDepth(rawValue: rawArguments[index]) else {
                    throw ToolError.missingArgument("--semantic-depth current-file|sdk")
                }
                semanticDepth = resolved
            case "--xcode-theme":
                index += 1
                guard index < rawArguments.count else {
                    throw ToolError.missingArgument(argument)
                }
                xcodeThemeName = rawArguments[index]
            case "--appearance":
                index += 1
                guard index < rawArguments.count else {
                    throw ToolError.missingArgument(argument)
                }
                let value = rawArguments[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard value == "light" || value == "dark" else {
                    throw ToolError.missingArgument("--appearance light|dark")
                }
                appearanceName = value
            case "--pretty":
                pretty = true
            case "--no-text":
                includeText = false
            case "--include-matches":
                includeMatches = true
            default:
                throw ToolError.usage
            }
            index += 1
        }

        guard let filePath else {
            throw ToolError.usage
        }

        self.filePath = filePath
        self.language = language
        self.xcodePath = xcodePath
        self.semanticDepth = semanticDepth
        self.xcodeThemeName = xcodeThemeName ?? (appearanceName == "light" ? "default-light" : "default-dark")
        self.appearance = appearanceName == "light" ? .light : .dark
        self.appearanceName = appearanceName
        self.pretty = pretty
        self.includeText = includeText
        self.includeMatches = includeMatches
    }
}
