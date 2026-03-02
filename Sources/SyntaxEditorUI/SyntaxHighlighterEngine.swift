import Foundation
import SwiftTreeSitter
import TreeSitterCSS
import TreeSitterJavaScript
import TreeSitterJSON

struct SyntaxHighlightToken {
    let range: NSRange
    let captureName: String
}

private struct SyntaxLanguageRegistry {
    let configurations: [SyntaxLanguage: LanguageConfiguration]

    static let shared = SyntaxLanguageRegistry()

    init() {
        var map: [SyntaxLanguage: LanguageConfiguration] = [:]
        let cssLanguage = unsafe Language(tree_sitter_css())
        let javaScriptLanguage = unsafe Language(tree_sitter_javascript())
        let jsonLanguage = unsafe Language(tree_sitter_json())

        if let config = Self.makeConfiguration(
            language: cssLanguage,
            name: "CSS",
            bundleName: "TreeSitterCSS_TreeSitterCSS"
        ) {
            map[.css] = config
        }
        if let config = Self.makeConfiguration(
            language: javaScriptLanguage,
            name: "JavaScript",
            bundleName: "TreeSitterJavaScript_TreeSitterJavaScript"
        ) {
            map[.javascript] = config
        }
        if let config = Self.makeConfiguration(
            language: jsonLanguage,
            name: "JSON",
            bundleName: "TreeSitterJSON_TreeSitterJSON"
        ) {
            map[.json] = config
        }

        self.configurations = map
    }

    func configuration(for language: SyntaxLanguage) -> LanguageConfiguration? {
        configurations[language]
    }
}

private extension SyntaxLanguageRegistry {
    static func makeConfiguration(
        language: Language,
        name: String,
        bundleName: String
    ) -> LanguageConfiguration? {
        for queriesURL in queryDirectoryCandidates(for: bundleName) {
            if let configuration = try? LanguageConfiguration(
                language,
                name: name,
                queriesURL: queriesURL
            ), configuration.queries[.highlights] != nil {
                return configuration
            }
        }
        return nil
    }

    static func queryDirectoryCandidates(for bundleName: String) -> [URL] {
        let bundleFilename = "\(bundleName).bundle"
        var roots: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL)
        }
        roots.append(Bundle.main.bundleURL)

        roots.append(contentsOf: Bundle.allBundles.map(\.bundleURL))
        roots.append(contentsOf: Bundle.allFrameworks.map(\.bundleURL))

        var seen = Set<String>()
        var uniqueRoots: [URL] = []
        for root in roots {
            for candidate in searchRoots(from: root) {
                if seen.insert(candidate.path).inserted {
                    uniqueRoots.append(candidate)
                }
            }
        }

        var candidates: [URL] = []
        let fileManager = FileManager.default

        for root in uniqueRoots {
            let bundleURL = root.appendingPathComponent(bundleFilename, isDirectory: true)
            let queryDirectories = [
                bundleURL.appendingPathComponent("queries", isDirectory: true),
                bundleURL.appendingPathComponent("Contents/Resources/queries", isDirectory: true),
            ]

            for directory in queryDirectories {
                if fileManager.fileExists(atPath: directory.path) {
                    candidates.append(directory)
                }
            }
        }

        return candidates
    }

    static func searchRoots(from root: URL) -> [URL] {
        var result: [URL] = []
        var currentURL: URL? = root.standardizedFileURL

        for _ in 0..<6 {
            guard let current = currentURL else { break }
            result.append(current)

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                break
            }
            currentURL = parent
        }

        return result
    }
}

actor SyntaxHighlighterEngine {
    private let parser = Parser()
    private let registry = SyntaxLanguageRegistry.shared

    func render(source: String, language: SyntaxLanguage) -> [SyntaxHighlightToken] {
        guard !source.isEmpty else { return [] }
        guard let configuration = registry.configuration(for: language) else { return [] }
        guard let highlightsQuery = configuration.queries[.highlights] else { return [] }

        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return []
        }

        guard let tree = parser.parse(source) else { return [] }

        let cursor = highlightsQuery.execute(in: tree)
        let highlights = cursor
            .resolve(with: .init(string: source))
            .highlights()

        let sourceUTF16Length = source.utf16.count
        return highlights.compactMap {
            guard let range = Self.utf16Range(
                fromByteRange: $0.tsRange.bytes,
                sourceUTF16Length: sourceUTF16Length
            ) else {
                return nil
            }
            return SyntaxHighlightToken(range: range, captureName: $0.name)
        }
    }

    // SwiftTreeSitter parses String input as UTF-16 by default, so byte offsets map
    // to UTF-16 offsets by dividing by 2.
    private static func utf16Range(
        fromByteRange byteRange: Range<UInt32>,
        sourceUTF16Length: Int
    ) -> NSRange? {
        guard byteRange.lowerBound % 2 == 0, byteRange.upperBound % 2 == 0 else {
            return nil
        }

        let start = Int(byteRange.lowerBound / 2)
        let end = Int(byteRange.upperBound / 2)
        guard start <= end, end <= sourceUTF16Length else {
            return nil
        }

        return NSRange(location: start, length: end - start)
    }
}
