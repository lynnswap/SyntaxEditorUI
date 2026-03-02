import Foundation

struct EditorUndoState: Equatable {
    let text: String
    let selectedRange: NSRange
    let refreshStartUTF16: Int
}
