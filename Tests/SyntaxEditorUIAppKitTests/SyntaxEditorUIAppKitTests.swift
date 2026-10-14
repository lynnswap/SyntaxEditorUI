#if canImport(AppKit)
import AppKit
import Testing
import SyntaxEditorUI
import SyntaxEditorUITestSupport
@testable import SyntaxEditorUIAppKit

@MainActor
struct SyntaxEditorUIAppKitTests {
    @Test("SyntaxEditorUIAppKit exposes the AppKit editor surface")
    func exposesAppKitEditorSurface() {
        let context = SyntaxEditorUITestContext(text: "let value = 1")
        let editorView = SyntaxEditorView(model: context.model)
        #expect(type(of: editorView).superclass() == NSScrollView.self)
        #expect(editorView.text == "let value = 1")
    }
}
#endif
