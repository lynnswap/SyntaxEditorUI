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
    @Test("SyntaxEditorViewController renders source-of-truth state on iOS")
    @MainActor
    func syntaxEditorViewControllerIOSRendersSourceOfTruthState() async {
        let model = SyntaxEditorTestContext(text: "{}", language: SyntaxLanguage.javascript)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()

        #expect(controller.model === model.model)
        #expect(controller.editorView.model === model.model)

        guard let delivery = controller.editorView.modelDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorViewController to expose its production model delivery")
            return
        }
        let renderedText = await delivery.values {
            controller.editorView.text
        }

        #expect(await renderedText.waitUntilValue("{}"))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))

        let originalEditorView = controller.editorView
        let replacementModel = SyntaxEditorModel(text: "let replacement = true", language: SyntaxLanguage.swift)

        controller.update(model: replacementModel)

        #expect(controller.editorView === originalEditorView)
        #expect(controller.editorView.model === replacementModel)
        #expect(delivery.isActive == false)

        guard let replacementDelivery = controller.editorView.modelDeliveryForTesting else {
            Issue.record("Expected replacement model delivery")
            return
        }
        let replacementRenderedText = await replacementDelivery.values {
            controller.editorView.text
        }
        #expect(await replacementRenderedText.waitUntilValue("let replacement = true"))
    }

    @Test("SyntaxEditorView is the iOS custom scroll text input surface")
    @MainActor
    func syntaxEditorViewIOSUsesCustomScrollTextInputSurface() {
        let editorView = SyntaxEditorView(testContext: SyntaxEditorTestContext(text: "let value = 1"))
        let scrollSurface: UIScrollView = editorView
        let textInputSurface: any UITextInput = editorView

        #expect(scrollSurface === editorView)
        #expect(textInputSurface.textInputView === editorView)
        #expect(editorView.keyboardType == .default)
    }

    @Test("SyntaxEditorView applies transformed iOS text input to the document")
    @MainActor
    func syntaxEditorViewIOSAppliesTransformedTextInputToDocument() {
        let model = SyntaxEditorTestContext(text: "", language: SyntaxLanguage.javascript)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        editorView.insertText("{")
        #expect(editorView.text == "{}")
        #expect(model.model.text == "{}")
        #expect(editorView.selectedRange == NSRange(location: 1, length: 0))

        editorView.insertText("\n")
        #expect(editorView.text == "{\n    \n}")
        #expect(model.model.text == "{\n    \n}")
        #expect(editorView.selectedRange == NSRange(location: 6, length: 0))
    }

    @Test("SyntaxEditorView notifies the iOS input delegate for transformed text input")
    @MainActor
    func syntaxEditorViewIOSNotifiesInputDelegateForTransformedTextInput() {
        let model = SyntaxEditorTestContext(text: "", language: SyntaxLanguage.javascript)
        let editorView = SyntaxEditorView(testContext: model)
        let inputDelegate = SyntaxEditorUITestInputDelegate()
        editorView.inputDelegate = inputDelegate
        layoutIOSEditorView(editorView)

        editorView.insertText("{")

        #expect(inputDelegate.textWillChangeCount == 1)
        #expect(inputDelegate.textDidChangeCount == 1)
        #expect(inputDelegate.selectionWillChangeCount == 1)
        #expect(inputDelegate.selectionDidChangeCount == 1)
    }

    @Test("SyntaxEditorView exposes active iOS marked text during input delegate updates")
    @MainActor
    func syntaxEditorViewIOSMarkedTextRangeIsCurrentDuringInputDelegateUpdate() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let inputDelegate = SyntaxEditorUITestInputDelegate()
        var observedMarkedRange: NSRange?
        inputDelegate.textDidChangeHandler = { textInput in
            guard let editorView = textInput as? SyntaxEditorView,
                  let markedRange = editorView.markedTextRange as? SyntaxEditorView.TextRange
            else {
                return
            }
            observedMarkedRange = markedRange.nsRange
        }
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editorView.inputDelegate = inputDelegate

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))

        #expect(observedMarkedRange == NSRange(location: source.utf16.count, length: "かな".utf16.count))
        #expect(inputDelegate.textWillChangeCount == 1)
        #expect(inputDelegate.textDidChangeCount == 1)
        #expect(inputDelegate.selectionWillChangeCount == 1)
        #expect(inputDelegate.selectionDidChangeCount == 1)
    }

    @Test("SyntaxEditorView handles iOS candidate alternative text input")
    @MainActor
    func syntaxEditorViewIOSHandlesCandidateAlternativeTextInput() {
        let source = "let value ="
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        #expect(editorView.responds(to: NSSelectorFromString("insertText:alternatives:style:")))
        editorView.insertText(" ", alternatives: [], style: .none)

        #expect(editorView.text == source + " ")
        #expect(model.model.text == source + " ")
        #expect(editorView.selectedRange == NSRange(location: source.utf16.count + 1, length: 0))
    }

    @Test("SyntaxEditorView underlines active iOS marked text")
    @MainActor
    func syntaxEditorViewIOSUnderlinesActiveMarkedText() {
        let model = SyntaxEditorTestContext(text: "let value = ", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let markedTextColor = syntaxEditorUITestColor(hex: 0xFF8800)
        editorView.tintColor = markedTextColor
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: model.model.text.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))

        let markedLocation = "let value = ".utf16.count
        #expect(editorView.markedTextRange != nil)
        #expect(iOSEditorUnderlineStyle(editorView, at: markedLocation) == NSUnderlineStyle.single.rawValue)
        #expect(syntaxEditorUITestColorsEqual(iOSEditorUnderlineColor(editorView, at: markedLocation), markedTextColor))

        editorView.unmarkText()

        #expect(editorView.markedTextRange == nil)
        #expect(iOSEditorUnderlineStyle(editorView, at: markedLocation) == nil)
    }

    @Test("SyntaxEditorView scrolls iOS marked text using the final IME selection")
    @MainActor
    func syntaxEditorViewIOSScrollsMarkedTextUsingFinalIMESelection() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 160, height: 120)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        let stableOffsetX = editorView.contentOffset.x
        editorView.setMarkedText(
            String(repeating: "かな", count: 80),
            selectedRange: NSRange(location: 0, length: 2)
        )
        layoutIOSEditorView(editorView, width: 160, height: 120)

        #expect(abs(editorView.contentOffset.x - stableOffsetX) <= 1)
        #expect(editorView.selectedRange == NSRange(location: source.utf16.count, length: 2))
    }

    @Test("SyntaxEditorView registers iOS undo for committed marked text")
    @MainActor
    func syntaxEditorViewIOSRegistersUndoForCommittedMarkedText() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        editorView.unmarkText()

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(editorView.text == source)
        #expect(model.model.text == source)
        #expect(editorView.selectedRange == NSRange(location: source.utf16.count, length: 0))
    }

    @Test("SyntaxEditorView registers iOS undo for empty marked text replacement")
    @MainActor
    func syntaxEditorViewIOSRegistersUndoForEmptyMarkedTextReplacement() {
        let source = "let value = 42"
        let selectedRange = (source as NSString).range(of: "value")
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = selectedRange

        editorView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(editorView.text == "let  = 42")
        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(editorView.text == source)
        #expect(model.model.text == source)
        #expect(editorView.selectedRange == selectedRange)
    }

    @Test("SyntaxEditorView replaces iOS marked text when IME commits through insertText")
    @MainActor
    func syntaxEditorViewIOSReplacesMarkedTextWhenIMECommitsThroughInsertText() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("あいうえお", selectedRange: NSRange(location: 5, length: 0))
        editorView.insertText("作成")

        let committedSource = source + "作成"
        #expect(editorView.markedTextRange == nil)
        #expect(editorView.text == committedSource)
        #expect(model.model.text == committedSource)
        #expect(editorView.selectedRange == NSRange(location: committedSource.utf16.count, length: 0))

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(editorView.text == source)
        #expect(model.model.text == source)
    }

    @Test("SyntaxEditorView clears iOS marked text before normal insertion after IME commit")
    @MainActor
    func syntaxEditorViewIOSClearsMarkedTextBeforeNormalInsertionAfterIMECommit() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("あいうえお", selectedRange: NSRange(location: 5, length: 0))
        editorView.insertText("作成")
        editorView.insertText("!")

        let expectedSource = source + "作成!"
        #expect(editorView.markedTextRange == nil)
        #expect(editorView.text == expectedSource)
        #expect(model.model.text == expectedSource)
        #expect(editorView.selectedRange == NSRange(location: expectedSource.utf16.count, length: 0))
    }

    @Test("SyntaxEditorView preserves iOS marked text when nil unmarks composition")
    @MainActor
    func syntaxEditorViewIOSPreservesMarkedTextWhenNilUnmarksComposition() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        editorView.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))

        let expectedText = source + "かな"
        #expect(editorView.markedTextRange == nil)
        #expect(editorView.text == expectedText)
        #expect(model.model.text == expectedText)
        #expect(editorView.selectedRange == NSRange(location: expectedText.utf16.count, length: 0))
    }

    @Test("SyntaxEditorView clears iOS marked text when selection leaves composition")
    @MainActor
    func syntaxEditorViewIOSClearsMarkedTextWhenSelectionLeavesComposition() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        editorView.selectedTextRange = editorView.textRange(
            from: editorView.beginningOfDocument,
            to: editorView.beginningOfDocument
        )
        editorView.insertText("X")

        #expect(editorView.markedTextRange == nil)
        #expect(editorView.text == "X" + source + "かな")
        #expect(model.model.text == "X" + source + "かな")
        #expect(editorView.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("SyntaxEditorView clears iOS marked text when selectedRange leaves composition")
    @MainActor
    func syntaxEditorViewIOSClearsMarkedTextWhenSelectedRangeLeavesComposition() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        editorView.selectedRange = NSRange(location: 0, length: 0)
        editorView.insertText("X")

        #expect(editorView.markedTextRange == nil)
        #expect(editorView.text == "X" + source + "かな")
        #expect(model.model.text == "X" + source + "かな")
        #expect(editorView.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("SyntaxEditorView does not commit iOS marked text while read-only")
    @MainActor
    func syntaxEditorViewIOSDoesNotCommitMarkedTextWhileReadOnly() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        model.model.isEditable = false
        editorView.synchronizeDocumentForTesting()
        editorView.insertText("作成")

        #expect(editorView.text == source + "かな")
        #expect(model.model.text == source + "かな")
        #expect(editorView.markedTextRange != nil)
    }

    @Test("SyntaxEditorView coalesces repeated iOS marked text updates into one undo")
    @MainActor
    func syntaxEditorViewIOSCoalescesRepeatedMarkedTextUpdatesIntoOneUndo() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
        editorView.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
        editorView.setMarkedText("あいう", selectedRange: NSRange(location: 3, length: 0))
        editorView.unmarkText()

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(editorView.text == source + "あいう")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(editorView.text == source)
        #expect(!undoManager.canUndo)
    }

    @Test("SyntaxEditorView clears stale iOS marked text undo anchors after normal edits")
    @MainActor
    func syntaxEditorViewIOSClearsStaleMarkedTextUndoAnchorsAfterNormalEdits() {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        editorView.deleteBackward()

        let textAfterInterruptedComposition = editorView.text
        let selectionAfterInterruptedComposition = editorView.selectedRange
        #expect(textAfterInterruptedComposition == source + "か")
        #expect(editorView.markedTextRange == nil)
        editorView.undoManager?.removeAllActions()

        editorView.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0))
        editorView.unmarkText()

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(editorView.text == source + "か字")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(editorView.text == textAfterInterruptedComposition)
        #expect(editorView.selectedRange == selectionAfterInterruptedComposition)
    }

    @Test("SyntaxEditorView deletes a complete iOS composed character backward")
    @MainActor
    func syntaxEditorViewIOSDeletesCompleteComposedCharacterBackward() {
        let source = "a🙂b"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: ("a🙂" as NSString).length, length: 0)

        editorView.deleteBackward()

        #expect(editorView.text == "ab")
        #expect(model.model.text == "ab")
        #expect(editorView.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("SyntaxEditorView preserves iOS command state through delayed selection callbacks")
    @MainActor
    func syntaxEditorViewIOSPreservesCommandStateThroughDelayedSelectionCallbacks() {
        let source = "description = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.toml)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        editorView.insertText("\"")
        #expect(editorView.text == source + "\"\"")
        #expect(editorView.selectedRange == NSRange(location: source.utf16.count + 1, length: 0))

        editorView.insertText("\"")
        #expect(editorView.text == source + "\"\"")
        #expect(editorView.selectedRange == NSRange(location: source.utf16.count + 2, length: 0))

        editorView.insertText("\"")

        #expect(editorView.text == source + "\"\"\"")
        #expect(model.model.text == source + "\"\"\"")
        #expect(editorView.selectedRange == NSRange(location: source.utf16.count + 3, length: 0))
    }

    @Test("SyntaxEditorView reflects document text replacements on iOS")
    @MainActor
    func syntaxEditorViewIOSTextObservation() async {
        let model = SyntaxEditorTestContext(text: "const answer = 42;", language: SyntaxLanguage.javascript)
        let editorView = SyntaxEditorView(testContext: model)
        guard let delivery = editorView.modelDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorView to expose its production document delivery")
            return
        }
        let renderedText = await delivery.values {
            editorView.text
        }

        #expect(await renderedText.waitUntilValue("const answer = 42;"))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))
    }

    @Test("SyntaxEditorView does not rerun iOS configuration observation for document changes")
    @MainActor
    func syntaxEditorViewIOSConfigurationObservationIgnoresDocumentChanges() async {
        let model = SyntaxEditorTestContext(text: "const answer = 42;", language: SyntaxLanguage.javascript)
        let editorView = SyntaxEditorView(testContext: model)
        guard let configurationDelivery = editorView.modelConfigurationDeliveryForTesting,
              let documentDelivery = editorView.modelDeliveryForTesting
        else {
            Issue.record("Expected SyntaxEditorView to expose its production deliveries")
            return
        }
        let configurationPassCounter = SyntaxEditorObservationPassCounter()
        let configurationPasses = await configurationDelivery.values {
            configurationPassCounter.next()
        }
        let renderedText = await documentDelivery.values {
            editorView.text
        }

        #expect(await configurationPasses.waitUntilValue(1))

        model.model.language = SyntaxLanguage.json

        #expect(await configurationPasses.waitUntilValue(2))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))
        await syntaxEditorDrainMainActorObservationDelivery(recording: configurationPasses)
        #expect(configurationPasses.snapshot() == [1, 2])
    }

    @Test("SyntaxEditorView clamps iOS horizontal offset after observed text replacement")
    @MainActor
    func syntaxEditorViewIOSClampsHorizontalOffsetAfterObservedTextReplacement() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.scrollRangeToVisible(NSRange(location: longSyntaxEditorLine.utf16.count - 1, length: 0))
        layoutIOSEditorView(editorView)
        #expect(editorView.contentOffset.x > 0)

        model.model.replaceText("let value = 42")
        editorView.synchronizeDocumentForTesting()
        layoutIOSEditorView(editorView)

        #expect(editorView.text == "let value = 42")
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
        #expect(editorView.contentOffset.x <= 1)
    }

    @Test("SyntaxEditorView reflects editable and wrapping changes on iOS")
    @MainActor
    func syntaxEditorViewIOSEditorStateObservation() async {
        let model = SyntaxEditorTestContext(text: longSyntaxEditorLine, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        guard let delivery = editorView.modelConfigurationDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorView to expose its production configuration delivery")
            return
        }
        let renderedState = await delivery.values {
            SyntaxEditorRenderedEditorState(
                isEditable: editorView.isEditable,
                wrapsLines: editorView.textContainer.widthTracksTextView
            )
        }

        model.model.isEditable = false
        model.model.lineWrappingEnabled = true

        #expect(
            await renderedState.waitUntilValue(
                SyntaxEditorRenderedEditorState(isEditable: false, wrapsLines: true)
            )
        )
        layoutIOSEditorView(editorView)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
        #expect(editorView.contentSize.height > editorView.bounds.height + 1)
        #expect(iOSEditorLineBreakMode(editorView) == .byCharWrapping)

        model.model.lineWrappingEnabled = false

        #expect(
            await renderedState.waitUntilValue(
                SyntaxEditorRenderedEditorState(isEditable: false, wrapsLines: false)
            )
        )
        layoutIOSEditorView(editorView)
        #expect(editorView.contentSize.width > editorView.bounds.width + 1)
        #expect(editorView.textContainer.size.width > editorView.bounds.width)
        #expect(iOSEditorLineBreakMode(editorView) == .byClipping)

        editorView.setContentOffset(CGPoint(x: 24, y: 0), animated: false)
        #expect(editorView.contentOffset.x > 0)

        model.model.lineWrappingEnabled = true

        let finalRenderedState = await delivery.values {
            SyntaxEditorRenderedEditorState(
                isEditable: editorView.isEditable,
                wrapsLines: editorView.textContainer.widthTracksTextView
            )
        }
        #expect(
            await finalRenderedState.waitUntilValue(
                SyntaxEditorRenderedEditorState(isEditable: false, wrapsLines: true)
            )
        )
        layoutIOSEditorView(editorView)
        #expect(editorView.contentSize.width <= editorView.bounds.width + 1)
    }

    @Test("SyntaxEditorView keeps iOS caret on the edited whitespace line after text input")
    @MainActor
    func syntaxEditorViewIOSKeepsCaretOnEditedWhitespaceLineAfterTextInput() {
        let editedLine = "    body { color          : red; }"
        let source = [
            "<style>",
            editedLine,
            "</style>",
            "</head>",
        ].joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.html,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)

        let editedLineStart = (source as NSString).range(of: editedLine).location
        let insertionOffset = editedLineStart + "    body { color".utf16.count
        guard let lineStartPosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: editedLineStart
        ) else {
            Issue.record("SyntaxEditorView could not resolve the edited line start")
            return
        }
        let lineStartRect = editorView.caretRect(for: lineStartPosition)

        editorView.selectedRange = NSRange(location: insertionOffset, length: 0)
        editorView.insertText(".")
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let caretPosition = editorView.selectedTextRange?.start else {
            Issue.record("SyntaxEditorView did not expose a selected text range after whitespace-line input")
            return
        }
        let caretRect = editorView.caretRect(for: caretPosition)

        #expect(editorView.selectedRange == NSRange(location: insertionOffset + 1, length: 0))
        #expect(abs(caretRect.midY - lineStartRect.midY) <= 1)
        #expect(caretRect.midX > lineStartRect.midX)
    }

    @Test("SyntaxEditorView keeps iOS caret stable while repeatedly inserting spaces")
    @MainActor
    func syntaxEditorViewIOSKeepsCaretStableWhileRepeatedlyInsertingSpaces() async {
        let sourceLines = [
            "const answer = 42;",
            "function greet(name) {",
            "    return \"Hello\";",
            "}",
        ]
        let source = sourceLines.joined(separator: "\n")
        let updateGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorUITestHighlighter(updateGate: updateGate)
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.javascript,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        await editorView.waitForPendingHighlightForTesting()

        let editedLineStart = (source as NSString).range(of: sourceLines[2]).location
        let insertionOffset = editedLineStart + sourceLines[2].utf16.count
        guard let editedLinePosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: editedLineStart
        ) else {
            Issue.record("SyntaxEditorView could not resolve the edited line start")
            return
        }
        let editedLineRect = editorView.caretRect(for: editedLinePosition)
        editorView.selectedRange = NSRange(location: insertionOffset, length: 0)

        var previousCaretX = editorView.caretRect(for: SyntaxEditorView.TextPosition(offset: insertionOffset)).midX
        for insertedSpaceCount in 1...12 {
            let previousSuspensionCount = await updateGate.currentSuspensionCount()
            editorView.insertText(" ")
            await updateGate.waitUntilSuspended(after: previousSuspensionCount)
            layoutIOSEditorView(editorView, width: 393, height: 658)
            await Task.yield()

            guard let caretPosition = editorView.selectedTextRange?.start else {
                Issue.record("SyntaxEditorView did not expose a selected text range after space input")
                return
            }
            let caretRect = editorView.caretRect(for: caretPosition)
            #expect(editorView.selectedRange == NSRange(location: insertionOffset + insertedSpaceCount, length: 0))
            #expect(abs(caretRect.midY - editedLineRect.midY) <= 1)
            #expect(caretRect.midX >= previousCaretX)
            previousCaretX = caretRect.midX
        }

        await updateGate.resumeAll()
        await editorView.waitForPendingHighlightForTesting()
        guard let finalCaretPosition = editorView.selectedTextRange?.start else {
            Issue.record("SyntaxEditorView did not expose a selected text range after highlighting")
            return
        }
        let finalCaretRect = editorView.caretRect(for: finalCaretPosition)
        #expect(abs(finalCaretRect.midY - editedLineRect.midY) <= 1)
        #expect(editorView.selectedRange == NSRange(location: insertionOffset + 12, length: 0))
    }

    @Test("SyntaxEditorView places iOS caret on the immediate next line after newline input")
    @MainActor
    func syntaxEditorViewIOSPlacesCaretOnImmediateNextLineAfterNewlineInput() {
        let source = "abcde\n01234"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView, width: 393, height: 658)
        editorView.selectedRange = NSRange(location: "abcde".utf16.count, length: 0)

        let firstLineRect = editorView.caretRect(for: editorView.beginningOfDocument)
        guard let originalSecondLinePosition = editorView.position(
            from: editorView.beginningOfDocument,
            offset: "abcde\n".utf16.count
        ) else {
            Issue.record("SyntaxEditorView could not resolve original second line")
            return
        }
        let originalSecondLineRect = editorView.caretRect(for: originalSecondLinePosition)

        editorView.insertText("\n")
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let caretPosition = editorView.selectedTextRange?.start else {
            Issue.record("SyntaxEditorView did not expose a selected text range after newline insertion")
            return
        }
        let caretRect = editorView.caretRect(for: caretPosition)

        #expect(editorView.text == "abcde\n\n01234")
        #expect(editorView.selectedRange == NSRange(location: "abcde\n".utf16.count, length: 0))
        #expect(caretRect.midY > firstLineRect.midY)
        #expect(abs(caretRect.midY - originalSecondLineRect.midY) <= 1)
    }

    @Test("SyntaxEditorView reports updated iOS caret geometry during transformed newline input")
    @MainActor
    func syntaxEditorViewIOSReportsUpdatedCaretGeometryDuringTransformedNewlineInput() {
        let model = SyntaxEditorTestContext(
            text: "{}",
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        let inputDelegate = SyntaxEditorUITestInputDelegate()
        var observedCaretRect: CGRect?
        inputDelegate.textDidChangeHandler = { textInput in
            guard let editorView = textInput as? SyntaxEditorView,
                  let caretPosition = editorView.selectedTextRange?.start
            else {
                return
            }
            observedCaretRect = editorView.caretRect(for: caretPosition)
        }
        editorView.inputDelegate = inputDelegate
        layoutIOSEditorView(editorView, width: 393, height: 658)
        editorView.selectedRange = NSRange(location: 1, length: 0)

        editorView.insertText("\n")
        layoutIOSEditorView(editorView, width: 393, height: 658)

        guard let caretPosition = editorView.selectedTextRange?.start,
              let lineStartPosition = editorView.position(
                  from: editorView.beginningOfDocument,
                  offset: "{\n".utf16.count
              ),
              let observedCaretRect
        else {
            Issue.record("SyntaxEditorView did not report caret geometry during transformed newline input")
            return
        }

        let caretRect = editorView.caretRect(for: caretPosition)
        let secondLineRect = editorView.caretRect(for: lineStartPosition)

        #expect(editorView.text == "{\n    \n}")
        #expect(editorView.selectedRange == NSRange(location: "{\n    ".utf16.count, length: 0))
        #expect(abs(observedCaretRect.midY - secondLineRect.midY) <= 1)
        #expect(abs(caretRect.midY - secondLineRect.midY) <= 1)
    }

    @Test("SyntaxEditorView does not fully rebuild iOS line metrics for normal input")
    @MainActor
    func syntaxEditorViewIOSNormalInputDoesNotFullyRebuildLineMetrics() {
        let source = (0..<2_000)
            .map { index in
                index == 1_500 ? longSyntaxEditorLine : "let value\(index) = \(index)"
            }
            .joined(separator: "\n")
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        let targetRange = (source as NSString).range(of: "let value42")
        #expect(targetRange.location != NSNotFound)
        let rebuildCount = editorView.lineMetricsFullRebuildCountForTesting
        let initialWidth = editorView.contentSize.width

        editorView.selectedRange = NSRange(location: targetRange.location + targetRange.length, length: 0)
        editorView.insertText("x")
        layoutIOSEditorView(editorView)

        #expect(editorView.lineMetricsFullRebuildCountForTesting == rebuildCount)
        #expect(abs(editorView.contentSize.width - initialWidth) <= 1)
        #expect(model.model.text.contains("let value42x = 42"))
    }

    @Test("SyntaxEditorMenu builds UIKit Editor menu commands")
    @MainActor
    func syntaxEditorMenuBuildsUIKitEditorMenuCommands() {
        let menu = SyntaxEditorMenu.makeMenu()
        #expect(menu.title == "Editor")
        #expect(menu.identifier == SyntaxEditorMenu.editorMenuIdentifier)

        let structureMenu = syntaxEditorChildMenu(menu, title: "Structure")
        #expect(structureMenu != nil)
        #expect(structureMenu?.children.compactMap { $0 as? UIMenu }.map(\.options) == [
            [.displayInline],
            [.displayInline],
        ])
        let shiftRight = structureMenu.flatMap { syntaxEditorChildKeyCommand($0, title: "Shift Right") }
        #expect(shiftRight?.input == "]")
        #expect(shiftRight?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.command])
        #expect(shiftRight?.action == NSSelectorFromString("syntaxEditorShiftRight:"))

        let shiftLeft = structureMenu.flatMap { syntaxEditorChildKeyCommand($0, title: "Shift Left") }
        #expect(shiftLeft?.input == "[")
        #expect(shiftLeft?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.command])
        #expect(shiftLeft?.action == NSSelectorFromString("syntaxEditorShiftLeft:"))

        let commentSelection = structureMenu.flatMap { syntaxEditorChildKeyCommand($0, title: "Comment Selection") }
        #expect(commentSelection?.input == "/")
        #expect(commentSelection?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.command])
        #expect(commentSelection?.action == NSSelectorFromString("syntaxEditorCommentSelection:"))

        let fontSizeMenu = syntaxEditorChildMenu(menu, title: "Font Size")
        #expect(fontSizeMenu != nil)
        #expect(fontSizeMenu?.children.compactMap { $0 as? UIMenu }.map(\.options) == [
            [.displayInline],
            [.displayInline],
        ])
        let increase = fontSizeMenu.flatMap { syntaxEditorChildKeyCommand($0, title: "Increase") }
        #expect(increase?.input == "+")
        #expect(increase?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.command])
        #expect(increase?.action == NSSelectorFromString("syntaxEditorIncreaseFontSize:"))

        let decrease = fontSizeMenu.flatMap { syntaxEditorChildKeyCommand($0, title: "Decrease") }
        #expect(decrease?.input == "-")
        #expect(decrease?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.command])
        #expect(decrease?.action == NSSelectorFromString("syntaxEditorDecreaseFontSize:"))

        let reset = fontSizeMenu.flatMap { syntaxEditorChildKeyCommand($0, title: "Reset") }
        #expect(reset?.input == "0")
        #expect(reset?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.control, .command])
        #expect(reset?.action == NSSelectorFromString("syntaxEditorResetFontSize:"))

        let wrapLines = syntaxEditorChildKeyCommand(menu, title: "Wrap Lines")
        #expect(wrapLines?.input == "l")
        #expect(wrapLines?.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == [.control, .shift, .command])
        #expect(wrapLines?.action == NSSelectorFromString("syntaxEditorToggleLineWrapping:"))
    }

    @Test("SyntaxEditorView omits editing key commands while read-only on iOS")
    @MainActor
    func syntaxEditorViewIOSReadOnlyOmitsEditingKeyCommands() {
        let model = SyntaxEditorTestContext(
            text: "let answer = 42",
            language: SyntaxLanguage.swift,
            isEditable: false
        )
        let editorView = SyntaxEditorView(testContext: model)

        let readOnlyCommands = editorView.keyCommands
        #expect(!hasSyntaxEditorKeyCommand(readOnlyCommands, input: "\t", modifierFlags: []))
        #expect(!hasSyntaxEditorKeyCommand(readOnlyCommands, input: "\t", modifierFlags: [.shift]))
        #expect(!hasSyntaxEditorKeyCommand(readOnlyCommands, input: "]", modifierFlags: [.command]))
        #expect(!hasSyntaxEditorKeyCommand(readOnlyCommands, input: "[", modifierFlags: [.command]))
        #expect(!hasSyntaxEditorKeyCommand(readOnlyCommands, input: "/", modifierFlags: [.command]))
        #expect(!hasSyntaxEditorKeyCommand(readOnlyCommands, input: "v", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(readOnlyCommands, input: "l", modifierFlags: [.control, .shift, .command]))
        #expect(hasSyntaxEditorKeyCommand(readOnlyCommands, input: "+", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(readOnlyCommands, input: "-", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(readOnlyCommands, input: "0", modifierFlags: [.control, .command]))

        let readOnlyLineWrappingActionTarget = editorView.target(
            forAction: NSSelectorFromString("syntaxEditorToggleLineWrapping:"),
            withSender: nil
        ) as AnyObject?
        #expect(readOnlyLineWrappingActionTarget === editorView)

        let readOnlyIncreaseFontSizeActionTarget = editorView.target(
            forAction: NSSelectorFromString("syntaxEditorIncreaseFontSize:"),
            withSender: nil
        ) as AnyObject?
        #expect(readOnlyIncreaseFontSizeActionTarget === editorView)

        let editorMenu = SyntaxEditorMenu.makeMenu()
        if let structureMenu = syntaxEditorChildMenu(editorMenu, title: "Structure"),
           let shiftRightCommand = syntaxEditorChildKeyCommand(structureMenu, title: "Shift Right") {
            editorView.validate(shiftRightCommand)
            #expect(shiftRightCommand.attributes.contains(.disabled))
        } else {
            Issue.record("Expected Structure > Shift Right command")
        }

        if let wrapLinesCommand = syntaxEditorChildKeyCommand(editorMenu, title: "Wrap Lines") {
            editorView.validate(wrapLinesCommand)
            #expect(!wrapLinesCommand.attributes.contains(.disabled))
            #expect(wrapLinesCommand.state == .off)

            model.model.lineWrappingEnabled = true
            editorView.validate(wrapLinesCommand)
            #expect(!wrapLinesCommand.attributes.contains(.disabled))
            #expect(wrapLinesCommand.state == .on)
        } else {
            Issue.record("Expected Wrap Lines command")
        }

        model.model.isEditable = true

        let editableCommands = editorView.keyCommands
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "\t", modifierFlags: []))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "\t", modifierFlags: [.shift]))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "]", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "[", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "/", modifierFlags: [.command]))
        let pasteCommand = syntaxEditorKeyCommand(editableCommands, input: "v", modifierFlags: [.command])
        #expect(pasteCommand != nil)
        #expect(pasteCommand?.wantsPriorityOverSystemBehavior == true)
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "l", modifierFlags: [.control, .shift, .command]))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "+", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "-", modifierFlags: [.command]))
        #expect(hasSyntaxEditorKeyCommand(editableCommands, input: "0", modifierFlags: [.control, .command]))

        let indentActionTarget = editorView.target(
            forAction: NSSelectorFromString("syntaxEditorShiftRight:"),
            withSender: nil
        ) as AnyObject?
        #expect(indentActionTarget === editorView)

        let insertTabActionTarget = editorView.target(
            forAction: NSSelectorFromString("handleInsertTabCommand"),
            withSender: nil
        ) as AnyObject?
        #expect(insertTabActionTarget === editorView)

        let pasteActionTarget = editorView.target(
            forAction: NSSelectorFromString("handlePasteCommand"),
            withSender: nil
        ) as AnyObject?
        #expect(pasteActionTarget === editorView)
    }

    @Test("SyntaxEditorView applies iOS paste payload repeatedly")
    @MainActor
    func syntaxEditorViewIOSAppliesPastePayloadRepeatedly() {
        let model = SyntaxEditorTestContext(text: "let ")
        let editorView = SyntaxEditorView(testContext: model)
        editorView.selectedRange = NSRange(location: model.model.text.utf16.count, length: 0)

        editorView.insertPastedText("42")
        editorView.insertPastedText("42")
        #expect(model.model.text == "let 4242")
    }

    @Test("SyntaxEditorView defers iOS large paste selection scroll until layout")
    @MainActor
    func syntaxEditorViewIOSDefersLargePasteSelectionScrollUntilLayout() {
        let model = SyntaxEditorTestContext(text: "let start = 0\n", lineWrappingEnabled: false)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        let stableOffset = editorView.contentOffset
        editorView.selectedRange = NSRange(location: model.model.text.utf16.count, length: 0)
        let pastedText = String(repeating: "let value = 1\n", count: 500)

        editorView.insertPastedText(pastedText)
        #expect(abs(editorView.contentOffset.y - stableOffset.y) <= 1)

        layoutIOSEditorView(editorView)

        #expect(model.model.text == "let start = 0\n" + pastedText)
        #expect(editorView.contentOffset.y > stableOffset.y + 1)
    }

    @Test("SyntaxEditorView toggles iOS line wrapping key command")
    @MainActor
    func syntaxEditorViewIOSToggleLineWrappingKeyCommand() {
        let model = SyntaxEditorTestContext(
            text: longSyntaxEditorLine,
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)

        #expect(performSyntaxEditorSelector("syntaxEditorToggleLineWrapping:", on: editorView))
        #expect(model.model.lineWrappingEnabled)
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textContainer.widthTracksTextView)

        #expect(performSyntaxEditorSelector("syntaxEditorToggleLineWrapping:", on: editorView))
        #expect(!model.model.lineWrappingEnabled)
        editorView.synchronizeDocumentForTesting()
        #expect(!editorView.textContainer.widthTracksTextView)
    }

    @Test("SyntaxEditorView read-only handlers do not mutate text on iOS")
    @MainActor
    func syntaxEditorViewIOSReadOnlyHandlersDoNotMutateText() {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            isEditable: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.selectedRange = NSRange(location: 0, length: source.utf16.count)

        editorView.insertText("\t")
        #expect(performSyntaxEditorSelector("handleInsertTabCommand", on: editorView))
        #expect(performSyntaxEditorSelector("syntaxEditorShiftRight:", on: editorView))
        #expect(performSyntaxEditorSelector("syntaxEditorShiftLeft:", on: editorView))
        #expect(performSyntaxEditorSelector("syntaxEditorCommentSelection:", on: editorView))
        #expect(performSyntaxEditorSelector("syntaxEditorToggleLineWrapping:", on: editorView))

        #expect(model.model.text == source)
        #expect(editorView.text == source)
        #expect(model.model.lineWrappingEnabled)
    }

    @Test("SyntaxEditorView inserts iOS tab spaces at the caret")
    @MainActor
    func syntaxEditorViewIOSInsertTabAtCaret() {
        let source = "abcde"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.selectedRange = NSRange(location: 2, length: 0)

        #expect(performSyntaxEditorSelector("handleInsertTabCommand", on: editorView))

        #expect(model.model.text == "ab  cde")
        #expect(editorView.text == "ab  cde")
        #expect(editorView.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("SyntaxEditorView inserts raw iOS tab in plain text")
    @MainActor
    func syntaxEditorViewIOSInsertPlainTextTabAtCaret() {
        let source = "abcde"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.plainText)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.selectedRange = NSRange(location: 2, length: 0)

        let commands = editorView.keyCommands
        #expect(hasSyntaxEditorKeyCommand(commands, input: "\t", modifierFlags: []))
        #expect(!hasSyntaxEditorKeyCommand(commands, input: "\t", modifierFlags: [.shift]))
        #expect(!hasSyntaxEditorKeyCommand(commands, input: "]", modifierFlags: [.command]))
        #expect(!hasSyntaxEditorKeyCommand(commands, input: "[", modifierFlags: [.command]))
        #expect(!hasSyntaxEditorKeyCommand(commands, input: "/", modifierFlags: [.command]))

        let insertTabActionTarget = editorView.target(
            forAction: NSSelectorFromString("handleInsertTabCommand"),
            withSender: nil
        ) as AnyObject?
        #expect(insertTabActionTarget === editorView)

        #expect(performSyntaxEditorSelector("handleInsertTabCommand", on: editorView))

        #expect(model.model.text == "ab\tcde")
        #expect(editorView.text == "ab\tcde")
        #expect(editorView.selectedRange == NSRange(location: 3, length: 0))
    }

    @Test("SyntaxEditorView uses native iOS undo stack for text input")
    @MainActor
    func syntaxEditorViewIOSNativeTextInputUndoRedo() {
        let source = "let answer = 42"
        let editedSource = "\(source)!"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        layoutIOSEditorView(editorView)
        editorView.selectedRange = NSRange(location: source.utf16.count, length: 0)

        #expect(!editorView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        #expect(!editorView.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))

        editorView.insertText("!")

        #expect(model.model.text == editedSource)
        #expect(editorView.text == editedSource)

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(undoManager.canUndo)
        #expect(editorView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        #expect(!editorView.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))
        #expect(performSyntaxEditorSelector("handleUndoCommand", on: editorView))

        #expect(model.model.text == source)
        #expect(editorView.text == source)
        #expect(undoManager.canRedo)
        #expect(!editorView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        #expect(editorView.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))

        #expect(performSyntaxEditorSelector("handleRedoCommand", on: editorView))

        #expect(model.model.text == editedSource)
        #expect(editorView.text == editedSource)
        #expect(editorView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        #expect(!editorView.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))
    }

    @Test("SyntaxEditorView read-only undo and redo do not mutate text on iOS")
    @MainActor
    func syntaxEditorViewIOSReadOnlyUndoRedoDoNotMutateText() {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.selectedRange = NSRange(location: 0, length: 0)

        #expect(performSyntaxEditorSelector("syntaxEditorShiftRight:", on: editorView))
        let indentedSource = "    \(source)"
        #expect(model.model.text == indentedSource)
        #expect(editorView.text == indentedSource)

        model.model.isEditable = false

        #expect(!editorView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        #expect(!editorView.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))
        #expect(performSyntaxEditorSelector("handleUndoCommand", on: editorView))
        #expect(performSyntaxEditorSelector("handleRedoCommand", on: editorView))

        #expect(model.model.text == indentedSource)
        #expect(editorView.text == indentedSource)

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        undoManager.undo()
        undoManager.redo()

        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)
        #expect(model.model.text == indentedSource)
        #expect(editorView.text == indentedSource)

        model.model.isEditable = true

        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(model.model.text == source)
        #expect(editorView.text == source)
    }

    @Test("SyntaxEditorView restores command selection through iOS undo and redo")
    @MainActor
    func syntaxEditorViewIOSCommandUndoRedoRestoresSelection() {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.selectedRange = NSRange(location: 4, length: 0)

        #expect(performSyntaxEditorSelector("syntaxEditorShiftRight:", on: editorView))
        let indentedSource = "    \(source)"
        let indentedSelection = NSRange(location: 8, length: 0)
        #expect(model.model.text == indentedSource)
        #expect(editorView.text == indentedSource)
        #expect(editorView.selectedRange == indentedSelection)

        guard let undoManager = editorView.undoManager else {
            Issue.record("SyntaxEditorView has no undo manager")
            return
        }

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(model.model.text == source)
        #expect(editorView.text == source)
        #expect(editorView.selectedRange == NSRange(location: 4, length: 0))

        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(model.model.text == indentedSource)
        #expect(editorView.text == indentedSource)
        #expect(editorView.selectedRange == indentedSelection)
    }

}
#endif
