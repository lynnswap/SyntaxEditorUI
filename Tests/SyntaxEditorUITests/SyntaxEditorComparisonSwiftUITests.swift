import Foundation
import SwiftUI
import ObservationBridge
import Testing
@testable import SyntaxEditorUI
@testable import SyntaxEditorModel

#if canImport(UIKit)
import UIKit
@testable import SyntaxEditorUIUIKit
#elseif canImport(AppKit)
import AppKit
@testable import SyntaxEditorUIAppKit
#endif

extension SyntaxEditorUITests {
    @Test("SwiftUI comparison updates retain the native editor, text, selection, and undo")
    @MainActor
    func swiftUIComparisonPreservesNativeEditor() async throws {
        let document = SyntaxEditorModel(text: "current e\u{301}😀\r\n", language: .plainText)
        let model = SyntaxEditorComparisonModel(originalText: "old\r\n", modified: document)
        await model.calculation?.value
        let fixture = ComparisonSwiftUIFixture(model: model)
        defer { fixture.close() }
        let comparison = try #require(fixture.comparisonView())
        let editor = comparison.modifiedEditor
        let parent = try #require(editor.superview)
        let source = document.text
        let end = NSRange(location: source.utf16.count, length: 0)
        #if canImport(UIKit)
        editor.selectedRange = end
        editor.insertText("!")
        let undo = try #require(editor.undoManager)
        #else
        let undo = try #require(editor.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.textView.setSelectedRange(end)
        editor.textView.insertText("!", replacementRange: end)
        editor.textView.breakUndoCoalescing()
        undo.endUndoGrouping()
        #endif
        let selection = editor.selectedRange
        let delivery = try #require(comparison.comparisonDeliveryForTesting)
        let modes = await delivery.values { model.presentation }

        for mode: SyntaxEditorComparisonModel.Presentation in [.changeMarkers, .sideBySide, .inline] {
            model.presentation = mode
            fixture.update(model: model)
            #expect(await modes.waitUntilValue(mode))
            await comparison.waitForPendingComparisonRefreshForTesting {
                comparison.displayedPresentationForTesting == mode
            }
            #expect(fixture.comparisonView() === comparison)
            #expect(comparison.modifiedEditor === editor)
            #expect(editor.superview === parent)
            #expect(editor.selectedRange == selection)
            #expect(document.text.utf16.elementsEqual((source + "!").utf16))
            #expect(undo.canUndo)
        }

        undo.undo()
        #expect(document.text.utf16.elementsEqual(source.utf16))
        undo.redo()
        #expect(document.text.utf16.elementsEqual((source + "!").utf16))
    }

    @Test("SwiftUI comparison rebinding keeps the view and installs the new models")
    @MainActor
    func swiftUIComparisonRebindsNativeView() async throws {
        let document = SyntaxEditorModel(text: "first", language: .plainText)
        let initial = SyntaxEditorComparisonModel(originalText: "original first", modified: document)
        await initial.calculation?.value
        let fixture = ComparisonSwiftUIFixture(model: initial)
        defer { fixture.close() }
        let comparison = try #require(fixture.comparisonView())
        let editor = comparison.modifiedEditor
        #if canImport(UIKit)
        editor.insertText("!")
        let undo = try #require(editor.undoManager)
        #else
        let undo = try #require(editor.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        editor.textView.breakUndoCoalescing()
        undo.endUndoGrouping()
        #endif
        #expect(undo.canUndo)
        let replacement = SyntaxEditorModel(text: "second", language: .plainText)
        let next = SyntaxEditorComparisonModel(originalText: "original second", modified: replacement, presentation: .sideBySide)
        await next.calculation?.value

        fixture.update(model: next)

        let updated = try #require(fixture.comparisonView())
        #expect(updated === comparison)
        #expect(updated.model === next)
        #expect(updated.modifiedEditor === editor)
        #expect(editor.model === replacement)
        #expect(editor.text == "second")
        #expect(updated.originalEditor.text == "original second")
        #expect(!undo.canUndo)
    }
}

@MainActor
private final class ComparisonSwiftUIFixture {
    #if canImport(UIKit)
    let host: UIHostingController<SyntaxEditorComparison>
    let window: UIWindow
    #else
    let host: NSHostingView<SyntaxEditorComparison>
    let window: NSWindow
    #endif

    init(model: SyntaxEditorComparisonModel) {
        #if canImport(UIKit)
        host = UIHostingController(rootView: SyntaxEditorComparison(model))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 720, height: 420))
        window.rootViewController = host
        host.loadViewIfNeeded()
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        #else
        host = NSHostingView(rootView: SyntaxEditorComparison(model))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 420),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        #endif
        layout()
    }

    func update(model: SyntaxEditorComparisonModel) {
        host.rootView = SyntaxEditorComparison(model)
        layout()
    }

    func close() {
        #if canImport(UIKit)
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        #else
        window.orderOut(nil)
        window.contentView = nil
        #endif
    }

    private func layout() {
        #if canImport(UIKit)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #else
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #endif
    }

    func comparisonView() -> SyntaxEditorComparisonView? {
        #if canImport(UIKit)
        return findComparison(in: host.view)
        #else
        return findComparison(in: host)
        #endif
    }

    #if canImport(UIKit)
    private func findComparison(in view: UIView) -> SyntaxEditorComparisonView? {
        if let comparison = view as? SyntaxEditorComparisonView { return comparison }
        for child in view.subviews {
            if let comparison = findComparison(in: child) { return comparison }
        }
        return nil
    }
    #else
    private func findComparison(in view: NSView) -> SyntaxEditorComparisonView? {
        if let comparison = view as? SyntaxEditorComparisonView { return comparison }
        for child in view.subviews {
            if let comparison = findComparison(in: child) { return comparison }
        }
        return nil
    }
    #endif
}
