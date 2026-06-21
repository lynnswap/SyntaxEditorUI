#if canImport(UIKit)
import Foundation
import Observation
import ObservationBridge
import SwiftUI
import Testing
import UIKit
@testable import SyntaxEditorUI
@testable import SyntaxEditorUICommon
@testable import SyntaxEditorUIUIKit

extension SyntaxEditorUITests {
    func approximatelyEqualIOS(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    @MainActor
    func iOSAdjustedVisibleSize(_ editorView: SyntaxEditorView) -> CGSize {
        let insets = editorView.adjustedContentInset
        return CGSize(
            width: max(0, editorView.bounds.width - insets.left - insets.right),
            height: max(0, editorView.bounds.height - insets.top - insets.bottom)
        )
    }

    @MainActor
    func iOSMaximumContentOffset(_ editorView: SyntaxEditorView) -> CGPoint {
        let insets = editorView.adjustedContentInset
        return CGPoint(
            x: max(-insets.left, editorView.contentSize.width - editorView.bounds.width + insets.right),
            y: max(-insets.top, editorView.contentSize.height - editorView.bounds.height + insets.bottom)
        )
    }

    @MainActor
    func iOSExpectedTextContentSize(_ editorView: SyntaxEditorView) -> CGSize {
        CGSize(
            width: max(
                editorView.font.lineHeight,
                editorView.contentSize.width - editorView.textContainerInset.left - editorView.textContainerInset.right
            ),
            height: max(
                editorView.font.lineHeight,
                editorView.contentSize.height - editorView.textContainerInset.top - editorView.textContainerInset.bottom
            )
        )
    }

}
#endif
