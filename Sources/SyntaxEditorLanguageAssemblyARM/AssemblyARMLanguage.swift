import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter
import TreeSitterAsm

package struct AssemblyARMLanguage: SyntaxLanguageSupport {
    package init() {}

    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? {
        SyntaxLanguageTreeSitterSupport(
            name: "AssemblyARM",
            bundleName: "TreeSitterAsm_TreeSitterAsm",
            queryDirectories: BundledLanguageQueryResources.directories(
                in: .module,
                named: "AssemblyARMQueries"
            ),
            makeLanguage: { unsafe Language(tree_sitter_asm()) }
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
        let text = source as NSString
        let limit = min(max(0, location), text.length)
        var cursor = 0
        var quote: unichar?
        var inLineComment = false
        var inBlockComment = false
        var escaped = false

        while cursor < limit {
            let current = text.character(at: cursor)
            let next = cursor + 1 < limit ? text.character(at: cursor + 1) : nil
            if inLineComment {
                if current == 10 || current == 13 {
                    inLineComment = false
                }
            } else if inBlockComment {
                if current == 42 && next == 47 {
                    inBlockComment = false
                    cursor += 1
                }
            } else if let delimiter = quote {
                if escaped {
                    escaped = false
                } else if current == 92 {
                    escaped = true
                } else if current == delimiter {
                    quote = nil
                }
            } else if current == 47 && next == 42 {
                inBlockComment = true
                cursor += 1
            } else if current == 59 || (current == 47 && next == 47) {
                inLineComment = true
            } else if current == 34 || current == 39 {
                quote = current
            }
            cursor += 1
        }

        return quote != nil || inLineComment || inBlockComment
    }
}
