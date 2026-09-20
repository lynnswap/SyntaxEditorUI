#if canImport(UIKit)
import UIKit

@MainActor
final class SyntaxEditorReadOnlyGuardedUndoManager: UndoManager {
    var allowsMutation: () -> Bool = { true }

    override var canUndo: Bool {
        guard allowsMutation() else { return false }
        return super.canUndo
    }

    override var canRedo: Bool {
        guard allowsMutation() else { return false }
        return super.canRedo
    }

    override func undo() {
        guard allowsMutation() else { return }
        super.undo()
    }

    override func redo() {
        guard allowsMutation() else { return }
        super.redo()
    }

    override func undoNestedGroup() {
        guard allowsMutation() else { return }
        super.undoNestedGroup()
    }
}

extension SyntaxEditorView {
final class TextPosition: UITextPosition {
    let offset: Int
    let anchorsLineEndHit: Bool

    init(offset: Int, anchorsLineEndHit: Bool = false) {
        self.offset = offset
        self.anchorsLineEndHit = anchorsLineEndHit
        super.init()
    }
}

final class TextRange: UITextRange {
    let nsRange: NSRange
    let findSearchIdentifier: Int?

    let startPosition: SyntaxEditorView.TextPosition
    let endPosition: SyntaxEditorView.TextPosition

    init(nsRange: NSRange, anchorsLineEndHit: Bool = false, findSearchIdentifier: Int? = nil) {
        let location = max(0, nsRange.location)
        let length = max(0, nsRange.length)
        let anchorsCollapsedLineEndHit = anchorsLineEndHit && length == 0
        self.nsRange = NSRange(location: location, length: length)
        self.findSearchIdentifier = findSearchIdentifier
        self.startPosition = SyntaxEditorView.TextPosition(
            offset: location,
            anchorsLineEndHit: anchorsCollapsedLineEndHit
        )
        self.endPosition = SyntaxEditorView.TextPosition(
            offset: location + length,
            anchorsLineEndHit: anchorsCollapsedLineEndHit
        )
        super.init()
    }

    override var start: UITextPosition {
        startPosition
    }

    override var end: UITextPosition {
        endPosition
    }

    override var isEmpty: Bool {
        nsRange.length == 0
    }
}
}

struct SyntaxEditorTextInteractionCaretOverride {
    let offset: Int
    var wordRange: NSRange?
}

extension SyntaxEditorView {
@MainActor
final class TextInputTokenizer: NSObject, UITextInputTokenizer {
    weak var textInput: SyntaxEditorView?
    private let baseTokenizer: UITextInputStringTokenizer

    init(textInput: SyntaxEditorView) {
        self.textInput = textInput
        self.baseTokenizer = UITextInputStringTokenizer(textInput: textInput)
        super.init()
    }

    func rangeEnclosingPosition(
        _ position: UITextPosition,
        with granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> UITextRange? {
        let result = baseTokenizer.rangeEnclosingPosition(
            position,
            with: granularity,
            inDirection: direction
        )
        if granularity == .word {
            textInput?.noteTextInteractionTokenizerWordRange(result, enclosing: position)
        }
        return result
    }

    func position(
        from position: UITextPosition,
        toBoundary granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> UITextPosition? {
        baseTokenizer.position(
            from: position,
            toBoundary: granularity,
            inDirection: direction
        )
    }

    func isPosition(
        _ position: UITextPosition,
        atBoundary granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> Bool {
        baseTokenizer.isPosition(
            position,
            atBoundary: granularity,
            inDirection: direction
        )
    }

    func isPosition(
        _ position: UITextPosition,
        withinTextUnit granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> Bool {
        baseTokenizer.isPosition(
            position,
            withinTextUnit: granularity,
            inDirection: direction
        )
    }
}

final class SelectionRect: UITextSelectionRect {
    let selectionRect: CGRect
    let selectionWritingDirection: NSWritingDirection
    let selectionContainsStart: Bool
    let selectionContainsEnd: Bool

    init(
        rect: CGRect,
        writingDirection: NSWritingDirection = .leftToRight,
        containsStart: Bool,
        containsEnd: Bool
    ) {
        self.selectionRect = rect
        self.selectionWritingDirection = writingDirection
        self.selectionContainsStart = containsStart
        self.selectionContainsEnd = containsEnd
        super.init()
    }

    override var rect: CGRect {
        selectionRect
    }

    override var writingDirection: NSWritingDirection {
        selectionWritingDirection
    }

    override var containsStart: Bool {
        selectionContainsStart
    }

    override var containsEnd: Bool {
        selectionContainsEnd
    }

    override var isVertical: Bool {
        false
    }
}

final class TextContentView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class TextLayoutFragmentView: UIView {
    weak var editor: SyntaxEditorView?
    let layoutFragment: NSTextLayoutFragment
    var findHighlightRects: [CGRect] = []
    var findHighlightColor: CGColor?
    var currentFindHighlightRects: [CGRect] = []
    var currentFindHighlightColor: CGColor?
    var bracketHighlightRects: [CGRect] = []
    var bracketHighlightColor: CGColor?

    init(layoutFragment: NSTextLayoutFragment, frame: CGRect) {
        self.layoutFragment = layoutFragment
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        editor?.comparisonLayout?.drawBackground(
            for: layoutFragment, surfaceOrigin: frame.origin, in: bounds, dirtyRect: rect
        )

        if let findHighlightColor, !findHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(findHighlightColor)
            for findRect in findHighlightRects where findRect.intersects(rect) {
                context.fill(findRect)
            }
            context.restoreGState()
        }

        if let currentFindHighlightColor, !currentFindHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(currentFindHighlightColor)
            for currentFindRect in currentFindHighlightRects where currentFindRect.intersects(rect) {
                context.fill(currentFindRect)
            }
            context.restoreGState()
        }

        if let bracketHighlightColor, !bracketHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(bracketHighlightColor)
            for bracketRect in bracketHighlightRects where bracketRect.intersects(rect) {
                context.fill(bracketRect)
            }
            context.restoreGState()
        }
        let origin = CGPoint(x: layoutFragment.layoutFragmentFrame.minX - frame.minX,
                             y: layoutFragment.layoutFragmentFrame.minY - frame.minY)
        layoutFragment.draw(at: origin, in: context)
    }
}
}

extension UIColor {
    static func syntaxEditorAlpha(_ color: UIColor, alpha: CGFloat) -> UIColor {
        UIColor { traitCollection in
            color.resolvedColor(with: traitCollection).withAlphaComponent(alpha)
        }
    }
}

extension CGFloat {
    func isNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}

extension CGSize {
    func isNearlyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        width.isNearlyEqual(to: other.width, tolerance: tolerance)
            && height.isNearlyEqual(to: other.height, tolerance: tolerance)
    }
}

extension CGRect {
    func isNearlyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        origin.x.isNearlyEqual(to: other.origin.x, tolerance: tolerance)
            && origin.y.isNearlyEqual(to: other.origin.y, tolerance: tolerance)
            && size.isNearlyEqual(to: other.size, tolerance: tolerance)
    }
}
#endif
