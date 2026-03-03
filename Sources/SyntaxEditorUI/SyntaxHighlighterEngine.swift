import Foundation
import SwiftTreeSitter
import TreeSitterCSS
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterSwift

struct SyntaxHighlightToken {
    let range: NSRange
    let captureName: String
}

private struct SyntaxLanguageRegistry {
    private struct LanguageSpecification {
        let syntaxLanguage: SyntaxLanguage
        let language: Language
        let name: String
        let bundleName: String
    }

    private struct ResolvedConfiguration {
        let configuration: LanguageConfiguration
        let queriesURL: URL
    }

    let configurations: [SyntaxLanguage: LanguageConfiguration]

    static let shared = SyntaxLanguageRegistry()

    init() {
        var map: [SyntaxLanguage: LanguageConfiguration] = [:]
        let specifications: [LanguageSpecification] = [
            .init(
                syntaxLanguage: .css,
                language: unsafe Language(tree_sitter_css()),
                name: "CSS",
                bundleName: "TreeSitterCSS_TreeSitterCSS"
            ),
            .init(
                syntaxLanguage: .javascript,
                language: unsafe Language(tree_sitter_javascript()),
                name: "JavaScript",
                bundleName: "TreeSitterJavaScript_TreeSitterJavaScript"
            ),
            .init(
                syntaxLanguage: .json,
                language: unsafe Language(tree_sitter_json()),
                name: "JSON",
                bundleName: "TreeSitterJSON_TreeSitterJSON"
            ),
            .init(
                syntaxLanguage: .swift,
                language: unsafe Language(tree_sitter_swift()),
                name: "Swift",
                bundleName: "TreeSitterSwift_TreeSitterSwift"
            ),
        ]

        var resolvedQueryDirectories: [URL] = []

        for specification in specifications {
            if let resolved = Self.makeConfiguration(
                language: specification.language,
                name: specification.name,
                bundleName: specification.bundleName
            ) {
                map[specification.syntaxLanguage] = resolved.configuration
                resolvedQueryDirectories.append(resolved.queriesURL)
            }
        }

        if map.count < specifications.count {
            let bundleContainerDirectories = resolvedQueryDirectories.compactMap {
                Self.bundleContainerDirectory(forQueriesDirectory: $0)
            }

            for specification in specifications where map[specification.syntaxLanguage] == nil {
                let siblingQueryDirectories = bundleContainerDirectories.flatMap { container in
                    let siblingBundle = container
                        .appendingPathComponent("\(specification.bundleName).bundle", isDirectory: true)
                    return [
                        siblingBundle.appendingPathComponent("queries", isDirectory: true),
                        siblingBundle.appendingPathComponent("Contents/Resources/queries", isDirectory: true),
                    ]
                }

                if let resolved = Self.makeConfiguration(
                    language: specification.language,
                    name: specification.name,
                    bundleName: specification.bundleName,
                    additionalQueryDirectories: siblingQueryDirectories
                ) {
                    map[specification.syntaxLanguage] = resolved.configuration
                }
            }
        }

        self.configurations = map
    }

    func configuration(for language: SyntaxLanguage) -> LanguageConfiguration? {
        configurations[language]
    }
}

private extension SyntaxLanguageRegistry {
    private static func makeConfiguration(
        language: Language,
        name: String,
        bundleName: String,
        additionalQueryDirectories: [URL] = []
    ) -> ResolvedConfiguration? {
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        for queriesURL in additionalQueryDirectories + queryDirectoryCandidates(for: bundleName) {
            let standardized = queriesURL.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else {
                continue
            }
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                continue
            }
            candidates.append(standardized)
        }

        for queriesURL in candidates {
            if let configuration = try? LanguageConfiguration(
                language,
                name: name,
                queriesURL: queriesURL
            ), configuration.queries[.highlights] != nil {
                return ResolvedConfiguration(configuration: configuration, queriesURL: queriesURL)
            }
        }
        return nil
    }

    private static func bundleContainerDirectory(forQueriesDirectory queriesURL: URL) -> URL? {
        let components = queriesURL.standardizedFileURL.pathComponents
        guard let bundleComponentIndex = components.lastIndex(where: { $0.hasSuffix(".bundle") }) else {
            return nil
        }

        var bundleContainer = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components[1..<bundleComponentIndex] {
            bundleContainer.appendPathComponent(component, isDirectory: true)
        }
        return bundleContainer.standardizedFileURL
    }

    static func queryDirectoryCandidates(for bundleName: String) -> [URL] {
        let bundleFilename = "\(bundleName).bundle"
        var roots: [URL] = []
        let fileManager = FileManager.default

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
