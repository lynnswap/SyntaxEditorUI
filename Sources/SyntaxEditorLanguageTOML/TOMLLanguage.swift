import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter
import TreeSitterTOML

package struct TOMLLanguage: SyntaxLanguageSupport {
    package init() {}

    package var language: SyntaxLanguage { .toml }
    package var displayName: String { "TOML" }
    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? {
        SyntaxLanguageTreeSitterSupport(
            name: "TOML",
            bundleName: "TreeSitterTOML_TreeSitterTOML",
            queryDirectories: Self.queryDirectories,
            makeLanguage: { unsafe Language(tree_sitter_toml()) }
        )
    }

    package func toggleComment(source: String, selection: NSRange) -> SyntaxLanguage.EditResult? {
        SyntaxLanguageTextUtilities.toggleLineComment(
            source: source,
            selection: selection,
            commentPrefix: "#"
        )
    }

    package func isInsideLiteralOrComment(source: String, location: Int) -> Bool {
        let nsSource = source as NSString
        let clampedLocation = max(0, min(location, nsSource.length))
        var analysis = PrefixAnalysis()
        var cursor = 0
        PrefixAnalyzer.advance(&analysis, in: nsSource, cursor: &cursor, limit: clampedLocation)
        return analysis.isInsideLiteralOrComment
    }
}

private extension TOMLLanguage {
    static var queryDirectories: [URL] {
        BundledLanguageQueryResources.directories(in: .module, named: "TOMLQueries")
    }

    struct PrefixAnalysis {
        var inLineComment = false
        var inBasicString = false
        var inMultilineBasicString = false
        var inLiteralString = false
        var inMultilineLiteralString = false
        var isEscaped = false

        var isInsideLiteralOrComment: Bool {
            inLineComment || inBasicString || inMultilineBasicString || inLiteralString || inMultilineLiteralString
        }
    }

    enum PrefixAnalyzer {
        /// `limit` is treated as the end of the analyzed text: lookahead never
        /// reads past it, matching what analyzing a prefix substring would see.
        static func advance(
            _ analysis: inout PrefixAnalysis,
            in source: NSString,
            cursor: inout Int,
            limit: Int
        ) {
            let upperBound = max(0, min(limit, source.length))
            let singleQuote: unichar = 39
            let doubleQuote: unichar = 34
            let backslash: unichar = 92
            let hash: unichar = 35
            let newline: unichar = 10
            let carriageReturn: unichar = 13

            while cursor < upperBound {
                let codeUnit = source.character(at: cursor)

                if analysis.inLineComment {
                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inLineComment = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inMultilineBasicString {
                    if analysis.isEscaped {
                        analysis.isEscaped = false
                        cursor += 1
                        continue
                    }

                    if codeUnit == backslash {
                        analysis.isEscaped = true
                        cursor += 1
                        continue
                    }

                    if closesMultilineString(in: source, at: cursor, quote: doubleQuote, end: upperBound) {
                        analysis.inMultilineBasicString = false
                        cursor += 3
                        continue
                    }

                    cursor += 1
                    continue
                }

                if analysis.inBasicString {
                    if analysis.isEscaped {
                        if codeUnit == newline || codeUnit == carriageReturn {
                            analysis.isEscaped = false
                            analysis.inBasicString = false
                            cursor += 1
                            continue
                        }

                        analysis.isEscaped = false
                        cursor += 1
                        continue
                    }

                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inBasicString = false
                        cursor += 1
                        continue
                    }

                    if codeUnit == backslash {
                        analysis.isEscaped = true
                        cursor += 1
                        continue
                    }

                    if codeUnit == doubleQuote {
                        analysis.inBasicString = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inMultilineLiteralString {
                    if closesMultilineString(in: source, at: cursor, quote: singleQuote, end: upperBound) {
                        analysis.inMultilineLiteralString = false
                        cursor += 3
                        continue
                    }

                    cursor += 1
                    continue
                }

                if analysis.inLiteralString {
                    if codeUnit == newline || codeUnit == carriageReturn {
                        analysis.inLiteralString = false
                    } else if codeUnit == singleQuote {
                        analysis.inLiteralString = false
                    }
                    cursor += 1
                    continue
                }

                if codeUnit == hash {
                    analysis.inLineComment = true
                    cursor += 1
                    continue
                }

                if hasTripleQuote(in: source, at: cursor, quote: doubleQuote, end: upperBound) {
                    analysis.inMultilineBasicString = true
                    cursor += 3
                    continue
                }

                if hasTripleQuote(in: source, at: cursor, quote: singleQuote, end: upperBound) {
                    analysis.inMultilineLiteralString = true
                    cursor += 3
                    continue
                }

                if codeUnit == doubleQuote {
                    analysis.inBasicString = true
                    cursor += 1
                    continue
                }

                if codeUnit == singleQuote {
                    analysis.inLiteralString = true
                    cursor += 1
                    continue
                }

                cursor += 1
            }
        }

        static func hasTripleQuote(in source: NSString, at offset: Int, quote: unichar, end: Int) -> Bool {
            guard offset >= 0, offset + 2 < end else { return false }
            return source.character(at: offset) == quote &&
                source.character(at: offset + 1) == quote &&
                source.character(at: offset + 2) == quote
        }

        static func closesMultilineString(in source: NSString, at offset: Int, quote: unichar, end: Int) -> Bool {
            guard hasTripleQuote(in: source, at: offset, quote: quote, end: end) else {
                return false
            }

            let nextOffset = offset + 3
            guard nextOffset < end else {
                return true
            }

            return source.character(at: nextOffset) != quote
        }
    }
}
