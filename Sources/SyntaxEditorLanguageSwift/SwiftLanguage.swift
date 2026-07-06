import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter
import TreeSitterSwift

package struct SwiftLanguage: SyntaxLanguageSupport {
    package init() {}

    package var language: SyntaxLanguage { .swift }
    package var displayName: String { "Swift" }
    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? {
        SyntaxLanguageTreeSitterSupport(
            name: "Swift",
            bundleName: "TreeSitterSwift_TreeSitterSwift",
            queryDirectories: Self.queryDirectories,
            makeLanguage: { unsafe Language(tree_sitter_swift()) }
        )
    }

    package func toggleComment(source: String, selection: NSRange) -> SyntaxLanguage.EditResult? {
        SyntaxLanguageTextUtilities.toggleLineComment(
            source: source,
            selection: selection,
            commentPrefix: "//"
        )
    }

    package func isInsideLiteralOrComment(source: String, location: Int) -> Bool {
        let nsSource = source as NSString
        let clampedLocation = max(0, min(location, nsSource.length))
        return PrefixAnalyzer.analysis(of: nsSource, upTo: clampedLocation).isInsideLiteralOrComment
    }
}

private extension SwiftLanguage {
    static var queryDirectories: [URL] {
        BundledLanguageQueryResources.directories(in: .module, named: "SwiftQueries")
    }
}

private extension SwiftLanguage {
    struct PrefixAnalysis {
        var inLineComment = false
        var blockCommentDepth = 0
        var inStringLiteralText = false

        var isInsideLiteralOrComment: Bool {
            inLineComment || blockCommentDepth > 0 || inStringLiteralText
        }
    }

    struct StringStart {
        let hashCount: Int
        let isMultiline: Bool
        let openerLength: Int
    }

    struct StringContext {
        let hashCount: Int
        let isMultiline: Bool
        var isEscaped = false
    }

    enum LexicalContext {
        case string(StringContext)
        case interpolation(parenDepth: Int)
    }

    enum PrefixAnalyzer {
        /// Analyzes `source` up to `limit`, treating `limit` as the end of the
        /// text: lookahead never reads past it, matching what analyzing a
        /// prefix substring would see.
        static func analysis(of source: NSString, upTo limit: Int) -> PrefixAnalysis {
            let end = max(0, min(limit, source.length))
            var contexts: [LexicalContext] = []
            var inLineComment = false
            var blockCommentDepth = 0
            var cursor = 0

            let slash: unichar = 47
            let asterisk: unichar = 42
            let backslash: unichar = 92
            let lineFeed: unichar = 10
            let carriageReturn: unichar = 13
            let openParen: unichar = 40
            let closeParen: unichar = 41

            while cursor < end {
                let codeUnit = source.character(at: cursor)
                let nextCodeUnit: unichar? = cursor + 1 < end ? source.character(at: cursor + 1) : nil

                if inLineComment {
                    if codeUnit == lineFeed || codeUnit == carriageReturn {
                        inLineComment = false
                    }
                    cursor += 1
                    continue
                }

                if blockCommentDepth > 0 {
                    if codeUnit == slash, nextCodeUnit == asterisk {
                        blockCommentDepth += 1
                        cursor += 2
                        continue
                    }

                    if codeUnit == asterisk, nextCodeUnit == slash {
                        blockCommentDepth -= 1
                        cursor += 2
                        continue
                    }

                    cursor += 1
                    continue
                }

                if case .string(var stringContext) = contexts.last {
                    if stringContext.hashCount == 0, stringContext.isEscaped {
                        stringContext.isEscaped = false
                        contexts[contexts.count - 1] = .string(stringContext)
                        cursor += 1
                        continue
                    }

                    if let interpolationLength = Self.interpolationOpenerLength(
                        in: source,
                        at: cursor,
                        hashCount: stringContext.hashCount,
                        end: end
                    ) {
                        contexts.append(.interpolation(parenDepth: 1))
                        cursor += interpolationLength
                        continue
                    }

                    if stringContext.hashCount == 0, codeUnit == backslash {
                        stringContext.isEscaped = true
                        contexts[contexts.count - 1] = .string(stringContext)
                        cursor += 1
                        continue
                    }

                    if let closeLength = Self.stringCloseLength(
                        in: source,
                        at: cursor,
                        context: stringContext,
                        end: end
                    ) {
                        _ = contexts.popLast()
                        cursor += closeLength
                        continue
                    }

                    cursor += 1
                    continue
                }

                if case .interpolation(let parenDepth) = contexts.last {
                    if codeUnit == openParen {
                        contexts[contexts.count - 1] = .interpolation(parenDepth: parenDepth + 1)
                        cursor += 1
                        continue
                    }

                    if codeUnit == closeParen {
                        if parenDepth == 1 {
                            _ = contexts.popLast()
                        } else {
                            contexts[contexts.count - 1] = .interpolation(parenDepth: parenDepth - 1)
                        }
                        cursor += 1
                        continue
                    }
                }

                if codeUnit == slash, nextCodeUnit == slash {
                    inLineComment = true
                    cursor += 2
                    continue
                }

                if codeUnit == slash, nextCodeUnit == asterisk {
                    blockCommentDepth = 1
                    cursor += 2
                    continue
                }

                if let start = Self.stringStart(in: source, at: cursor, end: end) {
                    contexts.append(
                        .string(
                            StringContext(
                                hashCount: start.hashCount,
                                isMultiline: start.isMultiline
                            )
                        )
                    )
                    cursor += start.openerLength
                    continue
                }

                cursor += 1
            }

            var analysis = PrefixAnalysis()
            analysis.inLineComment = inLineComment
            analysis.blockCommentDepth = blockCommentDepth
            if case .string = contexts.last {
                analysis.inStringLiteralText = true
            }
            return analysis
        }

        private static func stringStart(in source: NSString, at offset: Int, end: Int) -> StringStart? {
            guard offset >= 0, offset < end else { return nil }

            let hash: unichar = 35
            let quote: unichar = 34

            var cursor = offset
            var hashCount = 0
            while cursor < end, source.character(at: cursor) == hash {
                hashCount += 1
                cursor += 1
            }

            guard cursor < end, source.character(at: cursor) == quote else {
                return nil
            }

            let isMultiline = cursor + 2 < end &&
                source.character(at: cursor + 1) == quote &&
                source.character(at: cursor + 2) == quote

            let openerLength = hashCount + (isMultiline ? 3 : 1)
            return StringStart(hashCount: hashCount, isMultiline: isMultiline, openerLength: openerLength)
        }

        private static func interpolationOpenerLength(
            in source: NSString,
            at offset: Int,
            hashCount: Int,
            end: Int
        ) -> Int? {
            guard offset >= 0, offset < end else { return nil }

            let backslash: unichar = 92
            let hash: unichar = 35
            let openParen: unichar = 40

            guard source.character(at: offset) == backslash else { return nil }
            var cursor = offset + 1

            for _ in 0..<hashCount {
                guard cursor < end, source.character(at: cursor) == hash else {
                    return nil
                }
                cursor += 1
            }

            guard cursor < end, source.character(at: cursor) == openParen else {
                return nil
            }

            return cursor - offset + 1
        }

        private static func stringCloseLength(
            in source: NSString,
            at offset: Int,
            context: StringContext,
            end: Int
        ) -> Int? {
            guard offset >= 0, offset < end else { return nil }

            let quote: unichar = 34
            let hash: unichar = 35

            if context.isMultiline {
                guard offset + 2 < end,
                      source.character(at: offset) == quote,
                      source.character(at: offset + 1) == quote,
                      source.character(at: offset + 2) == quote
                else {
                    return nil
                }

                var cursor = offset + 3
                for _ in 0..<context.hashCount {
                    guard cursor < end, source.character(at: cursor) == hash else {
                        return nil
                    }
                    cursor += 1
                }
                return cursor - offset
            }

            guard source.character(at: offset) == quote else {
                return nil
            }

            var cursor = offset + 1
            for _ in 0..<context.hashCount {
                guard cursor < end, source.character(at: cursor) == hash else {
                    return nil
                }
                cursor += 1
            }
            return cursor - offset
        }
    }
}
