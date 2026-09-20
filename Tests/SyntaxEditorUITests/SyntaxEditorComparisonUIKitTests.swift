#if canImport(UIKit)
import Foundation
import ObservationBridge
import Testing
import UIKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIUIKit
@testable import SyntaxEditorModel

extension SyntaxEditorUITests {
    @Test("Comparison presentations retain the iOS editor, exact text, selection, and undo")
    @MainActor
    func iosComparisonPreservesEditingAcrossPresentations() async throws {
        let source = "let café = \"e\u{301}😀\"\r\n"
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeIOSComparison(original: "old\r\n", context: context)
        defer { closeIOSComparison(window) }
        let editor = view.modifiedEditor
        let parent = try #require(editor.superview)
        #expect(editor.becomeFirstResponder())
        let undo = try #require(editor.undoManager)
        let revision = context.model.textRevision + 1
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let ready = await delivery.values { context.model.textRevision == revision && view.model.changeCount != nil }
        editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editor.insertText("!")
        #expect(await ready.waitUntilValue(true))
        await settleIOSComparison(view)
        let selection = editor.selectedRange
        for presentation: SyntaxEditorComparisonModel.Presentation in [.changeMarkers, .sideBySide, .changeMarkers] {
            try await changeIOSComparison(view, to: presentation)
            #expect(view.modifiedEditor === editor)
            #expect(editor.superview === parent)
            #expect(editor.undoManager === undo)
            #expect(editor.isFirstResponder)
            #expect(editor.selectedRange == selection)
            #expect(editor.text.utf16.elementsEqual((source + "!").utf16))
            #expect(context.model.text.utf16.elementsEqual((source + "!").utf16))
            #expect(undo.canUndo)
        }
        undo.undo()
        #expect(editor.text.utf16.elementsEqual(source.utf16))
        #expect(context.model.text.utf16.elementsEqual(source.utf16))
        undo.redo()
        #expect(editor.text.utf16.elementsEqual((source + "!").utf16))
    }

    @Test("Comparison presentation switches preserve iOS marked text through commit and undo")
    @MainActor
    func iosComparisonPreservesMarkedText() async throws {
        let source = "current: "
        let context = SyntaxEditorTestContext(text: source, language: .plainText)
        let (view, window) = try await makeIOSComparison(original: "reference", context: context)
        defer { closeIOSComparison(window) }
        let editor = view.modifiedEditor
        #expect(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
        let revision = context.model.textRevision + 1
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let ready = await delivery.values { context.model.textRevision == revision && view.model.changeCount != nil }
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        #expect(await ready.waitUntilValue(true))
        await settleIOSComparison(view)
        let marked = try #require(editor.markedTextRange as? SyntaxEditorView.TextRange).nsRange
        let selection = editor.selectedRange
        for presentation: SyntaxEditorComparisonModel.Presentation in [.sideBySide, .changeMarkers] {
            try await changeIOSComparison(view, to: presentation)
            #expect((editor.markedTextRange as? SyntaxEditorView.TextRange)?.nsRange == marked)
            #expect(editor.selectedRange == selection)
            #expect(editor.text == source + "かな")
            #expect(editor.isFirstResponder)
        }
        editor.insertText("仮名")
        #expect(editor.markedTextRange == nil)
        #expect(context.model.text == source + "仮名")
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(context.model.text == source)
    }

    @Test("UIKit comparison rulers mark empty documents and EOF boundaries")
    @MainActor
    func iosComparisonMarksDocumentBoundaries() async throws {
        for (original, source, referenceBoundary) in [
            ("a\nb\n", "a\n", false), ("a\r\nb\r\n", "a\r\n", false),
            ("removed\n", "", false), ("a\n", "a\nb\n", true), ("", "added\n", true)
        ] {
            let context = SyntaxEditorTestContext(text: source, language: .plainText)
            let (view, window) = try await makeIOSComparison(original: original, context: context)
            defer { closeIOSComparison(window) }
            try await changeIOSComparison(view, to: referenceBoundary ? .sideBySide : .changeMarkers)
            let ruler = referenceBoundary ? view.originalLayout.rulerView : view.modifiedLayout.rulerView
            let pixels = try iosComparisonPixels(size: ruler.bounds.size) { ruler.draw(ruler.bounds) }
            let hasMarker = (0..<pixels.height).contains { y in
                let color = pixels.color(x: Int(ruler.bounds.width) - 4, y: y)
                return referenceBoundary
                    ? color.green > color.red + 0.15 && color.green > color.blue + 0.15
                    : color.red > color.green + 0.15 && color.red > color.blue + 0.15
            }
            #expect(hasMarker, "original: \(original.debugDescription), modified: \(source.debugDescription)")
        }
    }

    @Test("UIKit comparison backgrounds distinguish row and intraline edits without coloring a deletion boundary")
    @MainActor
    func iosComparisonDrawsRowAndIntralineBackgrounds() async throws {
        for deletion in [false, true] {
            let context = SyntaxEditorTestContext(text: deletion ? "before\nafter\n" : "let value = 2\n", language: .plainText)
            let (view, window) = try await makeIOSComparison(
                original: deletion ? "before\nremoved\nafter\n" : "let value = 1\n", context: context
            )
            defer { closeIOSComparison(window) }
            try await changeIOSComparison(view, to: .sideBySide)
            let editor = view.modifiedEditor
            let target = deletion ? "before\n".utf16.count : 0
            let surface = try #require(editor.textContentView.subviews.compactMap {
                $0 as? SyntaxEditorView.TextLayoutFragmentView
            }.first { editor.textSystem.utf16Range(for: $0.layoutFragment).location == target })
            let pixels = try iosComparisonPixels(size: surface.bounds.size) {
                UIColor.white.setFill()
                UIRectFill(surface.bounds)
                view.modifiedLayout.drawBackground(for: surface.layoutFragment, surfaceOrigin: surface.frame.origin,
                                                   in: surface.bounds, dirtyRect: surface.bounds)
            }
            let differences = (0..<pixels.height).flatMap { y in
                (0..<pixels.width).map { x -> CGFloat in
                    let color = pixels.color(x: x, y: y)
                    return color.green - color.red
                }
            }
            if deletion {
                #expect(differences.allSatisfy { abs($0) < 0.01 })
            } else {
                #expect(differences.contains { $0 > 0.02 && $0 < 0.09 })
                #expect(differences.contains { $0 > 0.1 })
            }
        }
    }

    @Test("UIKit comparison preserves client scroll delegates and fixed ruler placement")
    @MainActor
    func iosComparisonPreservesScrollDelegatesAndInsets() async throws {
        let text = (0..<180).map { "line \($0) " + String(repeating: "word ", count: 12) + "\n" }.joined()
        let context = SyntaxEditorTestContext(text: text, language: .plainText, lineWrappingEnabled: true)
        let (view, window) = try await makeIOSComparison(original: "old heading\n" + text, context: context)
        defer { closeIOSComparison(window) }
        let delegate = ComparisonScrollDelegate()
        let editor = view.modifiedEditor
        editor.delegate = delegate
        editor.contentInset = UIEdgeInsets(top: 23, left: 11, bottom: 47, right: 9)
        try await changeIOSComparison(view, to: .sideBySide)
        layoutIOSComparison(view)
        #expect(editor.delegate === delegate)
        #expect(!view.originalEditor.isEditable)
        #expect(view.modifiedLayout.rulerView.frame.maxX == editor.frame.minX)
        #expect(view.originalLayout.rulerView.frame.maxX == view.originalEditor.frame.minX)
        let rulerFrame = view.modifiedLayout.rulerView.frame
        editor.contentOffset = CGPoint(x: -editor.adjustedContentInset.left, y: 600)
        editor.layoutIfNeeded()
        #expect(delegate.scrollCount > 0)
        #expect(view.modifiedLayout.rulerView.frame == rulerFrame)
        #expect(editor.text == text)
        #expect(editor.textContainer.size.width <= editor.bounds.width - editor.adjustedContentInset.left - editor.adjustedContentInset.right + 1)
        #expect(view.modifiedLayout.rulerView.isUserInteractionEnabled)
        #expect(editor.hitTest(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), with: nil) === editor)
    }

    @Test("UIKit comparison rebinding retains native editors and discards old ranges")
    @MainActor
    func iosComparisonRebindsNativeEditors() async throws {
        let context = SyntaxEditorTestContext(text: "current\n" + String(repeating: "value\n", count: 200), language: .plainText)
        let (view, window) = try await makeIOSComparison(original: "reference\n" + String(repeating: "old\n", count: 200), context: context)
        defer { closeIOSComparison(window) }
        try await changeIOSComparison(view, to: .sideBySide)
        let current = view.modifiedEditor
        let original = view.originalEditor
        let nextDocument = SyntaxEditorModel(text: "y", language: .plainText, fontSizeDelta: 4)
        let next = SyntaxEditorComparisonModel(originalText: "x", modified: nextDocument, presentation: .sideBySide)
        await next.calculation?.value
        view.update(model: next)
        layoutIOSComparison(view)
        #expect(view.modifiedEditor === current)
        #expect(view.originalEditor === original)
        #expect(current.model === nextDocument)
        #expect(current.text == "y")
        #expect(original.text == "x")
        #expect(!original.isEditable)
        #expect(view.modifiedLayout.changes == next.changes)
    }

    @Test("Transparent UIKit comparisons keep their rulers transparent")
    @MainActor
    func iosComparisonRulersRespectTransparentBackgrounds() async throws {
        let context = SyntaxEditorTestContext(text: "current\n", language: .plainText)
        context.model.drawsBackground = false
        let (view, window) = try await makeIOSComparison(original: "reference\n", context: context)
        defer { closeIOSComparison(window) }
        try await changeIOSComparison(view, to: .sideBySide)
        for ruler in [view.modifiedLayout.rulerView, view.originalLayout.rulerView] {
            let pixels = try iosComparisonPixels(size: ruler.bounds.size) { ruler.draw(ruler.bounds) }
            #expect(pixels.color(x: 25, y: pixels.height - 10).alpha == 0)
        }
    }

    @MainActor
    private func iosComparisonPixels(size: CGSize, draw: () -> Void) throws -> ComparisonPixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in draw() }
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let succeeded = unsafe bytes.withUnsafeMutableBytes { buffer in
            guard let context = unsafe CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(succeeded)
        return ComparisonPixels(bytes: bytes, width: width, height: height)
    }

    @MainActor
    private func makeIOSComparison(original: String, context: SyntaxEditorTestContext) async throws -> (SyntaxEditorComparisonView, UIWindow) {
        let model = SyntaxEditorComparisonModel(originalText: original, modified: context.model, presentation: .changeMarkers)
        let calculation = try #require(model.calculation)
        await calculation.value
        _ = try #require(model.changeCount)
        let view = SyntaxEditorComparisonView(model: model)
        let window = attachIOSComparison(view)
        await settleIOSComparison(view)
        return (view, window)
    }

    @MainActor
    private func attachIOSComparison(_ view: SyntaxEditorComparisonView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 720, height: 420))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        view.frame = controller.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        window.updateTraitsIfNeeded()
        layoutIOSComparison(view)
        return window
    }

    @MainActor
    private func closeIOSComparison(_ window: UIWindow) {
        window.rootViewController?.view.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private func layoutIOSComparison(_ view: SyntaxEditorComparisonView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.modifiedEditor.setNeedsLayout()
        view.modifiedEditor.layoutIfNeeded()
        if !view.originalEditor.isHidden {
            view.originalEditor.setNeedsLayout()
            view.originalEditor.layoutIfNeeded()
        }
    }

    @MainActor
    private func settleIOSComparison(_ view: SyntaxEditorComparisonView) async {
        _ = await view.originalEditor.waitForPendingHighlightForTesting()
        _ = await view.modifiedEditor.waitForPendingHighlightForTesting()
        await view.waitForPendingComparisonRefreshForTesting()
        layoutIOSComparison(view)
    }

    @MainActor
    private func changeIOSComparison(_ view: SyntaxEditorComparisonView, to presentation: SyntaxEditorComparisonModel.Presentation) async throws {
        let delivery = try #require(view.comparisonDeliveryForTesting)
        let values = await delivery.values { view.model.presentation }
        view.model.presentation = presentation
        #expect(await values.waitUntilValue(presentation))
        await view.waitForPendingComparisonRefreshForTesting {
            view.displayedPresentationForTesting == presentation
        }
        await settleIOSComparison(view)
    }

}

@MainActor
private final class ComparisonScrollDelegate: NSObject, UIScrollViewDelegate {
    var scrollCount = 0
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollCount += 1 }
}

private struct ComparisonPixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    func color(x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let index = (y * width + x) * 4
        return (CGFloat(bytes[index]) / 255, CGFloat(bytes[index + 1]) / 255,
                CGFloat(bytes[index + 2]) / 255, CGFloat(bytes[index + 3]) / 255)
    }
}
#endif
