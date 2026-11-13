import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport

package struct PlainTextLanguage: SyntaxLanguageSupport {
    package init() {}

    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? { nil }

    package func toggleComment(source: String, selection: NSRange) -> SyntaxLanguage.EditResult? {
        nil
    }

    package func isInsideLiteralOrComment(source: String, location: Int) -> Bool {
        false
    }
}
