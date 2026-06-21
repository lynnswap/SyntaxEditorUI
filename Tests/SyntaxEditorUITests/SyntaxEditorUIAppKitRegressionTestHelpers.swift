#if canImport(AppKit)
import Foundation
import Observation
import ObservationBridge
import SwiftUI
import Testing
import AppKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUIAppKit

extension SyntaxEditorUITests {
    @MainActor
    func layoutMacEditorView(
        _ editorView: SyntaxEditorView,
        width: CGFloat = 220,
        height: CGFloat = 140
    ) {
        editorView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        editorView.needsLayout = true
        editorView.layoutSubtreeIfNeeded()
    }

    func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    @MainActor
    func macUnobscuredContentSize(_ editorView: SyntaxEditorView) -> NSSize {
        let contentInsets = editorView.contentView.contentInsets
        return NSSize(
            width: max(0, editorView.contentSize.width - contentInsets.left - contentInsets.right),
            height: max(0, editorView.contentSize.height - contentInsets.top - contentInsets.bottom)
        )
    }

    @MainActor
    func attachMacEditorWindow(_ editorView: SyntaxEditorView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        editorView.frame = window.contentView?.bounds ?? .zero
        editorView.layoutSubtreeIfNeeded()
        editorView.textView.layoutVisibleViewport()
        return window
    }

    @MainActor
    func macEditorWindowPoint(
        in window: NSWindow,
        textView: SyntaxEditorTextInputView,
        characterRange: NSRange,
        xOffset: CGFloat = 1
    ) -> NSPoint {
        let screenRect = textView.firstRect(forCharacterRange: characterRange, actualRange: nil)
        return window.convertPoint(
            fromScreen: NSPoint(
                x: screenRect.minX + xOffset,
                y: screenRect.midY
            )
        )
    }

}
#endif
