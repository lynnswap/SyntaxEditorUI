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
    @Test("SyntaxEditorView leaves iOS indirect pointer drags for text selection")
    @MainActor
    func syntaxEditorViewIOSLeavesIndirectPointerDragsForTextSelection() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "let value = 1"))
        let allowedTouchTypes = Set(editorView.panGestureRecognizer.allowedTouchTypes.map { Int($0.intValue) })

        #expect(allowedTouchTypes.contains(UITouch.TouchType.direct.rawValue))
        #expect(allowedTouchTypes.contains(UITouch.TouchType.pencil.rawValue))
        #expect(allowedTouchTypes.contains(UITouch.TouchType.indirect.rawValue))
        #expect(!allowedTouchTypes.contains(UITouch.TouchType.indirectPointer.rawValue))
    }

    @Test("SyntaxEditorView receives iOS text interaction hit tests through the rendering view")
    @MainActor
    func syntaxEditorViewIOSReceivesTextInteractionHitTestsThroughRenderingView() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "let value = 1"))
        layoutIOSEditorView(editorView)

        let hitView = editorView.hitTest(CGPoint(x: 24, y: 24), with: nil)

        #expect(hitView === editorView)
    }

    @Test("SyntaxEditorView preserves iOS UTF-16 position round trips")
    @MainActor
    func syntaxEditorViewIOSPreservesUTF16PositionRoundTrips() {
        let source = "🙂"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        guard let endPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: source.utf16.count
        )
        else {
            Issue.record("SyntaxEditorView could not move to the UTF-16 end offset")
            return
        }

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: endPosition) == source.utf16.count)
        #expect(editorView.position(from: editorView.beginningOfDocument, offset: 1) == nil)
    }

    @Test("SyntaxEditorView returns iOS composed character ranges")
    @MainActor
    func syntaxEditorViewIOSReturnsComposedCharacterRanges() {
        let source = "a🙂e\u{301}b"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        let afterAOffset = ("a" as NSString).length
        let afterEmojiOffset = ("a🙂" as NSString).length
        let beforeCombiningCharacterOffset = afterEmojiOffset
        guard let afterA = editorView.position(from: editorView.beginningOfDocument, offset: afterAOffset),
              let afterEmoji = editorView.position(from: editorView.beginningOfDocument, offset: afterEmojiOffset),
              let emojiRange = editorView.characterRange(byExtending: afterA, in: .right),
              let previousEmojiRange = editorView.characterRange(byExtending: afterEmoji, in: .left),
              let combiningRange = editorView.characterRange(
                  byExtending: SyntaxEditorView.TextPosition(offset: beforeCombiningCharacterOffset),
                  in: .right
              )
        else {
            Issue.record("SyntaxEditorView could not build composed character ranges")
            return
        }

        #expect(editorView.text(in: emojiRange) == "🙂")
        #expect(editorView.text(in: previousEmojiRange) == "🙂")
        #expect(editorView.text(in: combiningRange) == "e\u{301}")
    }

    @Test("SyntaxEditorView clamps iOS selection after setting shorter text")
    @MainActor
    func syntaxEditorViewIOSClampsSelectionAfterSettingShorterText() {
        let source = "abcdef"
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: source))
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.text = "x"

        #expect(editorView.text == "x")
        #expect(editorView.selectedRange == NSRange(location: 1, length: 0))
        #expect(editorView.model.latestTextChange?.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("SyntaxEditorView keeps empty no-wrap iOS content width tied to bounds")
    @MainActor
    func syntaxEditorViewIOSEmptyNoWrapContentWidthTracksBounds() {
        let model = SyntaxEditorTestContext(
            text: "",
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())

        layoutIOSEditorView(editorView, width: 600, height: 240)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)

        layoutIOSEditorView(editorView, width: 240, height: 240)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
    }

    @Test("SyntaxEditorView enables horizontal scrolling for initial long iOS line")
    @MainActor
    func syntaxEditorViewIOSInitialLongLineScrollsHorizontally() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)

        layoutIOSEditorView(editorView)
        #expect(iOSEditorHasHorizontalOverflow(editorView))
        #expect(editorView.contentSize.width > editorView.bounds.width + 1)

        editorView.setContentOffset(CGPoint(x: 24, y: 0), animated: false)
        #expect(editorView.contentOffset.x > 0)
    }

    @Test("SyntaxEditorView includes offscreen iOS lines in initial horizontal scroll range")
    @MainActor
    func syntaxEditorViewIOSInitialOffscreenLongLineSetsHorizontalScrollRange() {
        let model = SyntaxEditorTestContext(
            text: offscreenWideSyntaxEditorText,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)

        layoutIOSEditorView(editorView, width: 160, height: 120)
        #expect(editorView.contentSize.width > editorView.bounds.width + 1)

        let maxOffsetX = max(0, editorView.contentSize.width - editorView.bounds.width)
        #expect(maxOffsetX > 0)

        editorView.setContentOffset(CGPoint(x: maxOffsetX, y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 160, height: 120)
        #expect(editorView.contentOffset.x > 0)
    }

    @Test("SyntaxEditorView accounts for offscreen wide unicode iOS lines in horizontal scroll range")
    @MainActor
    func syntaxEditorViewIOSInitialOffscreenWideUnicodeLineSetsHorizontalScrollRange() {
        let model = SyntaxEditorTestContext(
            text: offscreenWideUnicodeSyntaxEditorText,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)

        layoutIOSEditorView(editorView, width: 160, height: 120)
        #expect(editorView.contentSize.width > editorView.bounds.width + 1)

        let measuredLineWidth = (offscreenWideUnicodeSyntaxEditorLine as NSString).size(
            withAttributes: [.font: editorView.font]
        ).width
        #expect(editorView.contentSize.width >= measuredLineWidth)

        editorView.setContentOffset(
            CGPoint(x: max(0, editorView.contentSize.width - editorView.bounds.width), y: 0),
            animated: false
        )
        layoutIOSEditorView(editorView, width: 160, height: 120)
        #expect(editorView.contentOffset.x > 0)
    }

    @Test("SyntaxEditorView keeps text layout covering horizontal scroll")
    @MainActor
    func syntaxEditorViewTextLayoutCoversHorizontalScrollViewport() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.contentSize.width > editorView.bounds.width + 1)
        #expect(editorView.textLayoutManager != nil)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let visibleRightEdge = editorView.contentOffset.x + editorView.bounds.width
        guard let renderedContentFrame = iOSEditorRenderedContentFrame(editorView) else {
            Issue.record("SyntaxEditorView does not expose a rendered content frame")
            return
        }

        #expect(renderedContentFrame.width >= editorView.contentSize.width - 1)
        #expect(renderedContentFrame.maxX >= visibleRightEdge - 1)
        #expect(
            editorTextLayoutUsageBoundsCoverVisibleHorizontalViewport(editorView),
            Comment(rawValue: editorTextLayoutDiagnostics(editorView))
        )
    }

    @Test("SyntaxEditorView keeps text layout covering horizontal scroll after wrapping toggle")
    @MainActor
    func syntaxEditorViewTextLayoutCoversHorizontalScrollAfterWrappingToggle() async {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 504, height: 1104)

        #expect(editorView.textContainer.widthTracksTextView)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
        #expect(iOSEditorLineBreakMode(editorView) == .byCharWrapping)

        model.model.lineWrappingEnabled = false

        editorView.synchronizeDocumentForTesting()
        #expect(!editorView.textContainer.widthTracksTextView)
        layoutIOSEditorView(editorView, width: 504, height: 1104)
        #expect(editorView.contentSize.width > editorView.bounds.width + 1)
        #expect(editorView.textLayoutManager != nil)
        #expect(iOSEditorLineBreakMode(editorView) == .byClipping)

        let maxOffsetX = max(0, editorView.contentSize.width - editorView.bounds.width)
        for fraction in [0.25, 0.5, 0.75] {
            editorView.setContentOffset(CGPoint(x: maxOffsetX * fraction, y: 0), animated: false)
            layoutIOSEditorView(editorView, width: 504, height: 1104)

            guard let renderedContentFrame = iOSEditorRenderedContentFrame(editorView) else {
                Issue.record("SyntaxEditorView does not expose a rendered content frame")
                return
            }
            let visibleRightEdge = editorView.contentOffset.x + editorView.bounds.width

            #expect(editorView.contentOffset.x > 0)
            #expect(renderedContentFrame.width >= editorView.contentSize.width - 1)
            #expect(renderedContentFrame.maxX >= visibleRightEdge - 1)
            #expect(
                editorTextLayoutUsageBoundsCoverVisibleHorizontalViewport(editorView),
                Comment(rawValue: editorTextLayoutDiagnostics(editorView))
            )
        }
    }

    @Test("SyntaxEditorView keeps long iOS lines unwrapped while horizontally scrollable")
    @MainActor
    func syntaxEditorViewIOSNoWrapKeepsLongLinesUnwrapped() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.contentSize.width > editorView.bounds.width + 1)
        #expect(iOSEditorTextUsageHeight(editorView) <= 120)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.contentOffset.x > 0)
        #expect(iOSEditorTextUsageHeight(editorView) <= 120)
        #expect(editorView.textLayoutManager != nil)
        #expect(
            editorTextLayoutUsageBoundsCoverVisibleHorizontalViewport(editorView),
            Comment(rawValue: editorTextLayoutDiagnostics(editorView))
        )
    }

    @Test("SyntaxEditorView does not jump to the iOS line end when a visible long range is selected")
    @MainActor
    func syntaxEditorViewIOSVisibleLongRangeSelectionDoesNotJumpToLineEnd() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let stableOffsetX = iOSEditorStableHorizontalOffset(editorView)
        editorView.setContentOffset(CGPoint(x: stableOffsetX, y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let position = editorView.closestPosition(
            to: CGPoint(x: editorView.bounds.midX, y: iOSEditorLineMidY(editorView, lineIndex: 2))
        ) else {
            Issue.record("SyntaxEditorView could not resolve a visible iOS text-input point")
            return
        }
        let location = editorView.offset(from: editorView.beginningOfDocument, to: position)
        editorView.selectedRange = NSRange(location: location, length: 0)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
        #expect(editorView.textLayoutManager != nil)
        #expect(
            editorTextLayoutUsageBoundsCoverVisibleHorizontalViewport(editorView),
            Comment(rawValue: editorTextLayoutDiagnostics(editorView))
        )
    }

    @Test("SyntaxEditorView snaps iOS trailing line whitespace taps to that line end")
    @MainActor
    func syntaxEditorViewIOSSnapsTrailingLineWhitespaceTapToLineEnd() {
        let source = "const answer = 42;\nfunction greet(name) {}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = (source as NSString).range(of: "\n").location
        guard let lineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: firstLineEnd
        ) else {
            Issue.record("SyntaxEditorView could not resolve the first line end")
            return
        }

        let lineEndRect = editorView.caretRect(for: lineEndPosition)
        guard let snappedPosition = editorView.closestPosition(
            to: CGPoint(x: lineEndRect.maxX + 96, y: lineEndRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve trailing line whitespace")
            return
        }

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: snappedPosition) == firstLineEnd)
    }

    @Test("SyntaxEditorView keeps iOS drag hit testing on the touched visual line")
    @MainActor
    func syntaxEditorViewIOSKeepsDragHitTestingOnTouchedVisualLine() {
        let longLine = "    return "
            + String(repeating: "\"Hello, ${name}! \", ", count: 36)
        let source = [
            "const answer = 42;",
            "function greet(name) {",
            longLine,
            "}",
            "const again = 42;",
        ].joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let touchedLineStart = (source as NSString).range(of: longLine).location
        let touchedLineEnd = touchedLineStart + longLine.utf16.count
        guard let lineStartPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: touchedLineStart
        ) else {
            Issue.record("SyntaxEditorView could not resolve touched line start")
            return
        }

        let lineStartRect = editorView.caretRect(for: lineStartPosition)
        guard let hitPosition = editorView.closestPosition(
            to: CGPoint(x: lineStartRect.minX + 260, y: lineStartRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve touched line point")
            return
        }

        let hitOffset = editorView.offset(from: editorView.beginningOfDocument, to: hitPosition)
        #expect(hitOffset >= touchedLineStart)
        #expect(hitOffset <= touchedLineEnd)
        #expect(hitOffset < source.utf16.count - 1)
    }

    @Test("SyntaxEditorView constrains iOS drag hit testing to the requested text range")
    @MainActor
    func syntaxEditorViewIOSConstrainsDragHitTestingToRequestedRange() {
        let source = [
            "const answer = 42;",
            "function greet(name) {",
            "    return " + String(repeating: "\"Hello\", ", count: 28),
            "}",
            "const finalAnswer = 42;",
        ].joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let constrainedLine = "function greet(name) {"
        let constrainedStart = (source as NSString).range(of: constrainedLine).location
        let constrainedEnd = constrainedStart + constrainedLine.utf16.count
        guard let startPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: constrainedStart
        ),
              let endPosition = editorView.position(
                from: editorView.beginningOfDocument,
                offset: constrainedEnd
              ),
              let constrainedRange = editorView.textRange(from: startPosition, to: endPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve constrained drag range")
            return
        }

        let farDocumentEndPoint = CGPoint(x: editorView.bounds.maxX - 12, y: editorView.bounds.maxY - 12)
        guard let constrainedPosition = editorView.closestPosition(
            to: farDocumentEndPoint,
            within: constrainedRange
        ) else {
            Issue.record("SyntaxEditorView could not resolve constrained drag point")
            return
        }

        let constrainedOffset = editorView.offset(
            from: editorView.beginningOfDocument,
            to: constrainedPosition
        )
        #expect(constrainedOffset >= constrainedStart)
        #expect(constrainedOffset <= constrainedEnd)
    }

    @Test("SyntaxEditorView keeps collapsed iOS drag constraints at anchor")
    @MainActor
    func syntaxEditorViewIOSKeepsCollapsedDragConstraintsAtAnchor() {
        let line = "const answer = 42;"
        let source = [
            "<script>",
            line,
            "</script>",
            "<script>",
            line,
            "</script>",
        ].joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.html,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let lineStart = (source as NSString).range(of: line).location
        let lineEnd = lineStart + line.utf16.count
        let targetOffset = lineStart + "const ".utf16.count
        guard let lineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: lineEnd
        ),
              let targetPosition = editorView.position(
                from: editorView.beginningOfDocument,
                offset: targetOffset
              ),
              let collapsedRange = editorView.textRange(from: lineEndPosition, to: lineEndPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve collapsed drag positions")
            return
        }

        let targetRect = editorView.caretRect(for: targetPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: targetRect.midX, y: targetRect.midY),
            within: collapsedRange
        ) else {
            Issue.record("SyntaxEditorView could not resolve collapsed constrained drag point")
            return
        }

        let resolvedOffset = editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition)
        #expect(resolvedOffset == lineEnd)
    }

    @Test("SyntaxEditorView resolves iOS clicks to the touched whitespace column")
    @MainActor
    func syntaxEditorViewIOSResolvesClicksToTouchedWhitespaceColumn() {
        let sourceLines = [
            "let prefix = 1;",
            "value          = 42;",
            "let suffix = 2;",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let whitespaceLineStart = (source as NSString).range(of: sourceLines[1]).location
        let whitespaceOffset = whitespaceLineStart + "value     ".utf16.count
        guard let whitespacePosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: whitespaceOffset
        ) else {
            Issue.record("SyntaxEditorView could not resolve whitespace position")
            return
        }

        let whitespaceRect = editorView.caretRect(for: whitespacePosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: whitespaceRect.midX, y: whitespaceRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve whitespace click")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition)
                == whitespaceOffset
        )
    }

    @Test("SyntaxEditorView resolves iOS clicks to the nearest caret before a character midpoint")
    @MainActor
    func syntaxEditorViewIOSResolvesClicksToNearestCaretBeforeCharacterMidpoint() {
        let source = "struct Greeting {\n    let message = \"hello\"\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let wordStart = (source as NSString).range(of: "Greeting").location
        let leadingOffset = wordStart + "Gre".utf16.count
        let trailingOffset = leadingOffset + 1
        guard let leadingPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: leadingOffset
        ),
              let trailingPosition = editorView.position(
                from: editorView.beginningOfDocument,
                offset: trailingOffset
              )
        else {
            Issue.record("SyntaxEditorView could not resolve adjacent word caret positions")
            return
        }

        let leadingRect = editorView.caretRect(for: leadingPosition)
        let trailingRect = editorView.caretRect(for: trailingPosition)
        let tapPoint = CGPoint(
            x: ((leadingRect.midX + trailingRect.midX) / 2) - 0.2,
            y: leadingRect.midY
        )
        guard let resolvedPosition = editorView.closestPosition(to: tapPoint) else {
            Issue.record("SyntaxEditorView could not resolve the word tap point")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition)
                == leadingOffset
        )
    }

    @Test("SyntaxEditorView keeps the iOS tap caret when UIKit collapses an enclosing word")
    @MainActor
    func syntaxEditorViewIOSKeepsTapCaretWhenUIKitCollapsesEnclosingWord() {
        let source = "struct Greeting {\n    let message = \"hello\"\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let wordStart = (source as NSString).range(of: "Greeting").location
        let tappedOffset = wordStart + "Gre".utf16.count
        let wordEnd = wordStart + "Greeting".utf16.count
        guard let tappedPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: tappedOffset
        ),
              let wordEndPosition = editorView.position(
                from: editorView.beginningOfDocument,
                offset: wordEnd
              ),
              let collapsedWordEndRange = editorView.textRange(from: wordEndPosition, to: wordEndPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve the tapped word positions")
            return
        }

        let tappedRect = editorView.caretRect(for: tappedPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: tappedRect.midX, y: tappedRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve the tapped word caret")
            return
        }
        _ = editorView.tokenizer.rangeEnclosingPosition(
            resolvedPosition,
            with: .word,
            inDirection: UITextDirection(rawValue: 0)
        )

        editorView.selectedTextRange = collapsedWordEndRange

        #expect(editorView.selectedRange == NSRange(location: tappedOffset, length: 0))
    }

    @Test("SyntaxEditorView resolves an adjacent caret boundary for iOS drag selection")
    @MainActor
    func syntaxEditorViewIOSResolvesAdjacentCaretBoundaryForDragSelection() {
        let source = "struct Greeting {\n    let message = \"hello\"\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let wordStart = (source as NSString).range(of: "Greeting").location
        let tappedOffset = wordStart + "Gre".utf16.count
        guard let nextPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: tappedOffset + 1
        ) else {
            Issue.record("SyntaxEditorView could not resolve the adjacent word caret position")
            return
        }

        editorView.selectedRange = NSRange(location: tappedOffset, length: 0)
        let adjacentBoundaryRect = editorView.caretRect(for: nextPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: adjacentBoundaryRect.midX, y: adjacentBoundaryRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve the adjacent word caret boundary")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition)
                == tappedOffset + 1
        )
    }

    @Test("SyntaxEditorView keeps iOS drag selections separate from tap word-boundary correction")
    @MainActor
    func syntaxEditorViewIOSKeepsDragSelectionsSeparateFromTapWordBoundaryCorrection() {
        let source = "struct Greeting {\n    let message = \"hello\"\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let wordStart = (source as NSString).range(of: "Greeting").location
        let tappedOffset = wordStart + "Gre".utf16.count
        let wordEnd = wordStart + "Greeting".utf16.count
        guard let tappedPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: tappedOffset
        ),
              let wordEndPosition = editorView.position(
                from: editorView.beginningOfDocument,
                offset: wordEnd
              ),
              let dragRange = editorView.textRange(from: tappedPosition, to: wordEndPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve the drag selection positions")
            return
        }

        let tappedRect = editorView.caretRect(for: tappedPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: tappedRect.midX, y: tappedRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve the tapped word caret")
            return
        }
        _ = editorView.tokenizer.rangeEnclosingPosition(
            resolvedPosition,
            with: .word,
            inDirection: UITextDirection(rawValue: 0)
        )

        editorView.selectedTextRange = dragRange

        #expect(editorView.selectedRange == NSRange(location: tappedOffset, length: wordEnd - tappedOffset))
    }

    @Test("SyntaxEditorView resolves iOS clicks at the final line end")
    @MainActor
    func syntaxEditorViewIOSResolvesClicksAtFinalLineEnd() {
        let source = "let value = 123"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let endOffset = source.utf16.count
        guard let lineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: endOffset
        ) else {
            Issue.record("SyntaxEditorView could not resolve final line end position")
            return
        }

        let lineEndRect = editorView.caretRect(for: lineEndPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: lineEndRect.midX, y: lineEndRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve final line end click")
            return
        }

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition) == endOffset)
    }

    @Test("SyntaxEditorView resolves iOS clicks right of short lines to the line end")
    @MainActor
    func syntaxEditorViewIOSResolvesClicksRightOfShortLinesToLineEnd() {
        let sourceLines = [
            "let short = 1;",
            "let next = 2;",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = sourceLines[0].utf16.count
        guard let lineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: firstLineEnd
        ) else {
            Issue.record("SyntaxEditorView could not resolve line end position")
            return
        }

        let lineEndRect = editorView.caretRect(for: lineEndPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: lineEndRect.maxX + 120, y: lineEndRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve right-of-line click")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition)
                == firstLineEnd
        )
    }

    @Test("SyntaxEditorView resolves iOS clicks right of CRLF lines before the terminator")
    @MainActor
    func syntaxEditorViewIOSResolvesClicksRightOfCRLFLinesBeforeTerminator() {
        let firstLine = "let short = 1;"
        let source = "\(firstLine)\r\nlet next = 2;"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = firstLine.utf16.count
        guard let lineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: firstLineEnd
        ) else {
            Issue.record("SyntaxEditorView could not resolve CRLF line end position")
            return
        }

        let lineEndRect = editorView.caretRect(for: lineEndPosition)
        guard let resolvedPosition = editorView.closestPosition(
            to: CGPoint(x: lineEndRect.maxX + 120, y: lineEndRect.midY)
        ) else {
            Issue.record("SyntaxEditorView could not resolve right-of-CRLF-line click")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: resolvedPosition)
                == firstLineEnd
        )
    }

    @Test("SyntaxEditorView moves iOS caret vertically between visual lines")
    @MainActor
    func syntaxEditorViewIOSMovesCaretVerticallyBetweenVisualLines() {
        let sourceLines = [
            "let first = 0;",
            "01234567890123456789",
            "abcdefghijABCDEFGHIJ",
            "klmnopqrstKLMNOPQRST",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let secondLineStart = (source as NSString).range(of: sourceLines[1]).location
        let thirdLineStart = (source as NSString).range(of: sourceLines[2]).location
        let fourthLineStart = (source as NSString).range(of: sourceLines[3]).location
        let visualColumn = 10
        guard let currentPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: thirdLineStart + visualColumn
        ),
              let upPosition = editorView.position(from: currentPosition, in: .up, offset: 1),
              let downPosition = editorView.position(from: currentPosition, in: .down, offset: 1)
        else {
            Issue.record("SyntaxEditorView could not resolve vertical caret movement")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: upPosition)
                == secondLineStart + visualColumn
        )
        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: downPosition)
                == fourthLineStart + visualColumn
        )

        let currentRect = editorView.caretRect(for: currentPosition)
        let upRect = editorView.caretRect(for: upPosition)
        let downRect = editorView.caretRect(for: downPosition)
        #expect(upRect.midY < currentRect.midY)
        #expect(downRect.midY > currentRect.midY)
        #expect(abs(upRect.midX - currentRect.midX) <= 1)
        #expect(abs(downRect.midX - currentRect.midX) <= 1)
    }

    @Test("SyntaxEditorView keeps iOS caret column moving vertically from short visual lines")
    @MainActor
    func syntaxEditorViewIOSKeepsCaretColumnMovingVerticallyFromShortVisualLines() {
        let sourceLines = [
            "01234567890123456789",
            "abcde",
            "ABCDEFGHIJABCDEFGHIJ",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let secondLineStart = (source as NSString).range(of: sourceLines[1]).location
        let thirdLineStart = (source as NSString).range(of: sourceLines[2]).location
        let visualColumn = 4
        guard let shortLinePosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: secondLineStart + visualColumn
        ),
              let downPosition = editorView.position(from: shortLinePosition, in: .down, offset: 1)
        else {
            Issue.record("SyntaxEditorView could not resolve vertical caret movement from a short line")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: downPosition)
                == thirdLineStart + visualColumn
        )

        let shortLineRect = editorView.caretRect(for: shortLinePosition)
        let downRect = editorView.caretRect(for: downPosition)
        #expect(downRect.midY > shortLineRect.midY)
        #expect(abs(downRect.midX - shortLineRect.midX) <= 1)
    }

    @Test("SyntaxEditorView uses displayed iOS line break affinity for vertical caret movement")
    @MainActor
    func syntaxEditorViewIOSUsesDisplayedLineBreakAffinityForVerticalCaretMovement() {
        let sourceLines = [
            "abcde",
            "01234567890123456789",
            "ABCDEFGHIJABCDEFGHIJ",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = sourceLines[0].utf16.count
        let secondLineStart = (source as NSString).range(of: sourceLines[1]).location
        guard let downFromDocumentStart = editorView.position(
            from: editorView.beginningOfDocument,
            in: .down,
            offset: 1
        ) else {
            Issue.record("SyntaxEditorView could not resolve vertical caret movement from document start")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: downFromDocumentStart)
                == secondLineStart
        )

        guard let lineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: firstLineEnd
        ),
              let downPosition = editorView.position(from: lineEndPosition, in: .down, offset: 1)
        else {
            Issue.record("SyntaxEditorView could not resolve vertical caret movement at a line break")
            return
        }

        #expect(
            editorView.offset(from: editorView.beginningOfDocument, to: downPosition)
                == secondLineStart + firstLineEnd
        )

        let lineEndRect = editorView.caretRect(for: lineEndPosition)
        let downRect = editorView.caretRect(for: downPosition)
        #expect(downRect.midY > lineEndRect.midY)
        #expect(abs(downRect.midX - lineEndRect.midX) <= 1)
    }

    @Test("SyntaxEditorView syncs iOS line-end selections with upstream affinity")
    @MainActor
    func syntaxEditorViewIOSSyncsLineEndSelectionsWithUpstreamAffinity() {
        let source = "abcde\n01234"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        editorView.selectedRange = NSRange(location: 1, length: 0)
        #expect(editorView.textLayoutManager?.textSelections.first?.affinity == .downstream)

        let firstLineEnd = (source as NSString).range(of: "\n").location
        editorView.selectedRange = NSRange(location: firstLineEnd, length: 0)

        #expect(editorView.textLayoutManager?.textSelections.first?.affinity == .upstream)
    }

    @Test("SyntaxEditorView keeps iOS caret on the edited line after inserting before a line break")
    @MainActor
    func syntaxEditorViewIOSKeepsCaretOnEditedLineAfterInsertingBeforeLineBreak() {
        let editedLine = "    </style>"
        let source = [
            editedLine,
            "</head>",
            "<body>",
        ].joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.html,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let editedLineEnd = editedLine.utf16.count
        guard let lineStartPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: 0
        ) else {
            Issue.record("SyntaxEditorView could not resolve the edited line start")
            return
        }
        let lineStartRect = editorView.caretRect(for: lineStartPosition)

        editorView.selectedRange = NSRange(location: editedLineEnd, length: 0)
        editorView.insertText(".")
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let caretPosition = editorView.selectedTextRange?.start else {
            Issue.record("SyntaxEditorView did not expose a selected text range after line-break input")
            return
        }
        let caretRect = editorView.caretRect(for: caretPosition)

        #expect(editorView.text == "    </style>.\n</head>\n<body>")
        #expect(editorView.selectedRange == NSRange(location: editedLineEnd + 1, length: 0))
        #expect(abs(caretRect.midY - lineStartRect.midY) <= 1)
    }

    @Test("SyntaxEditorView keeps iOS EOF caret on the final visual line")
    @MainActor
    func syntaxEditorViewIOSKeepsEOFCaretOnFinalVisualLine() {
        let sourceLines = [
            "const answer = 42;",
            "function greet(name) {",
            "    return \"Hello\";",
            "}.",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let finalLineStart = (source as NSString).range(of: sourceLines[3]).location
        guard let finalLinePosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: finalLineStart
        ),
              let endPosition = editorView.position(
                from: editorView.beginningOfDocument,
                offset: source.utf16.count
              )
        else {
            Issue.record("SyntaxEditorView could not resolve the final line or EOF position")
            return
        }

        let finalLineRect = editorView.caretRect(for: finalLinePosition)
        let endRect = editorView.caretRect(for: endPosition)

        #expect(abs(endRect.midY - finalLineRect.midY) <= 1)

        guard let tappedPosition = editorView.closestPosition(
            to: CGPoint(x: endRect.midX + 120, y: endRect.maxY + 100)
        ) else {
            Issue.record("SyntaxEditorView could not resolve an empty-space tap below text")
            return
        }
        editorView.selectedTextRange = editorView.textRange(from: tappedPosition, to: tappedPosition)

        guard let selectedPosition = editorView.selectedTextRange?.start else {
            Issue.record("SyntaxEditorView did not expose a selected text range after empty-space tap")
            return
        }
        let tappedCaretRect = editorView.caretRect(for: selectedPosition)

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: selectedPosition) == source.utf16.count)
        #expect(abs(tappedCaretRect.midY - finalLineRect.midY) <= 1)
    }

    @Test("SyntaxEditorView places iOS caret on the next line after appending newline")
    @MainActor
    func syntaxEditorViewIOSPlacesCaretOnNextLineAfterAppendingNewline() {
        let source = "abcde"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        let firstLineRect = editorView.caretRect(for: editorView.beginningOfDocument)

        editorView.insertText("\n")
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let caretPosition = editorView.selectedTextRange?.start else {
            Issue.record("SyntaxEditorView did not expose a selected text range after appending newline")
            return
        }
        let caretRect = editorView.caretRect(for: caretPosition)

        #expect(editorView.text == "abcde\n")
        #expect(editorView.selectedRange == NSRange(location: "abcde\n".utf16.count, length: 0))
        #expect(caretRect.midY > firstLineRect.midY + editorView.font.lineHeight * 0.5)
        #expect(caretRect.midY < firstLineRect.midY + editorView.font.lineHeight * 1.5)
    }

    @Test("SyntaxEditorView keeps iOS caret on the edited line after inserting at line start")
    @MainActor
    func syntaxEditorViewIOSKeepsCaretOnEditedLineAfterInsertingAtLineStart() {
        let sourceLines = [
            "let first = 1;",
            "let second = 2;",
        ]
        let source = sourceLines.joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let secondLineStart = (source as NSString).range(of: sourceLines[1]).location
        editorView.selectedRange = NSRange(location: secondLineStart, length: 0)
        let firstLineRect = editorView.caretRect(for: editorView.beginningOfDocument)

        editorView.insertText("x")
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let editedPosition = editorView.selectedTextRange?.start
        guard let editedPosition else {
            Issue.record("SyntaxEditorView did not expose a selected text range after insertion")
            return
        }
        let editedRect = editorView.caretRect(for: editedPosition)

        #expect(editorView.selectedRange.location == secondLineStart + 1)
        #expect(editedRect.midY > firstLineRect.midY)
    }

    @Test("SyntaxEditorView rejects foreign iOS text positions for nonzero directional movement")
    @MainActor
    func syntaxEditorViewIOSRejectsForeignTextPositionsForNonzeroDirectionalMovement() {
        let model = SyntaxEditorTestContext(text: "abc", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        let foreignPosition = SyntaxEditorUITestForeignTextPosition()

        #expect(editorView.position(from: foreignPosition, in: .down, offset: 1) == nil)
        #expect(editorView.position(from: foreignPosition, in: .down, offset: 0) === foreignPosition)
    }

    @Test("SyntaxEditorView does not let iOS gesture selection changes own horizontal scrolling")
    @MainActor
    func syntaxEditorViewIOSGestureSelectionDoesNotOwnHorizontalScrolling() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let offscreenStartRange = editorView.textRange(
            from: editorView.beginningOfDocument,
            to: editorView.beginningOfDocument
        ) else {
            Issue.record("SyntaxEditorView could not resolve the document start range")
            return
        }

        let stableOffsetX = editorView.contentOffset.x
        editorView.selectedTextRange = offscreenStartRange
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView blocks iOS text interaction auto-scroll during gesture selection")
    @MainActor
    func syntaxEditorViewIOSBlocksTextInteractionAutoScrollDuringGestureSelection() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let visiblePosition = editorView.closestPosition(
            to: CGPoint(x: 240, y: iOSEditorLineMidY(editorView, lineIndex: 0))
        ),
              let visibleRange = editorView.textRange(from: visiblePosition, to: visiblePosition)
        else {
            Issue.record("SyntaxEditorView could not resolve a visible gesture selection range")
            return
        }

        let stableOffsetX = editorView.contentOffset.x
        editorView.selectedTextRange = visibleRange
        editorView.setContentOffset(CGPoint(x: editorView.contentSize.width - editorView.bounds.width, y: 0), animated: false)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView maps trailing first-line iOS tap to first line end")
    @MainActor
    func syntaxEditorViewIOSTrailingFirstLineTapMapsToFirstLineEnd() {
        let source = "const answer = 42;\nfunction greet(name) {\n    return name\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = (source as NSString).range(of: "\n").location
        let pointPastFirstLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 0.5
        )

        guard let position = editorView.closestPosition(to: pointPastFirstLineText) else {
            Issue.record("SyntaxEditorView could not resolve a first-line trailing tap")
            return
        }

        let offset = editorView.offset(from: editorView.beginningOfDocument, to: position)
        #expect(offset == firstLineEnd)
    }

    @Test("SyntaxEditorView collapses iOS character range for trailing line-end tap")
    @MainActor
    func syntaxEditorViewIOSCharacterRangeForTrailingLineEndTapIsCollapsed() {
        let source = "const answer = 42;\nfunction greet(name) {\n    return name\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = (source as NSString).range(of: "\n").location
        let pointPastFirstLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 0.5
        )

        guard let characterRange = editorView.characterRange(at: pointPastFirstLineText) else {
            Issue.record("SyntaxEditorView could not resolve a first-line trailing character range")
            return
        }

        let rangeStart = editorView.offset(from: editorView.beginningOfDocument, to: characterRange.start)
        let rangeEnd = editorView.offset(from: editorView.beginningOfDocument, to: characterRange.end)
        #expect(rangeStart == firstLineEnd)
        #expect(rangeEnd == firstLineEnd)

        editorView.selectedTextRange = characterRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))

        guard let adjustedPosition = editorView.position(from: characterRange.end, offset: 1),
              let adjustedRange = editorView.textRange(from: adjustedPosition, to: adjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not simulate UIKit character-range adjustment")
            return
        }
        editorView.selectedTextRange = adjustedRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))

        guard let storedRange = editorView.selectedTextRange,
              let storedAdjustedPosition = editorView.position(from: storedRange.end, offset: 1),
              let storedAdjustedRange = editorView.textRange(from: storedAdjustedPosition, to: storedAdjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve explicit movement from stored selection")
            return
        }
        editorView.selectedTextRange = storedAdjustedRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd + 1, length: 0))
    }

    @Test("SyntaxEditorView keeps iOS UIKit-adjusted trailing line-end tap before line break")
    @MainActor
    func syntaxEditorViewIOSKeepsUIKitAdjustedTrailingLineEndTapBeforeLineBreak() {
        let source = "const answer = 42;\nfunction greet(name) {\n    return name\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = (source as NSString).range(of: "\n").location
        let pointPastFirstLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 0.5
        )

        guard let hitPosition = editorView.closestPosition(to: pointPastFirstLineText),
              let hitRange = editorView.textRange(from: hitPosition, to: hitPosition),
              let adjustedPosition = editorView.position(from: hitRange.end, offset: 1),
              let adjustedRange = editorView.textRange(from: adjustedPosition, to: adjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not simulate UIKit trailing line-end tap adjustment")
            return
        }

        editorView.selectedTextRange = adjustedRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))

        guard let explicitLineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: firstLineEnd
        ),
              let explicitNextPosition = editorView.position(from: explicitLineEndPosition, offset: 1)
        else {
            Issue.record("SyntaxEditorView could not resolve explicit movement across a line break")
            return
        }

        let explicitNextOffset = editorView.offset(
            from: editorView.beginningOfDocument,
            to: explicitNextPosition
        )
        #expect(explicitNextOffset == firstLineEnd + 1)
    }

    @Test("SyntaxEditorView keeps iOS UIKit-adjusted second-line trailing tap before line break")
    @MainActor
    func syntaxEditorViewIOSKeepsUIKitAdjustedSecondLineTrailingTapBeforeLineBreak() {
        let source = "const answer = 42;\nfunction greet(name) {\n    return name\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineBreak = (source as NSString).range(of: "\n").location
        let secondLineStart = firstLineBreak + 1
        let secondLineEnd = (source as NSString).range(
            of: "\n",
            options: [],
            range: NSRange(location: secondLineStart, length: (source as NSString).length - secondLineStart)
        ).location
        let nextLineContentStart = (source as NSString).range(
            of: "return",
            options: [],
            range: NSRange(location: secondLineEnd, length: (source as NSString).length - secondLineEnd)
        ).location
        let uiKitAdjustedOffset = nextLineContentStart - secondLineEnd
        let pointPastSecondLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 1.5
        )

        guard let hitPosition = editorView.closestPosition(to: pointPastSecondLineText),
              let hitRange = editorView.textRange(from: hitPosition, to: hitPosition),
              let adjustedPosition = editorView.position(from: hitRange.end, offset: uiKitAdjustedOffset),
              let adjustedRange = editorView.textRange(from: adjustedPosition, to: adjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not simulate UIKit second-line trailing tap adjustment")
            return
        }

        let hitOffset = editorView.offset(from: editorView.beginningOfDocument, to: hitPosition)
        #expect(hitOffset == secondLineEnd)

        editorView.selectedTextRange = adjustedRange
        #expect(editorView.selectedRange == NSRange(location: secondLineEnd, length: 0))

        guard let storedRange = editorView.selectedTextRange,
              let storedAdjustedPosition = editorView.position(from: storedRange.end, offset: uiKitAdjustedOffset),
              let storedAdjustedRange = editorView.textRange(from: storedAdjustedPosition, to: storedAdjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve explicit second-line movement from stored selection")
            return
        }
        editorView.selectedTextRange = storedAdjustedRange
        #expect(editorView.selectedRange == NSRange(location: nextLineContentStart, length: 0))

        guard let explicitLineEndPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: secondLineEnd
        ),
              let explicitNextLineContentPosition = editorView.position(
                from: explicitLineEndPosition,
                offset: uiKitAdjustedOffset
              )
        else {
            Issue.record("SyntaxEditorView could not resolve explicit movement to second-line next content")
            return
        }

        let explicitNextLineContentOffset = editorView.offset(
            from: editorView.beginningOfDocument,
            to: explicitNextLineContentPosition
        )
        #expect(explicitNextLineContentOffset == nextLineContentStart)
    }

    @Test("SyntaxEditorView collapses iOS character range for trailing CRLF line-end tap")
    @MainActor
    func syntaxEditorViewIOSCharacterRangeForTrailingCRLFLineEndTapIsCollapsed() {
        let source = "const answer = 42;\r\nfunction greet(name) {\r\n    return name\r\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = (source as NSString).range(of: "\r\n").location
        let pointPastFirstLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 0.5
        )

        guard let characterRange = editorView.characterRange(at: pointPastFirstLineText) else {
            Issue.record("SyntaxEditorView could not resolve a first-line trailing CRLF character range")
            return
        }

        let rangeStart = editorView.offset(from: editorView.beginningOfDocument, to: characterRange.start)
        let rangeEnd = editorView.offset(from: editorView.beginningOfDocument, to: characterRange.end)
        #expect(rangeStart == firstLineEnd)
        #expect(rangeEnd == firstLineEnd)

        editorView.selectedTextRange = characterRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))

        guard let oneStepAdjustedPosition = editorView.position(from: characterRange.end, offset: 1),
              let oneStepAdjustedRange = editorView.textRange(
                from: oneStepAdjustedPosition,
                to: oneStepAdjustedPosition
              ),
              let adjustedPosition = editorView.position(from: characterRange.end, offset: 2),
              let adjustedRange = editorView.textRange(from: adjustedPosition, to: adjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not simulate UIKit CRLF character-range adjustment")
            return
        }
        editorView.selectedTextRange = oneStepAdjustedRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))

        editorView.selectedTextRange = adjustedRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))
    }

    @Test("SyntaxEditorView keeps iOS UIKit-adjusted trailing CRLF line-end tap before CRLF")
    @MainActor
    func syntaxEditorViewIOSKeepsUIKitAdjustedTrailingCRLFLineEndTapBeforeCRLF() {
        let source = "const answer = 42;\r\nfunction greet(name) {\r\n    return name\r\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineEnd = (source as NSString).range(of: "\r\n").location
        let nextLineContentStart = firstLineEnd + 2
        let pointPastFirstLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 0.5
        )

        guard let hitPosition = editorView.closestPosition(to: pointPastFirstLineText),
              let hitRange = editorView.textRange(from: hitPosition, to: hitPosition),
              let adjustedPosition = editorView.position(from: hitRange.end, offset: nextLineContentStart - firstLineEnd),
              let adjustedRange = editorView.textRange(from: adjustedPosition, to: adjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not simulate UIKit trailing CRLF line-end tap adjustment")
            return
        }

        editorView.selectedTextRange = adjustedRange
        #expect(editorView.selectedRange == NSRange(location: firstLineEnd, length: 0))
    }

    @Test("SyntaxEditorView keeps iOS UIKit-adjusted trailing CRLF indented tap before CRLF")
    @MainActor
    func syntaxEditorViewIOSKeepsUIKitAdjustedTrailingCRLFIndentedTapBeforeCRLF() {
        let source = "const answer = 42;\r\nfunction greet(name) {\r\n    return name\r\n}"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let firstLineBreak = (source as NSString).range(of: "\r\n").location
        let secondLineStart = firstLineBreak + 2
        let secondLineEnd = (source as NSString).range(
            of: "\r\n",
            options: [],
            range: NSRange(location: secondLineStart, length: (source as NSString).length - secondLineStart)
        ).location
        let nextLineContentStart = (source as NSString).range(
            of: "return",
            options: [],
            range: NSRange(location: secondLineEnd, length: (source as NSString).length - secondLineEnd)
        ).location
        let uiKitAdjustedOffset = nextLineContentStart - secondLineEnd
        let pointPastSecondLineText = CGPoint(
            x: editorView.bounds.minX + 260,
            y: editorView.textContainerInset.top + editorView.font.lineHeight * 1.5
        )

        guard let hitPosition = editorView.closestPosition(to: pointPastSecondLineText),
              let hitRange = editorView.textRange(from: hitPosition, to: hitPosition),
              let adjustedPosition = editorView.position(from: hitRange.end, offset: uiKitAdjustedOffset),
              let adjustedRange = editorView.textRange(from: adjustedPosition, to: adjustedPosition)
        else {
            Issue.record("SyntaxEditorView could not simulate UIKit trailing CRLF indented tap adjustment")
            return
        }

        let hitOffset = editorView.offset(from: editorView.beginningOfDocument, to: hitPosition)
        #expect(hitOffset == secondLineEnd)

        editorView.selectedTextRange = adjustedRange
        #expect(editorView.selectedRange == NSRange(location: secondLineEnd, length: 0))
    }

    @Test("SyntaxEditorView allows explicit iOS scrollRectToVisible to move horizontally")
    @MainActor
    func syntaxEditorViewIOSAllowsExplicitScrollRectToVisibleToMoveHorizontally() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let initialOffsetX = editorView.contentOffset.x
        let explicitTargetRect = CGRect(
            x: editorView.contentSize.width - 4,
            y: editorView.textContainerInset.top,
            width: 2,
            height: editorView.font.lineHeight
        )
        editorView.scrollRectToVisible(explicitTargetRect, animated: false)

        #expect(editorView.contentOffset.x > initialOffsetX)
    }

    @Test("SyntaxEditorView preserves horizontal offset for text interaction iOS scrollRectToVisible")
    @MainActor
    func syntaxEditorViewIOSPreservesHorizontalOffsetForTextInteractionScrollRectToVisible() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        let stableOffsetX = editorView.contentOffset.x
        #expect(stableOffsetX > 0)

        let textInteractionCaretRect = editorView.caretRect(for: editorView.beginningOfDocument)
        #expect(!textInteractionCaretRect.isEmpty)
        let textInteractionTargetRect = CGRect(
            x: editorView.contentSize.width - 4,
            y: editorView.textContainerInset.top,
            width: 2,
            height: editorView.font.lineHeight
        )
        editorView.scrollRectToVisible(textInteractionTargetRect, animated: false)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView reports iOS visible content rect after horizontal scroll")
    @MainActor
    func syntaxEditorViewIOSVisibleContentRectTracksHorizontalScroll() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let visibleRect = CGRect(origin: editorView.contentOffset, size: editorView.bounds.size)
        #expect(abs(visibleRect.minX - editorView.contentOffset.x) <= 1)
        #expect(abs(visibleRect.minY - editorView.contentOffset.y) <= 1)
        #expect(abs(visibleRect.width - editorView.bounds.width) <= 1)
        #expect(abs(visibleRect.height - editorView.bounds.height) <= 1)

        let visibleMidPoint = CGPoint(
            x: editorView.bounds.midX,
            y: editorView.bounds.minY + iOSEditorLineMidY(editorView, lineIndex: 2)
        )
        guard let position = editorView.closestPosition(to: visibleMidPoint) else {
            Issue.record("SyntaxEditorView could not resolve a scrolled visible text-input point")
            return
        }

        let location = editorView.offset(from: editorView.beginningOfDocument, to: position)
        #expect(location > 0)
        #expect(location < longSyntaxEditorMultilineText.utf16.count)
    }

    @Test("SyntaxEditorView grows horizontal content size after observed iOS text update")
    @MainActor
    func syntaxEditorViewIOSObservedLongTextUpdateGrowsHorizontalContentSize() async {
        let model = SyntaxEditorTestContext(
            text: "let short = true",
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)

        model.model.replaceText(longSyntaxEditorLine)

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.text == longSyntaxEditorLine)
        layoutIOSEditorView(editorView)
        #expect(iOSEditorHasHorizontalOverflow(editorView))
    }

    @Test("SyntaxEditorView grows horizontal content size after direct iOS text assignment")
    @MainActor
    func syntaxEditorViewIOSDirectTextAssignmentGrowsHorizontalContentSize() {
        let model = SyntaxEditorTestContext(
            text: "let short = true",
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)

        editorView.text = longSyntaxEditorLine

        #expect(model.model.text == longSyntaxEditorLine)
        layoutIOSEditorView(editorView)
        #expect(iOSEditorHasHorizontalOverflow(editorView))
    }

    @Test("SyntaxEditorView keeps iOS scroll position while editing")
    @MainActor
    func syntaxEditorViewIOSKeepsScrollPositionWhileEditing() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        editorView.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        #expect(editorView.contentOffset.x > 0)

        let insertionLocation = visibleMidSyntaxEditorLocation
        #expect(insertionLocation > 0)
        #expect(insertionLocation < longSyntaxEditorLine.utf16.count)

        editorView.selectedRange = NSRange(location: insertionLocation, length: 0)
        layoutIOSEditorView(editorView)
        let stableOffsetX = editorView.contentOffset.x
        #expect(stableOffsetX > 0)

        editorView.insertText("x")
        layoutIOSEditorView(editorView)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView does not rebuild iOS line metrics during resize")
    @MainActor
    func syntaxEditorViewIOSResizeDoesNotRebuildLineMetrics() {
        let source = (0..<2_000)
            .map { index in
                index == 1_500 ? longSyntaxEditorLine : "let value\(index) = \(index)"
            }
            .joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 720, height: 300)

        let rebuildCount = editorView.lineMetricsFullRebuildCountForTesting
        layoutIOSEditorView(editorView, width: 360, height: 300)
        layoutIOSEditorView(editorView, width: 640, height: 300)

        #expect(editorView.lineMetricsFullRebuildCountForTesting == rebuildCount)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
    }

    @Test("SyntaxEditorView keeps iOS scroll position while moving cursor")
    @MainActor
    func syntaxEditorViewIOSKeepsScrollPositionWhileMovingCursor() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        editorView.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        let stableOffsetX = editorView.contentOffset.x
        #expect(stableOffsetX > 0)

        let targetLocation = visibleMidSyntaxEditorLocation
        #expect(targetLocation > 0)
        #expect(targetLocation < longSyntaxEditorLine.utf16.count)

        editorView.selectedRange = NSRange(location: targetLocation, length: 0)
        layoutIOSEditorView(editorView)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView keeps native iOS bounce enabled")
    @MainActor
    func syntaxEditorViewIOSKeepsNativeBounceEnabled() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        #expect(editorView.bounces)
        #expect(editorView.alwaysBounceVertical)
    }

    @Test("SyntaxEditorView scrolls iOS ranges through the single text view")
    @MainActor
    func syntaxEditorViewIOSScrollsRangesThroughSingleTextView() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        editorView.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        let stableOffsetX = editorView.contentOffset.x
        #expect(stableOffsetX > 0)

        let targetLocation = max(0, longSyntaxEditorLine.utf16.count - 1)
        #expect(editorView.position(
            from: editorView.beginningOfDocument,
            offset: targetLocation
        ) != nil)

        let scrollRangeToVisible: (NSRange) -> Void = editorView.scrollRangeToVisible
        scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
        layoutIOSEditorView(editorView)

        #expect(editorView.contentOffset.x > stableOffsetX)
    }

    @Test("SyntaxEditorView scrolls iOS ranges outside adjusted right inset")
    @MainActor
    func syntaxEditorViewIOSScrollsRangesOutsideAdjustedRightInset() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 44)
        layoutIOSEditorView(editorView)

        let targetLocation = max(0, longSyntaxEditorLine.utf16.count - 1)
        guard let position = editorView.position(
            from: editorView.beginningOfDocument,
            offset: targetLocation
        ) else {
            Issue.record("SyntaxEditorView could not resolve the inset scroll target")
            return
        }

        let targetRect = editorView.caretRect(for: position)
        editorView.scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
        layoutIOSEditorView(editorView)

        let insets = editorView.adjustedContentInset
        let visibleWidth = editorView.bounds.width - insets.left - insets.right
        let visibleMaxX = editorView.contentOffset.x + insets.left + visibleWidth
        #expect(insets.right >= 44)
        #expect(editorView.contentOffset.x > 0)
        #expect(targetRect.maxX <= visibleMaxX + 1)
    }

    @Test("SyntaxEditorView includes iOS horizontal insets in TextKit viewport bounds")
    @MainActor
    func syntaxEditorViewIOSIncludesHorizontalInsetsInViewportBounds() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.contentInset = UIEdgeInsets(top: 3, left: 5, bottom: 7, right: 11)
        editorView.textContainerInset = UIEdgeInsets(top: 13, left: 17, bottom: 19, right: 23)
        layoutIOSEditorView(editorView)

        guard let textLayoutManager = editorView.textLayoutManager else {
            Issue.record("SyntaxEditorView has no TextKit layout manager")
            return
        }

        let viewportBounds = editorView.viewportBounds(
            for: textLayoutManager.textViewportLayoutController
        )
        let insets = editorView.adjustedContentInset
        let expectedBounds = CGRect(
            x: editorView.bounds.origin.x - insets.left - editorView.textContainerInset.left,
            y: editorView.bounds.origin.y - insets.top - editorView.textContainerInset.top,
            width: editorView.bounds.width
                + insets.left
                + insets.right
                + editorView.textContainerInset.left
                + editorView.textContainerInset.right,
            height: editorView.bounds.height
                + insets.top
                + insets.bottom
                + editorView.textContainerInset.top
                + editorView.textContainerInset.bottom
        )

        #expect(viewportBounds == expectedBounds)
    }

    @Test("SyntaxEditorView sizes short iOS content to adjusted visible area")
    @MainActor
    func syntaxEditorViewIOSShortContentTracksAdjustedVisibleArea() {
        let insetCases = [
            UIEdgeInsets(top: 54, left: 0, bottom: 12, right: 0),
            UIEdgeInsets(top: 16, left: 24, bottom: 28, right: 36),
            UIEdgeInsets(top: 0, left: 40, bottom: 44, right: 12),
        ]

        for lineWrappingEnabled in [true, false] {
            for contentInset in insetCases {
                let model = SyntaxEditorTestContext(
                    text: #"{"result":"ok"}"#,
                    language: SyntaxLanguage.json,
                    lineWrappingEnabled: lineWrappingEnabled
                )
                let editorView = SyntaxEditorView(testContext: model)
                editorView.contentInset = contentInset
                layoutIOSEditorView(editorView, width: 360, height: 240)

                let visibleSize = iOSAdjustedVisibleSize(editorView)
                let maximumContentOffset = iOSMaximumContentOffset(editorView)
                let expectedTextContentSize = iOSExpectedTextContentSize(editorView)
                let expectedContainerWidth = max(
                    0,
                    visibleSize.width - editorView.textContainerInset.left - editorView.textContainerInset.right
                )

                #expect(approximatelyEqualIOS(editorView.contentSize.width, visibleSize.width))
                #expect(approximatelyEqualIOS(editorView.contentSize.height, visibleSize.height))
                #expect(approximatelyEqualIOS(maximumContentOffset.x, -editorView.adjustedContentInset.left))
                #expect(approximatelyEqualIOS(maximumContentOffset.y, -editorView.adjustedContentInset.top))
                #expect(approximatelyEqualIOS(editorView.textContainer.size.width, expectedContainerWidth))
                #expect(approximatelyEqualIOS(editorView.renderedTextContentFrameForTesting.width, expectedTextContentSize.width))
                #expect(approximatelyEqualIOS(editorView.renderedTextContentFrameForTesting.height, expectedTextContentSize.height))
            }
        }
    }

    @Test("SyntaxEditorView wraps long iOS content to adjusted visible width")
    @MainActor
    func syntaxEditorViewIOSWrappedLongContentTracksAdjustedVisibleWidth() {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let insetAwareWrappingWidth = true; ", count: 40),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.contentInset = UIEdgeInsets(top: 54, left: 48, bottom: 30, right: 24)
        layoutIOSEditorView(editorView, width: 260, height: 180)

        let visibleSize = iOSAdjustedVisibleSize(editorView)
        let maximumContentOffset = iOSMaximumContentOffset(editorView)
        let expectedContainerWidth = max(
            0,
            visibleSize.width - editorView.textContainerInset.left - editorView.textContainerInset.right
        )

        #expect(editorView.textContainer.widthTracksTextView)
        #expect(approximatelyEqualIOS(editorView.contentSize.width, visibleSize.width))
        #expect(editorView.contentSize.height > visibleSize.height + 1)
        #expect(approximatelyEqualIOS(editorView.textContainer.size.width, expectedContainerWidth))
        #expect(approximatelyEqualIOS(maximumContentOffset.x, -editorView.adjustedContentInset.left))
        #expect(maximumContentOffset.y > -editorView.adjustedContentInset.top)
    }

    @Test("SyntaxEditorView keeps unwrapped iOS content height tied to adjusted visible height")
    @MainActor
    func syntaxEditorViewIOSUnwrappedLongContentTracksAdjustedVisibleHeight() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.contentInset = UIEdgeInsets(top: 32, left: 40, bottom: 36, right: 44)
        layoutIOSEditorView(editorView, width: 260, height: 180)

        let visibleSize = iOSAdjustedVisibleSize(editorView)
        let maximumContentOffset = iOSMaximumContentOffset(editorView)
        let expectedTextContentSize = iOSExpectedTextContentSize(editorView)

        #expect(!editorView.textContainer.widthTracksTextView)
        #expect(editorView.contentSize.width > visibleSize.width + 1)
        #expect(approximatelyEqualIOS(editorView.contentSize.height, visibleSize.height))
        #expect(maximumContentOffset.x > -editorView.adjustedContentInset.left)
        #expect(approximatelyEqualIOS(maximumContentOffset.y, -editorView.adjustedContentInset.top))
        #expect(approximatelyEqualIOS(editorView.renderedTextContentFrameForTesting.width, expectedTextContentSize.width))
        #expect(approximatelyEqualIOS(editorView.renderedTextContentFrameForTesting.height, expectedTextContentSize.height))
    }

    @Test("SyntaxEditorView recomputes iOS wrapping geometry after adjusted inset changes")
    @MainActor
    func syntaxEditorViewIOSWrappingGeometryTracksAdjustedInsetChanges() {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let resizedInsetAwareWrappingWidth = true; ", count: 24),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 360, height: 240)

        let initialContainerWidth = editorView.textContainer.size.width

        editorView.contentInset = UIEdgeInsets(top: 20, left: 36, bottom: 44, right: 52)
        layoutIOSEditorView(editorView, width: 360, height: 240)

        let visibleSize = iOSAdjustedVisibleSize(editorView)
        let expectedContainerWidth = max(
            0,
            visibleSize.width - editorView.textContainerInset.left - editorView.textContainerInset.right
        )

        #expect(editorView.textContainer.widthTracksTextView)
        #expect(editorView.textContainer.size.width < initialContainerWidth)
        #expect(approximatelyEqualIOS(editorView.contentSize.width, visibleSize.width))
        #expect(approximatelyEqualIOS(editorView.textContainer.size.width, expectedContainerWidth))
        #expect(editorView.contentSize.height >= visibleSize.height)
    }

    @Test("SyntaxEditorView does not double-count adjusted iOS insets when ensuring content size")
    @MainActor
    func syntaxEditorViewIOSContentSizeEnsuringDoesNotDoubleCountInsets() {
        let model = SyntaxEditorTestContext(
            text: #"{"result":"ok"}"#,
            language: SyntaxLanguage.json,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.contentInset = UIEdgeInsets(top: 24, left: 28, bottom: 36, right: 40)
        layoutIOSEditorView(editorView, width: 260, height: 180)

        let targetRect = CGRect(
            x: 0,
            y: 0,
            width: editorView.contentSize.width + 31,
            height: editorView.contentSize.height + 29
        )

        editorView.scrollContentRectToVisible(targetRect)

        #expect(approximatelyEqualIOS(editorView.contentSize.width, ceil(targetRect.maxX)))
        #expect(approximatelyEqualIOS(editorView.contentSize.height, ceil(targetRect.maxY)))
    }

    @Test("SyntaxEditorView keeps iOS horizontal offset after visible cursor click")
    @MainActor
    func syntaxEditorViewIOSKeepsHorizontalOffsetAfterVisibleCursorClick() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        editorView.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        let targetLocation = visibleMidSyntaxEditorLocation
        #expect(targetLocation > 0)
        #expect(targetLocation < longSyntaxEditorLine.utf16.count)
        editorView.selectedRange = NSRange(location: targetLocation, length: 0)
        layoutIOSEditorView(editorView)

        let stableOffsetX = editorView.contentOffset.x
        editorView.selectedRange = NSRange(location: targetLocation, length: 0)
        layoutIOSEditorView(editorView)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView does not horizontally scroll after repeated visible iOS selection updates")
    @MainActor
    func syntaxEditorViewIOSDoesNotScrollHorizontallyAfterRepeatedVisibleSelectionUpdates() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        editorView.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        let stableOffsetX = editorView.contentOffset.x
        #expect(stableOffsetX > 0)

        let targetLocation = visibleMidSyntaxEditorLocation
        editorView.selectedRange = NSRange(location: targetLocation, length: 0)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: targetLocation, length: 0)
        layoutIOSEditorView(editorView)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
    }

    @Test("SyntaxEditorView keeps iOS horizontal offset after native content-space tap selection")
    @MainActor
    func syntaxEditorViewIOSKeepsHorizontalOffsetAfterNativeContentSpaceTapSelection() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.contentSize.width > editorView.bounds.width + 1)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        let stableOffsetX = editorView.contentOffset.x
        #expect(stableOffsetX > 0)

        let tapPoint = CGPoint(x: stableOffsetX + 200, y: iOSEditorLineMidY(editorView, lineIndex: 2))
        guard let position = editorView.closestPosition(to: tapPoint),
              let textRange = editorView.textRange(from: position, to: position)
        else {
            Issue.record("SyntaxEditorView could not resolve a native tap point")
            return
        }

        editorView.selectedTextRange = textRange
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
        guard let renderedContentFrame = iOSEditorRenderedContentFrame(editorView) else {
            Issue.record("SyntaxEditorView does not expose a rendered content frame")
            return
        }
        #expect(renderedContentFrame.width >= editorView.contentSize.width - 1)
        #expect(renderedContentFrame.maxX >= editorView.contentOffset.x + editorView.bounds.width - 1)
        #expect(
            editorTextLayoutUsageBoundsCoverVisibleHorizontalViewport(editorView),
            Comment(rawValue: editorTextLayoutDiagnostics(editorView))
        )
    }

    @Test("SyntaxEditorView supports ranged iOS selection after horizontal scroll")
    @MainActor
    func syntaxEditorViewIOSSupportsRangedSelectionAfterHorizontalScroll() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let stableOffsetX = editorView.contentOffset.x
        let visibleRect = editorView.bounds
        let longLineMidY = iOSEditorLineMidY(editorView, lineIndex: 2)
        let startPoint = CGPoint(x: visibleRect.minX + 120, y: visibleRect.minY + longLineMidY)
        let endPoint = CGPoint(x: visibleRect.minX + 280, y: visibleRect.minY + longLineMidY)

        guard let startPosition = editorView.closestPosition(to: startPoint),
              let endPosition = editorView.closestPosition(to: endPoint),
              let textRange = editorView.textRange(from: startPosition, to: endPosition)
        else {
            Issue.record("SyntaxEditorView could not resolve scrolled ranged selection points")
            return
        }

        editorView.selectedTextRange = textRange
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.selectedRange.length > 0)
        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)

        let selectionRects = editorView.selectionRects(for: textRange)
        #expect(!selectionRects.isEmpty)
        #expect(selectionRects.contains { $0.rect.intersects(visibleRect) })

        #expect(editorView.contentSize.width >= editorView.contentOffset.x + editorView.bounds.width - 1)
    }

    @Test("SyntaxEditorView updates ranged iOS selection after horizontal scroll")
    @MainActor
    func syntaxEditorViewIOSUpdatesRangedSelectionAfterHorizontalScroll() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorMultilineText,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        editorView.setContentOffset(CGPoint(x: iOSEditorStableHorizontalOffset(editorView), y: 0), animated: false)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let longLineMidY = iOSEditorLineMidY(editorView, lineIndex: 2)
        let viewportStartPoint = CGPoint(x: 120, y: longLineMidY)
        let viewportEndPoint = CGPoint(x: 280, y: longLineMidY)
        let extendedViewportEndPoint = CGPoint(x: 340, y: longLineMidY)

        guard let viewportStartPosition = editorView.closestPosition(to: viewportStartPoint),
              let viewportEndPosition = editorView.closestPosition(to: viewportEndPoint),
              let extendedViewportEndPosition = editorView.closestPosition(to: extendedViewportEndPoint)
        else {
            Issue.record("SyntaxEditorView could not resolve viewport-local selection points")
            return
        }

        guard let viewportTextRange = editorView.textRange(from: viewportStartPosition, to: viewportEndPosition),
              let documentRange = editorView.textRange(from: editorView.beginningOfDocument, to: editorView.endOfDocument),
              let constrainedViewportEndPosition = editorView.closestPosition(to: viewportEndPoint, within: documentRange),
              let characterRange = editorView.characterRange(at: viewportStartPoint)
        else {
            Issue.record("SyntaxEditorView could not resolve viewport-local ranged selection helpers")
            return
        }

        editorView.selectedTextRange = viewportTextRange
        layoutIOSEditorView(editorView, width: 393, height: 658)
        let initialSelectionLength = editorView.selectedRange.length

        guard let extendedTextRange = editorView.textRange(
            from: viewportStartPosition,
            to: extendedViewportEndPosition
        ) else {
            Issue.record("SyntaxEditorView could not extend a viewport-local ranged selection")
            return
        }

        editorView.selectedTextRange = extendedTextRange
        layoutIOSEditorView(editorView, width: 393, height: 658)

        #expect(editorView.selectedRange.length > 0)
        #expect(editorView.selectedRange.length >= initialSelectionLength)
        #expect(editorView.offset(from: editorView.beginningOfDocument, to: constrainedViewportEndPosition) ==
            editorView.offset(from: editorView.beginningOfDocument, to: viewportEndPosition))
        let characterRangeStartOffset = editorView.offset(
            from: editorView.beginningOfDocument,
            to: characterRange.start
        )
        let viewportStartOffset = editorView.offset(
            from: editorView.beginningOfDocument,
            to: viewportStartPosition
        )
        #expect(abs(characterRangeStartOffset - viewportStartOffset) <= 1)
    }

    @Test("SyntaxEditorView keeps iOS closest position inside collapsed constrained range")
    @MainActor
    func syntaxEditorViewIOSKeepsClosestPositionInsideCollapsedConstrainedRange() {
        let source = "abcdef\nuvwxyz"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let constrainedPosition = editorView.position(from: editorView.beginningOfDocument, offset: 2),
              let constrainedRange = editorView.textRange(from: constrainedPosition, to: constrainedPosition),
              let closestPosition = editorView.closestPosition(to: CGPoint(x: 250, y: 80), within: constrainedRange)
        else {
            Issue.record("SyntaxEditorView could not resolve a collapsed constrained closest position")
            return
        }

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: closestPosition) == 2)
    }

    @Test("SyntaxEditorView clamps iOS character-offset positions to supplied range")
    @MainActor
    func syntaxEditorViewIOSClampsCharacterOffsetPositionsToSuppliedRange() {
        let source = "abcdef"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        guard let rangeStart = editorView.position(from: editorView.beginningOfDocument, offset: 1),
              let rangeEnd = editorView.position(from: editorView.beginningOfDocument, offset: 4),
              let range = editorView.textRange(from: rangeStart, to: rangeEnd),
              let beforeRange = editorView.position(within: range, atCharacterOffset: -3),
              let afterRange = editorView.position(within: range, atCharacterOffset: 10)
        else {
            Issue.record("SyntaxEditorView could not resolve range-constrained character offsets")
            return
        }

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: beforeRange) == 1)
        #expect(editorView.offset(from: editorView.beginningOfDocument, to: afterRange) == 4)
    }

    @Test("SyntaxEditorView resolves iOS character-offset positions by composed characters")
    @MainActor
    func syntaxEditorViewIOSResolvesCharacterOffsetPositionsByComposedCharacters() {
        let source = "🙂a"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        guard let range = editorView.textRange(
            from: editorView.beginningOfDocument,
            to: editorView.endOfDocument
        ),
              let afterEmoji = editorView.position(within: range, atCharacterOffset: 1),
              let afterEnd = editorView.position(within: range, atCharacterOffset: 10)
        else {
            Issue.record("SyntaxEditorView could not resolve composed character offsets")
            return
        }

        #expect(editorView.offset(from: editorView.beginningOfDocument, to: afterEmoji) == ("🙂" as NSString).length)
        #expect(editorView.offset(from: editorView.beginningOfDocument, to: afterEnd) == source.utf16.count)
        #expect(editorView.characterOffset(of: afterEmoji, within: range) == 1)
        #expect(editorView.characterOffset(of: afterEnd, within: range) == 2)
    }

    @Test("SyntaxEditorView clears stale horizontal content size after iOS wrapping toggles")
    @MainActor
    func syntaxEditorViewIOSWrappingToggleClearsStaleHorizontalContentSize() async {
        let source = String(repeating: "let wrappingHeightMustTrackVisualLines = true; ", count: 48)
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)

        layoutIOSEditorView(editorView, width: 240, height: 140)
        let wrappedHeight = editorView.contentSize.height
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
        #expect(wrappedHeight > editorView.bounds.height + 400)

        model.model.lineWrappingEnabled = false

        editorView.synchronizeDocumentForTesting()
        #expect(!editorView.textContainer.widthTracksTextView)
        layoutIOSEditorView(editorView, width: 240, height: 140)
        let unwrappedHeight = editorView.contentSize.height
        #expect(unwrappedHeight < wrappedHeight - 400)
        let restoredHorizontalOverflow = iOSEditorHasHorizontalOverflow(editorView)
        if !restoredHorizontalOverflow {
            Issue.record(Comment(rawValue: iOSEditorHorizontalOverflowDiagnostics(editorView)))
        }
        #expect(restoredHorizontalOverflow)

        editorView.setContentOffset(CGPoint(x: 24, y: 0), animated: false)
        #expect(editorView.contentOffset.x > 0)

        model.model.lineWrappingEnabled = true

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textContainer.widthTracksTextView)
        layoutIOSEditorView(editorView, width: 240, height: 140)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
        #expect(editorView.contentSize.height > unwrappedHeight + 400)
    }

    @Test("SyntaxEditorView keeps selection and copy available while read-only on iOS")
    @MainActor
    func syntaxEditorViewIOSReadOnlyKeepsSelectionAndCopy() {
        let source = "copy me"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            isEditable: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.isSelectable = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.addSubview(editorView)
        window.makeKeyAndVisible()

        #expect(editorView.becomeFirstResponder())
        #expect(editorView.isFirstResponder)

        let selectedRange = NSRange(location: 0, length: 4)
        editorView.selectedRange = selectedRange

        withExtendedLifetime(window) {
            #expect(editorView.isSelectable)
            #expect(editorView.selectedRange == selectedRange)
            #expect(editorView.canPerformAction(
                #selector(UIResponderStandardEditActions.copy(_:)),
                withSender: nil
            ))
        }

        #expect(editorView.resignFirstResponder())
        #expect(!editorView.isFirstResponder)
    }
}
#endif
