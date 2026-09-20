import Foundation
import SyntaxEditorCore

package enum EditorComparisonGeometry {
    package enum Side: Sendable, Hashable {
        case original
        case modified
    }

    /// Maps logical line coordinates, preserving fractions in unchanged lines
    /// and interpolating changed spans by their logical line counts.
    /// Empty source spans and upper bounds use the following common boundary.
    package static func counterpartLine(
        _ line: CGFloat,
        from side: Side,
        changes: [EditorComparisonEngine.Change]
    ) -> CGFloat {
        var lineDelta: CGFloat = 0
        for change in changes {
            let source: Range<Int>
            let destination: Range<Int>
            switch side {
            case .original:
                source = change.originalLines
                destination = change.modifiedLines
            case .modified:
                source = change.modifiedLines
                destination = change.originalLines
            }

            if line < CGFloat(source.lowerBound) {
                return line + lineDelta
            }
            if line < CGFloat(source.upperBound) {
                let progress = (line - CGFloat(source.lowerBound)) / CGFloat(source.count)
                return CGFloat(destination.lowerBound) + progress * CGFloat(destination.count)
            }
            lineDelta = CGFloat(destination.upperBound) - CGFloat(source.upperBound)
        }
        return line + lineDelta
    }
}
