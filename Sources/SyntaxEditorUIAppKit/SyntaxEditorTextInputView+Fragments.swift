#if canImport(AppKit)
import AppKit
import SyntaxEditorCore
import SyntaxEditorUICommon

extension SyntaxEditorTextInputView {
final class TextContentView: NSView {
    weak var textInputView: SyntaxEditorTextInputView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class TextLayoutFragment: NSTextLayoutFragment {
    private(set) var lineFragmentDrawCountForTesting = 0

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
    }

    func draw(at point: CGPoint, in context: CGContext, dirtyRect: CGRect?) {
        context.saveGState()
        for lineFragment in textLineFragments {
            let lineFrame = lineFragment.typographicBounds.offsetBy(dx: point.x, dy: point.y)
            if let dirtyRect,
               !lineFrame.insetBy(dx: 0, dy: -2).intersects(dirtyRect) {
                continue
            }

            lineFragmentDrawCountForTesting += 1
            lineFragment.draw(at: lineFrame.origin, in: context)
        }
        context.restoreGState()
    }
}

final class TextLayoutFragmentView: NSView {
    let layoutFragment: NSTextLayoutFragment
    weak var textInputView: SyntaxEditorTextInputView?
    static let findCandidateHighlightFillColor = dynamicTextColor(alpha: 0.14)
    private static let findCandidateHighlightStrokeColor = dynamicTextColor(alpha: 0.32)
    static let findCandidateHighlightCornerRadius: CGFloat = 3
    var findHighlightRects: [CGRect] = []
    var selectionHighlightRects: [CGRect] = []
    var selectionHighlightColor: NSColor?
    var bracketHighlightRects: [CGRect] = []
    var bracketHighlightColor: NSColor?

    init(layoutFragment: NSTextLayoutFragment, frame: CGRect) {
        self.layoutFragment = layoutFragment
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.drawsAsynchronously = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setFindHighlights(rects: [CGRect]) {
        guard findHighlightRects != rects else { return }

        findHighlightRects = rects
        needsDisplay = true
    }

    func setSelectionHighlights(rects: [CGRect], color: NSColor?) {
        guard selectionHighlightRects != rects
            || !colorsEqual(selectionHighlightColor, color)
        else {
            return
        }
        selectionHighlightRects = rects
        selectionHighlightColor = color
        needsDisplay = true
    }

    func setBracketHighlights(rects: [CGRect], color: NSColor?) {
        guard bracketHighlightRects != rects
            || !colorsEqual(bracketHighlightColor, color)
        else {
            return
        }
        bracketHighlightRects = rects
        bracketHighlightColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawFindCandidateHighlights(in: dirtyRect)
        if let selectionHighlightColor, !selectionHighlightRects.isEmpty {
            selectionHighlightColor.setFill()
            for rect in selectionHighlightRects where rect.intersects(dirtyRect) {
                rect.fill()
            }
        }
        if let bracketHighlightColor, !bracketHighlightRects.isEmpty {
            bracketHighlightColor.setFill()
            for rect in bracketHighlightRects where rect.intersects(dirtyRect) {
                rect.fill()
            }
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        textInputView?.validateSyntaxRenderingAttributesForDisplay(
            in: layoutFragment,
            dirtyRectInFragment: dirtyRect
        )
        if let syntaxLayoutFragment = layoutFragment as? SyntaxEditorTextInputView.TextLayoutFragment {
            syntaxLayoutFragment.draw(at: .zero, in: context, dirtyRect: dirtyRect)
        } else {
            layoutFragment.draw(at: .zero, in: context)
        }
    }

    private func drawFindCandidateHighlights(in dirtyRect: NSRect) {
        guard !findHighlightRects.isEmpty else { return }

        Self.findCandidateHighlightFillColor.setFill()
        Self.findCandidateHighlightStrokeColor.setStroke()
        for rect in findHighlightRects where rect.intersects(dirtyRect) {
            let highlightRect = rect.insetBy(dx: -2, dy: 1)
            let path = NSBezierPath(
                roundedRect: highlightRect,
                xRadius: Self.findCandidateHighlightCornerRadius,
                yRadius: Self.findCandidateHighlightCornerRadius
            )
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func dynamicTextColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolvedColor = NSColor.textColor.withAlphaComponent(alpha)
            appearance.performAsCurrentDrawingAppearance {
                resolvedColor = NSColor.textColor.withAlphaComponent(alpha)
            }
            return resolvedColor
        }
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}
}

#endif
