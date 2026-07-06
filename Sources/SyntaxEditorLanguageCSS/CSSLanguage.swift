import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter
import TreeSitterCSS

package struct CSSLanguage: SyntaxLanguageSupport {
    package init() {}

    package var language: SyntaxLanguage { .css }
    package var displayName: String { "CSS" }
    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? {
        SyntaxLanguageTreeSitterSupport(
            name: "CSS",
            bundleName: "TreeSitterCSS_TreeSitterCSS",
            queryDirectories: Self.queryDirectories,
            makeLanguage: { unsafe Language(tree_sitter_css()) }
        )
    }

    package func toggleComment(source: String, selection: NSRange) -> SyntaxLanguage.EditResult? {
        SyntaxLanguageTextUtilities.toggleWrappedComment(
            source: source,
            selection: selection,
            openMarker: "/*",
            closeMarker: "*/"
        )
    }

    package func isInsideLiteralOrComment(source: String, location: Int) -> Bool {
        let nsSource = source as NSString
        let clampedLocation = max(0, min(location, nsSource.length))
        var analysis = PrefixAnalysis()
        var cursor = 0
        PrefixAnalyzer.advance(
            &analysis,
            in: nsSource,
            cursor: &cursor,
            limit: clampedLocation,
            limitIsEndOfText: true
        )
        return analysis.isInsideLiteralOrComment
    }
}

private extension CSSLanguage {
    static var queryDirectories: [URL] {
        BundledLanguageQueryResources.directories(in: .module, named: "CSSQueries")
    }
}

extension CSSLanguage {
    package struct PrefixAnalysis {
        var inSingleQuote = false
        var inDoubleQuote = false
        var inBlockComment = false
        var isEscaped = false

        package init() {}

        package var isInsideLiteralOrComment: Bool {
            inSingleQuote || inDoubleQuote || inBlockComment
        }
    }

    package enum PrefixAnalyzer {
        /// `limitIsEndOfText` treats `limit` as the end of the analyzed text
        /// (no lookahead past it), matching what analyzing a prefix substring
        /// would see. Leave it `false` for streaming callers that keep
        /// advancing the same cursor with growing limits.
        package static func advance(
            _ analysis: inout PrefixAnalysis,
            in source: NSString,
            cursor: inout Int,
            limit: Int,
            limitIsEndOfText: Bool = false
        ) {
            let upperBound = max(0, min(limit, source.length))
            let lookaheadBound = limitIsEndOfText ? upperBound : source.length
            let singleQuote: unichar = 39
            let doubleQuote: unichar = 34
            let backslash: unichar = 92
            let slash: unichar = 47
            let asterisk: unichar = 42

            while cursor < upperBound {
                let codeUnit = source.character(at: cursor)
                let nextCodeUnit: unichar? = cursor + 1 < lookaheadBound ? source.character(at: cursor + 1) : nil

                if analysis.inBlockComment {
                    if codeUnit == asterisk, nextCodeUnit == slash {
                        analysis.inBlockComment = false
                        cursor += 2
                    } else {
                        cursor += 1
                    }
                    continue
                }

                if analysis.isEscaped {
                    analysis.isEscaped = false
                    cursor += 1
                    continue
                }

                if analysis.inSingleQuote {
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                    } else if codeUnit == singleQuote {
                        analysis.inSingleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if analysis.inDoubleQuote {
                    if codeUnit == backslash {
                        analysis.isEscaped = true
                    } else if codeUnit == doubleQuote {
                        analysis.inDoubleQuote = false
                    }
                    cursor += 1
                    continue
                }

                if codeUnit == slash, nextCodeUnit == asterisk {
                    analysis.inBlockComment = true
                    cursor += 2
                    continue
                }

                if codeUnit == singleQuote {
                    analysis.inSingleQuote = true
                    cursor += 1
                    continue
                }

                if codeUnit == doubleQuote {
                    analysis.inDoubleQuote = true
                    cursor += 1
                    continue
                }

                cursor += 1
            }
        }
    }
}
