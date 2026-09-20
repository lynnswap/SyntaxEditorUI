#if canImport(UIKit) || canImport(AppKit)
import CoreGraphics
import Foundation
import SyntaxEditorCore

package final class DocumentLineMetrics {
    private let index: LineMetricsIndex

    package var fullRebuildCount: Int { index.fullRebuildCount }
    package var lineCount: Int { index.lineCount }
    package var lineOffsets: LineOffsetTable { index.lineOffsets }

    package init(source: String = "", tabWidth: Int) {
        index = LineMetricsIndex(source: source, tabWidth: tabWidth)
    }

    package func reset(source: String) {
        index.reset(source: source)
    }

    package func apply(edits: [SyntaxEditorTextChange.Replacement], previousSource: String) {
        index.apply(edits: edits, previousSource: previousSource)
    }

    package func horizontalDocumentWidth(
        columnWidth: CGFloat,
        textContainerInset: CGFloat,
        lineFragmentPadding: CGFloat
    ) -> CGFloat {
        index.horizontalDocumentWidth(
            columnWidth: columnWidth,
            textContainerInset: textContainerInset,
            lineFragmentPadding: lineFragmentPadding
        )
    }

    package func estimatedWrappedLineCount(maxColumnsPerLine: Int) -> Int {
        index.estimatedWrappedLineCount(maxColumnsPerLine: maxColumnsPerLine)
    }

    package func estimatedDocumentSize(
        minimumSize: CGSize,
        lineWrappingEnabled: Bool,
        lineHeight: CGFloat,
        columnWidth: CGFloat,
        lineFragmentPadding: CGFloat,
        textContainerInset: CGFloat = 0
    ) -> CGSize {
        let estimatedWidth = horizontalDocumentWidth(
            columnWidth: columnWidth,
            textContainerInset: textContainerInset,
            lineFragmentPadding: lineFragmentPadding
        )
        let maxColumnsPerLine = Int(floor(max(1, minimumSize.width - lineFragmentPadding * 2) / columnWidth))
        let visualLineCount = lineWrappingEnabled
            ? estimatedWrappedLineCount(maxColumnsPerLine: maxColumnsPerLine)
            : lineCount
        let estimatedHeight = ceil(CGFloat(visualLineCount) * lineHeight)

        return CGSize(
            width: max(minimumSize.width, estimatedWidth),
            height: max(minimumSize.height, estimatedHeight)
        )
    }
}
#endif
