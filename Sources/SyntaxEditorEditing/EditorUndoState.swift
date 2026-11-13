import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguages

extension EditorCommandEngine {
package struct UndoState: Equatable {
    package let edits: [SyntaxEditorTextChange.Replacement]
    package let selectedRange: NSRange

    package init(edits: [SyntaxEditorTextChange.Replacement], selectedRange: NSRange) {
        self.edits = edits
        self.selectedRange = selectedRange
    }
}
}
