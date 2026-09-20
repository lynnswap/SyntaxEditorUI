import SwiftUI
import Testing
import SyntaxEditorUITestSupport
@testable import SyntaxEditorUISwiftUI

@MainActor
struct SyntaxEditorUISwiftUITests {
    @Test("SyntaxEditorUISwiftUI exposes the comparison wrapper")
    func exposesComparisonWrapper() {
        let context = SyntaxEditorUITestContext(text: "let value = 1")
        let comparison = SyntaxEditorComparison(.init(originalText: "old", modified: context.model))
        #expect(String(describing: type(of: comparison)) == "SyntaxEditorComparison")
    }

    @Test("SyntaxEditorUISwiftUI exposes the SwiftUI wrapper")
    func exposesSwiftUIWrapper() {
        let context = SyntaxEditorUITestContext(text: "let value = 1")
        let editor = SyntaxEditor(context.model)
        #expect(String(describing: type(of: editor)) == "SyntaxEditor")
    }
}
