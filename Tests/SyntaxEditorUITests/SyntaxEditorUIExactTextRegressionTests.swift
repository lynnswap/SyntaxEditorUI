import Foundation
import ObservationBridge
import Testing
@testable import SyntaxEditorUI

#if canImport(UIKit)
import UIKit
@testable import SyntaxEditorUIUIKit
#elseif canImport(AppKit)
import AppKit
@testable import SyntaxEditorUIAppKit
#endif

extension SyntaxEditorUITests {
    @Test("Editor model and text storage preserve normalization-only replacements")
    @MainActor
    func exactUnicodeTextReplacements() async throws {
        let context = SyntaxEditorTestContext(text: "é\n", language: .plainText)
        let editor = SyntaxEditorView(testContext: context, highlighter: SyntaxEditorUITestHighlighter())
        let delivery = try #require(editor.modelDeliveryForTesting)
        let rendered = await delivery.values { Array(editor.text.utf16) }

        context.model.text = "e\u{301}\n"
        #expect(await rendered.waitUntilValue(Array("e\u{301}\n".utf16)))
        #expect(context.model.textRevision == 1)

        editor.text = "é\n"
        #expect(editor.text.utf16.elementsEqual("é\n".utf16))
        #expect(context.model.text.utf16.elementsEqual("é\n".utf16))
        #expect(context.model.textRevision == 2)
    }

    @Test("User input preserves normalization-only replacements")
    @MainActor
    func exactUnicodeInputReplacement() async {
        let context = SyntaxEditorTestContext(text: "é", language: .plainText)
        let editor = SyntaxEditorView(testContext: context, highlighter: SyntaxEditorUITestHighlighter())
        #if canImport(UIKit)
        editor.selectedRange = NSRange(location: 0, length: 1)
        editor.insertText("e\u{301}")
        #elseif canImport(AppKit)
        editor.textView.insertText("e\u{301}", replacementRange: NSRange(location: 0, length: 1))
        #endif
        #expect(editor.text.utf16.elementsEqual("e\u{301}".utf16))
        #expect(context.model.text.utf16.elementsEqual("e\u{301}".utf16))
        #expect(context.model.textRevision == 1)
    }
}
