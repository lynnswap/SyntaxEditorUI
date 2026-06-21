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
    @Test("SyntaxEditorView reflects document text replacements on macOS")
    @MainActor
    func syntaxEditorViewMacTextObservation() async {
        let model = SyntaxEditorTestContext(text: "const answer = 42;", language: SyntaxLanguage.javascript)
        let editorView = SyntaxEditorView(testContext: model)
        guard let delivery = editorView.modelDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorView to expose its production document delivery")
            return
        }
        let renderedText = await delivery.values {
            editorView.textView.string
        }

        #expect(await renderedText.waitUntilValue("const answer = 42;"))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))
    }

    @Test("SyntaxEditorView clamps macOS selection after whole-document replacement")
    @MainActor
    func syntaxEditorViewMacClampsSelectionAfterWholeDocumentReplacement() {
        let model = SyntaxEditorTestContext(text: "abcdef", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: SyntaxEditorUITestHighlighter())
        editorView.textView.setSelectedRange(NSRange(location: 6, length: 0))

        model.model.replaceText("a")
        editorView.synchronizeDocumentForTesting()

        #expect(editorView.textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("SyntaxEditorView sends macOS text change notifications for command edits")
    @MainActor
    func syntaxEditorViewMacCommandEditsSendTextChangeNotifications() async {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let recorder = SyntaxEditorNotificationRecorder()
        NotificationCenter.default.addObserver(
            recorder,
            selector: #selector(SyntaxEditorNotificationRecorder.record(_:)),
            name: NSText.didChangeNotification,
            object: editorView.textView
        )
        defer {
            NotificationCenter.default.removeObserver(recorder)
        }

        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)
        editorView.textView.insertText("\"", replacementRange: insertionRange)
        await editorView.waitForPendingHighlightForTesting()

        #expect(editorView.textView.string == "\(source)\"\"")
        #expect(recorder.count == 1)
    }

    @Test("SyntaxEditorView syncs macOS multi-range replacements from the final text")
    @MainActor
    func syntaxEditorViewMacMultiRangeReplacementSyncsFinalText() async {
        let source = "abcde"
        let expectedSource = "aXcYe"
        let completeGate = ManualSyntaxHighlightGate()
        let highlighter = SyntaxEditorPhasedTestHighlighter(
            fastTokens: [],
            completeTokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 1),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ],
            completeGate: completeGate
        )
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)

        await completeGate.waitUntilSuspended()
        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
        #expect(editorView.syntaxColorRunCountForTesting == 1)

        let didAccept = editorView.textView.shouldReplaceCharacters(
            inRanges: [
                NSValue(range: NSRange(location: 1, length: 1)),
                NSValue(range: NSRange(location: 3, length: 1)),
            ],
            with: ["X", "Y"]
        )
        #expect(didAccept)

        let suspensionCount = await completeGate.currentSuspensionCount()
        editorView.textView.string = expectedSource
        #expect(editorView.syntaxColorRunCountForTesting == 0)
        await completeGate.waitUntilSuspended(after: suspensionCount)

        #expect(editorView.textView.string == expectedSource)
        #expect(model.model.text == expectedSource)
        #expect(editorView.syntaxColorRunCountForTesting == 0)

        await completeGate.resumeOne()
        await editorView.waitForPendingHighlightForTesting()
    }

    @Test("SyntaxEditorView keeps macOS marked range unchanged when marked text is handled as command input")
    @MainActor
    func syntaxEditorViewMacRejectedMarkedCommandDoesNotInstallMarkedRange() async {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)

        editorView.textView.setMarkedText(
            "\"",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        await editorView.waitForPendingHighlightForTesting()

        let expectedSource = source + "\"\""
        #expect(!editorView.textView.hasMarkedText())
        #expect(editorView.textView.markedRange().location == NSNotFound)
        #expect(editorView.textView.string == expectedSource)
        #expect(model.model.text == expectedSource)
    }

    @Test("SyntaxEditorView replaces macOS marked text when IME commits through insertText")
    @MainActor
    func syntaxEditorViewMacReplacesMarkedTextWhenIMECommitsThroughInsertText() async {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(insertionRange)

        editorView.textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editorView.textView.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        await editorView.waitForPendingHighlightForTesting()

        let expectedSource = source + "仮名"
        #expect(!editorView.textView.hasMarkedText())
        #expect(editorView.textView.markedRange().location == NSNotFound)
        #expect(editorView.textView.string == expectedSource)
        #expect(model.model.text == expectedSource)
        #expect(editorView.textView.selectedRange() == NSRange(location: expectedSource.utf16.count, length: 0))
    }

    @Test("SyntaxEditorView clears macOS marked-text highlight suppression after IME commit")
    @MainActor
    func syntaxEditorViewMacClearsMarkedTextHighlightSuppressionAfterIMECommit() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutMacEditorView(editorView)
        let originalMarkedTextHook = editorView.textView.didChangeMarkedTextRange
        var markedTextHookCallCount = 0
        editorView.textView.didChangeMarkedTextRange = {
            markedTextHookCallCount += 1
            originalMarkedTextHook?()
        }

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editorView.textView.setMarkedText(
            "let",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))
        #expect(markedTextHookCallCount == 1)

        editorView.textView.insertText("let", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(editorView.textView.markedRange().location == NSNotFound)
        #expect(markedTextHookCallCount == 2)
    }

    @Test("SyntaxEditorView preserves macOS attributed marked text attributes")
    @MainActor
    func syntaxEditorViewMacPreservesAttributedMarkedTextAttributes() async throws {
        let source = "let value = "
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let insertionRange = NSRange(location: source.utf16.count, length: 0)
        let markedForeground = syntaxEditorUITestColor(hex: 0x1A7F37)
        let markedUnderline = syntaxEditorUITestColor(hex: 0x0969DA)
        let markedText = NSMutableAttributedString(string: "かな")
        let markedTextRange = NSRange(location: 0, length: markedText.length)
        markedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: markedTextRange
        )
        markedText.addAttribute(.underlineColor, value: markedUnderline, range: markedTextRange)
        markedText.addAttribute(.foregroundColor, value: markedForeground, range: markedTextRange)
        editorView.textView.setSelectedRange(insertionRange)
        layoutMacEditorView(editorView)

        editorView.textView.setMarkedText(
            markedText,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        await editorView.waitForPendingHighlightForTesting()

        let installedRange = NSRange(location: insertionRange.location, length: markedText.length)
        #expect(editorView.textView.markedRange() == installedRange)
        #expect(macEditorUnderlineStyle(editorView, at: installedRange.location) == NSUnderlineStyle.single.rawValue)
        #expect(
            syntaxEditorUITestColorsEqual(
                editorView.textView.textStorage?.attribute(
                    .underlineColor,
                    at: installedRange.location,
                    effectiveRange: nil
                ) as? NSColor,
                markedUnderline
            )
        )
        #expect(syntaxEditorUITestColorsEqual(
            macEditorPermanentForegroundColor(editorView, at: installedRange.location),
            markedForeground
        ))

        let installedTextRange = try #require(editorView.textView.textRange(forUTF16Range: installedRange))
        var renderingForeground: NSColor?
        editorView.textView.textLayoutManager.enumerateRenderingAttributes(
            from: installedTextRange.location,
            reverse: false
        ) { _, attributes, range in
            let utf16Range = editorView.textView.utf16Range(for: range)
            guard NSIntersectionRange(utf16Range, installedRange).length > 0 else {
                return true
            }
            renderingForeground = attributes[.foregroundColor] as? NSColor
            return false
        }
        #expect(renderingForeground == nil)
    }

    @Test("SyntaxEditorView clears macOS marked-text highlight suppression after unmarking")
    @MainActor
    func syntaxEditorViewMacClearsMarkedTextHighlightSuppressionAfterUnmarking() async {
        let source = "let value = 1"
        let theme = syntaxEditorUITestTheme(
            baseForeground: syntaxEditorUITestColor(hex: 0x123456),
            keyword: syntaxEditorUITestColor(hex: 0x654321)
        )
        let highlighter = SyntaxEditorUITestHighlighter(
            tokens: [
                SyntaxEditorHighlighting.Token(
                    range: NSRange(location: 0, length: 3),
                    rawCaptureName: "editor.syntax.swift.keyword"
                ),
            ]
        )
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            theme: theme
        )
        let editorView = SyntaxEditorView(testContext: model, highlighter: highlighter)
        layoutMacEditorView(editorView)

        await editorView.waitForPendingHighlightForTesting()
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))

        let markedRange = NSRange(location: 0, length: 3)
        editorView.textView.markedTextRangeStorage = markedRange
        editorView.textView.markedTextAttributedStringStorage = NSAttributedString(
            string: "let",
            attributes: editorView.textView.typingAttributes
        )
        editorView.textView.applyMarkedTextAttributes()
        editorView.textView.didChangeMarkedTextRange?()

        #expect(editorView.textView.markedRange() == markedRange)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.baseForeground))

        editorView.textView.unmarkText()

        #expect(editorView.textView.markedRange().location == NSNotFound)
        #expect(syntaxEditorUITestColorsEqual(macEditorForegroundColor(editorView, at: 0), theme.keyword))
    }

    @Test("SyntaxEditorView reflects editable and wrapping changes on macOS")
    @MainActor
    func syntaxEditorViewMacEditorStateObservation() async {
        let model = SyntaxEditorTestContext(text: "body {}", language: SyntaxLanguage.css)
        let editorView = SyntaxEditorView(testContext: model)

        model.model.isEditable = false
        model.model.lineWrappingEnabled = true

        editorView.synchronizeDocumentForTesting()
        #expect(
            editorView.textView.isEditable == false
                && editorView.hasHorizontalScroller == false
        )

        model.model.lineWrappingEnabled = false

        editorView.synchronizeDocumentForTesting()
        #expect(editorView.hasHorizontalScroller == true)
    }

    @Test("SyntaxEditorTextInputView updates short macOS document frame to unobscured inset height")
    @MainActor
    func syntaxEditorTextInputViewMacDocumentFrameAccountsForTopInsets() async {
        let model = SyntaxEditorTestContext(
            text: #"{"result":"ok"}"#,
            language: SyntaxLanguage.json,
            lineWrappingEnabled: true
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.automaticallyAdjustsContentInsets = false
        editorView.contentInsets = NSEdgeInsets(top: 54, left: 24, bottom: 12, right: 36)
        layoutMacEditorView(editorView, width: 360, height: 240)

        editorView.textView.updateDocumentFrameForCurrentText()

        let unobscuredContentSize = macUnobscuredContentSize(editorView)
        #expect(approximatelyEqual(editorView.textView.frame.width, unobscuredContentSize.width))
        #expect(approximatelyEqual(editorView.textView.frame.height, unobscuredContentSize.height))
    }

    @Test("SyntaxEditorMenu builds AppKit Editor menu commands")
    @MainActor
    func syntaxEditorMenuBuildsAppKitEditorMenuCommands() throws {
        let menu = SyntaxEditorMenu.makeMenu()
        #expect(menu.title == "Editor")

        let structureMenu = try #require(syntaxEditorSubmenu(menu, title: "Structure"))
        let shiftRight = try #require(structureMenu.item(withTitle: "Shift Right"))
        #expect(shiftRight.action == NSSelectorFromString("syntaxEditorShiftRight:"))
        #expect(shiftRight.target == nil)
        #expect(shiftRight.keyEquivalent == "]")
        #expect(shiftRight.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.command])

        let shiftLeft = try #require(structureMenu.item(withTitle: "Shift Left"))
        #expect(shiftLeft.action == NSSelectorFromString("syntaxEditorShiftLeft:"))
        #expect(shiftLeft.target == nil)
        #expect(shiftLeft.keyEquivalent == "[")
        #expect(shiftLeft.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.command])

        let commentSelection = try #require(structureMenu.item(withTitle: "Comment Selection"))
        #expect(structureMenu.items.firstIndex(where: { $0.isSeparatorItem }) == 2)
        #expect(commentSelection.action == NSSelectorFromString("syntaxEditorCommentSelection:"))
        #expect(commentSelection.target == nil)
        #expect(commentSelection.keyEquivalent == "/")
        #expect(commentSelection.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.command])

        let fontSizeMenu = try #require(syntaxEditorSubmenu(menu, title: "Font Size"))
        let increase = try #require(fontSizeMenu.item(withTitle: "Increase"))
        #expect(increase.action == NSSelectorFromString("syntaxEditorIncreaseFontSize:"))
        #expect(increase.target == nil)
        #expect(increase.keyEquivalent == "+")
        #expect(increase.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.command])

        let decrease = try #require(fontSizeMenu.item(withTitle: "Decrease"))
        #expect(decrease.action == NSSelectorFromString("syntaxEditorDecreaseFontSize:"))
        #expect(decrease.target == nil)
        #expect(decrease.keyEquivalent == "-")
        #expect(decrease.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.command])

        let reset = try #require(fontSizeMenu.item(withTitle: "Reset"))
        #expect(fontSizeMenu.items.firstIndex(where: { $0.isSeparatorItem }) == 2)
        #expect(reset.action == NSSelectorFromString("syntaxEditorResetFontSize:"))
        #expect(reset.target == nil)
        #expect(reset.keyEquivalent == "0")
        #expect(reset.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.control, .command])

        let wrapLines = try #require(menu.item(withTitle: "Wrap Lines"))
        #expect(wrapLines.action == NSSelectorFromString("syntaxEditorToggleLineWrapping:"))
        #expect(wrapLines.target == nil)
        #expect(wrapLines.keyEquivalent == "l")
        #expect(wrapLines.keyEquivalentModifierMask.intersection(syntaxEditorMenuItemModifierMask) == [.control, .shift, .command])
    }

    @Test("SyntaxEditorView validates and handles AppKit Editor menu actions")
    @MainActor
    func syntaxEditorViewMacValidatesAndHandlesEditorMenuActions() throws {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            isEditable: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        let menu = SyntaxEditorMenu.makeMenu()
        let structureMenu = try #require(syntaxEditorSubmenu(menu, title: "Structure"))
        let shiftRight = try #require(structureMenu.item(withTitle: "Shift Right"))
        let wrapLines = try #require(menu.item(withTitle: "Wrap Lines"))

        #expect(!editorView.textView.validateUserInterfaceItem(shiftRight))
        #expect(editorView.textView.validateUserInterfaceItem(wrapLines))
        #expect(wrapLines.state == .off)
        model.model.lineWrappingEnabled = true
        #expect(editorView.textView.validateUserInterfaceItem(wrapLines))
        #expect(wrapLines.state == .on)

        model.model.lineWrappingEnabled = false
        model.model.isEditable = true
        editorView.synchronizeDocumentForTesting()
        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editorView.textView)
        defer { window.orderOut(nil) }

        #expect(NSApplication.shared.sendAction(
            NSSelectorFromString("syntaxEditorShiftRight:"),
            to: editorView.textView,
            from: shiftRight
        ))
        #expect(model.model.text == "    \(source)")
        #expect(editorView.textView.string == "    \(source)")

        #expect(NSApplication.shared.sendAction(
            NSSelectorFromString("syntaxEditorToggleLineWrapping:"),
            to: editorView.textView,
            from: wrapLines
        ))
        #expect(model.model.lineWrappingEnabled)
    }

    @Test("SyntaxEditorView handles AppKit standard edit key equivalents")
    @MainActor
    func syntaxEditorViewMacHandlesStandardEditKeyEquivalents() throws {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editorView.textView)
        defer { window.orderOut(nil) }

        let pasteboard = NSPasteboard.general
        let previousPasteboardString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousPasteboardString {
                pasteboard.setString(previousPasteboardString, forType: .string)
            }
        }

        let copyEvent = try #require(makeMacCommandKeyEvent("c"))
        let pasteEvent = try #require(makeMacCommandKeyEvent("v"))
        let cutEvent = try #require(makeMacCommandKeyEvent("x"))
        let selectAllEvent = try #require(makeMacCommandKeyEvent("a"))
        let copyItem = NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        let cutItem = NSMenuItem(title: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        let pasteItem = NSMenuItem(title: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")

        editorView.textView.setSelectedRange(NSRange(location: 4, length: 6))

        #expect(editorView.textView.validateUserInterfaceItem(copyItem))
        #expect(editorView.textView.performKeyEquivalent(with: copyEvent))
        #expect(pasteboard.string(forType: .string) == "answer")

        pasteboard.clearContents()
        pasteboard.setString("value", forType: .string)
        #expect(editorView.textView.validateUserInterfaceItem(pasteItem))
        #expect(editorView.textView.performKeyEquivalent(with: pasteEvent))
        #expect(model.model.text == "let value = 42")
        #expect(editorView.textView.string == "let value = 42")
        #expect(editorView.textView.selectedRange() == NSRange(location: 9, length: 0))

        editorView.textView.setSelectedRange(NSRange(location: 4, length: 5))
        #expect(editorView.textView.validateUserInterfaceItem(cutItem))
        #expect(editorView.textView.performKeyEquivalent(with: cutEvent))
        #expect(pasteboard.string(forType: .string) == "value")
        #expect(model.model.text == "let  = 42")
        #expect(editorView.textView.string == "let  = 42")
        #expect(editorView.textView.selectedRange() == NSRange(location: 4, length: 0))

        #expect(editorView.textView.performKeyEquivalent(with: selectAllEvent))
        #expect(editorView.textView.selectedRange() == NSRange(location: 0, length: editorView.textView.string.utf16.count))

        model.model.isEditable = false
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.validateUserInterfaceItem(copyItem))
        #expect(!editorView.textView.validateUserInterfaceItem(cutItem))
        #expect(!editorView.textView.validateUserInterfaceItem(pasteItem))
    }

    @Test("SyntaxEditorView provides AppKit contextual edit menu")
    @MainActor
    func syntaxEditorViewMacProvidesContextualEditMenu() throws {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        let pasteboard = NSPasteboard.general
        let previousPasteboardString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousPasteboardString {
                pasteboard.setString(previousPasteboardString, forType: .string)
            }
        }

        editorView.textView.setSelectedRange(NSRange(location: 4, length: 6))
        let previousSelection = editorView.textView.selectedRange()
        pasteboard.clearContents()
        pasteboard.setString("value", forType: .string)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 12, y: 12),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(editorView.textView.menu(for: event))

        #expect(window.firstResponder === editorView.textView)
        #expect(editorView.textView.selectedRange() == previousSelection)
        #expect(menu.items.count == 3)
        #expect(menu.items[0].title == "Cut")
        #expect(menu.items[0].action == #selector(NSText.cut(_:)))
        #expect(menu.items[0].keyEquivalent == "")
        #expect(menu.items[0].target === editorView.textView)
        #expect(menu.items[1].title == "Copy")
        #expect(menu.items[1].action == #selector(NSText.copy(_:)))
        #expect(menu.items[1].keyEquivalent == "")
        #expect(menu.items[1].target === editorView.textView)
        #expect(menu.items[2].title == "Paste")
        #expect(menu.items[2].action == #selector(NSText.paste(_:)))
        #expect(menu.items[2].keyEquivalent == "")
        #expect(menu.items[2].target === editorView.textView)

        menu.update()
        #expect(menu.items[0].isEnabled)
        #expect(menu.items[1].isEnabled)
        #expect(menu.items[2].isEnabled)

        pasteboard.clearContents()
        model.model.isEditable = false
        editorView.synchronizeDocumentForTesting()

        menu.update()
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[1].isEnabled)
        #expect(!menu.items[2].isEnabled)

        editorView.textView.isSelectable = false
        #expect(editorView.textView.menu(for: event) == nil)
    }

    @Test("SyntaxEditorView leaves AppKit paste key equivalents to the active search field")
    @MainActor
    func syntaxEditorViewMacLeavesPasteKeyEquivalentToActiveSearchField() throws {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let searchField = NSSearchField(frame: NSRect(x: 0, y: 200, width: 220, height: 24))
        editorView.frame = NSRect(x: 0, y: 0, width: 320, height: 190)
        container.addSubview(editorView)
        container.addSubview(searchField)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        defer { window.orderOut(nil) }

        let pasteboard = NSPasteboard.general
        let previousPasteboardString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousPasteboardString {
                pasteboard.setString(previousPasteboardString, forType: .string)
            }
        }
        pasteboard.clearContents()
        pasteboard.setString("pasted", forType: .string)

        let pasteEvent = try #require(makeMacCommandKeyEvent("v"))
        #expect(window.firstResponder !== editorView.textView)
        #expect(!editorView.textView.performKeyEquivalent(with: pasteEvent))
        #expect(model.model.text == source)
        #expect(editorView.textView.string == source)
    }

    @Test("SyntaxEditorView read-only delegate commands do not mutate text on macOS")
    @MainActor
    func syntaxEditorViewMacReadOnlyDelegateCommandsDoNotMutateText() {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            isEditable: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))

        #expect(!editorView.textView(
            editorView.textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "\t"
        ))

        let commandSelectors = [
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.deleteBackward(_:)),
        ]

        for commandSelector in commandSelectors {
            #expect(!editorView.textView(editorView.textView, doCommandBy: commandSelector))
            #expect(model.model.text == source)
            #expect(editorView.textView.string == source)
        }
    }

    @Test("SyntaxEditorView inserts macOS tab spaces at the caret")
    @MainActor
    func syntaxEditorViewMacInsertTabAtCaret() {
        let source = "abcde"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.textView.setSelectedRange(NSRange(location: 2, length: 0))

        #expect(editorView.textView(
            editorView.textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))

        #expect(model.model.text == "ab  cde")
        #expect(editorView.textView.string == "ab  cde")
        #expect(editorView.textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test("SyntaxEditorView inserts raw macOS tab in plain text")
    @MainActor
    func syntaxEditorViewMacInsertPlainTextTabAtCaret() {
        let source = "abcde"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.plainText)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.textView.setSelectedRange(NSRange(location: 2, length: 0))

        #expect(editorView.textView(
            editorView.textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))

        #expect(model.model.text == "ab\tcde")
        #expect(editorView.textView.string == "ab\tcde")
        #expect(editorView.textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("SyntaxEditorView accepts macOS first responder keyboard input")
    @MainActor
    func syntaxEditorViewMacAcceptsFirstResponderKeyboardInput() {
        let source = "let"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(editorView))
        #expect(window.firstResponder === editorView.textView)

        editorView.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        guard let event = makeMacKeyEvent("x") else {
            Issue.record("Failed to create macOS key event")
            return
        }

        editorView.textView.keyDown(with: event)

        #expect(model.model.text == "letx")
        #expect(editorView.textView.string == "letx")
        #expect(editorView.textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test("SyntaxEditorView focuses macOS text input through rendered fragments")
    @MainActor
    func syntaxEditorViewMacFocusesTextInputThroughRenderedFragments() {
        let model = SyntaxEditorTestContext(text: "let value = 1", language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        let clickPoint = NSPoint(x: 12, y: 12)
        #expect(editorView.textView.hitTest(clickPoint) === editorView.textView)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: editorView.textView.convert(clickPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            Issue.record("Failed to create macOS mouse event")
            return
        }

        editorView.textView.mouseDown(with: event)

        #expect(window.firstResponder === editorView.textView)
    }

    @Test("SyntaxEditorView resolves macOS text input character indexes from screen points")
    @MainActor
    func syntaxEditorViewMacResolvesCharacterIndexFromScreenPoint() {
        let source = "let value = 1"
        let valueRange = (source as NSString).range(of: "value")
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = attachMacEditorWindow(editorView)
        defer { window.orderOut(nil) }

        let screenRect = editorView.textView.firstRect(forCharacterRange: valueRange, actualRange: nil)
        let screenPoint = NSPoint(x: screenRect.minX + 1, y: screenRect.midY)

        #expect(editorView.textView.characterIndex(for: screenPoint) == valueRange.location)
    }

    @Test("SyntaxEditorView uses TextKit navigation for macOS movement commands")
    @MainActor
    func syntaxEditorViewMacUsesTextKitNavigationForMovementCommands() {
        let source = "abc def\nghi"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))

        editorView.textView.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
        #expect(editorView.textView.selectedRange().location > 0)

        editorView.textView.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        #expect(editorView.textView.selectedRange() == NSRange(location: 7, length: 0))

        editorView.textView.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
        #expect(editorView.textView.selectedRange() == NSRange(location: source.utf16.count, length: 0))

        editorView.textView.doCommand(by: #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)))
        #expect(editorView.textView.selectedRange().location == 0)
        #expect(editorView.textView.selectedRange().length == source.utf16.count)
    }

    @Test("SyntaxEditorView read-only key equivalents do not mutate text on macOS")
    @MainActor
    func syntaxEditorViewMacReadOnlyKeyEquivalentsDoNotMutateText() {
        let source = "let answer = 42"
        let model = SyntaxEditorTestContext(
            text: source,
            language: SyntaxLanguage.swift,
            isEditable: false
        )
        let editorView = SyntaxEditorView(testContext: model)
        editorView.textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))

        guard let lineWrappingEvent = makeMacCommandKeyEvent(
            "l",
            modifierFlags: [.control, .shift, .command]
        ) else {
            Issue.record("Failed to create line wrapping key event")
            return
        }

        #expect(editorView.textView.performKeyEquivalent(with: lineWrappingEvent))
        #expect(model.model.lineWrappingEnabled)
        #expect(editorView.textView.string == source)

        for (character, modifiers) in [
            ("+", NSEvent.ModifierFlags.command),
            ("-", NSEvent.ModifierFlags.command),
            ("0", NSEvent.ModifierFlags([.control, .command])),
        ] {
            guard let event = makeMacCommandKeyEvent(character, modifierFlags: modifiers) else {
                Issue.record("Failed to create font size key event for \(character)")
                continue
            }

            #expect(editorView.textView.performKeyEquivalent(with: event))
            #expect(model.model.text == source)
            #expect(editorView.textView.string == source)
        }

        for character in ["/", "]", "["] {
            guard let event = makeMacCommandKeyEvent(character) else {
                Issue.record("Failed to create command key event for \(character)")
                continue
            }

            _ = editorView.textView.performKeyEquivalent(with: event)
            #expect(model.model.text == source)
            #expect(editorView.textView.string == source)
        }
    }

    @Test("SyntaxEditorView toggles macOS line wrapping key equivalent")
    @MainActor
    func syntaxEditorViewMacToggleLineWrappingKeyEquivalent() {
        let model = SyntaxEditorTestContext(
            text: String(repeating: "let macHorizontalScrollNeedsWrapping = true; ", count: 8),
            language: SyntaxLanguage.swift,
            lineWrappingEnabled: false
        )
        let editorView = SyntaxEditorView(testContext: model)

        guard let event = makeMacCommandKeyEvent(
            "l",
            modifierFlags: [.control, .shift, .command]
        ) else {
            Issue.record("Failed to create line wrapping key event")
            return
        }

        #expect(editorView.textView.performKeyEquivalent(with: event))
        #expect(model.model.lineWrappingEnabled)
        editorView.synchronizeDocumentForTesting()
        #expect(!editorView.hasHorizontalScroller)

        #expect(editorView.textView.performKeyEquivalent(with: event))
        #expect(!model.model.lineWrappingEnabled)
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.hasHorizontalScroller)
    }

    @Test("SyntaxEditorView uses native macOS undo stack for text input")
    @MainActor
    func syntaxEditorViewMacNativeTextInputUndoRedo() async {
        let source = "let answer = 42"
        let editedSource = "\(source)!"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editorView.textView)
        defer { window.orderOut(nil) }

        guard let undoManager = editorView.textView.undoManager else {
            Issue.record("SyntaxEditorView text view has no undo manager")
            return
        }

        let editRange = NSRange(location: source.utf16.count, length: 0)
        editorView.textView.setSelectedRange(editRange)
        editorView.textView.insertText("!", replacementRange: editRange)
        editorView.textView.breakUndoCoalescing()

        #expect(model.model.text == editedSource)
        #expect(editorView.textView.string == editedSource)

        let undoSelector = NSSelectorFromString("undo:")
        let redoSelector = NSSelectorFromString("redo:")
        let undoItem = NSMenuItem(title: "Undo", action: undoSelector, keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: redoSelector, keyEquivalent: "Z")

        #expect(undoManager.canUndo)
        #expect(editorView.textView.validateUserInterfaceItem(undoItem))

        model.model.isEditable = false
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.isEditable == false)
        #expect(!undoManager.canUndo)
        #expect(!editorView.textView.validateUserInterfaceItem(undoItem))

        #expect(NSApplication.shared.sendAction(undoSelector, to: editorView.textView, from: undoItem))
        #expect(model.model.text == editedSource)
        #expect(editorView.textView.string == editedSource)

        model.model.isEditable = true
        editorView.synchronizeDocumentForTesting()
        #expect(editorView.textView.isEditable == true)

        #expect(undoManager.canUndo)
        #expect(NSApplication.shared.sendAction(undoSelector, to: editorView.textView, from: undoItem))

        #expect(model.model.text == source)
        #expect(editorView.textView.string == source)
        #expect(undoManager.canRedo)
        #expect(editorView.textView.validateUserInterfaceItem(redoItem))
        #expect(NSApplication.shared.sendAction(redoSelector, to: editorView.textView, from: redoItem))

        #expect(model.model.text == editedSource)
        #expect(editorView.textView.string == editedSource)
    }

    @Test("SyntaxEditorView preserves undo history when undo manager runs while read-only on macOS")
    @MainActor
    func syntaxEditorViewMacReadOnlyUndoManagerPreservesHistory() async {
        let source = "let answer = 42"
        let onceIndentedSource = "    \(source)"
        let twiceIndentedSource = "        \(source)"
        let model = SyntaxEditorTestContext(text: source, language: SyntaxLanguage.swift)
        let editorView = SyntaxEditorView(testContext: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editorView.textView)
        defer { window.orderOut(nil) }

        editorView.textView.setSelectedRange(NSRange(location: 0, length: 0))

        guard let undoManager = editorView.textView.undoManager else {
            Issue.record("SyntaxEditorView text view has no undo manager")
            return
        }
        undoManager.groupsByEvent = false

        func runUndoGroupedCommand(_ action: () -> Bool) {
            undoManager.beginUndoGrouping()
            let handled = action()
            undoManager.endUndoGrouping()
            #expect(handled)
        }

        runUndoGroupedCommand {
            editorView.textView(
                editorView.textView,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
        }
        runUndoGroupedCommand {
            editorView.textView(
                editorView.textView,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
        }
        #expect(model.model.text == twiceIndentedSource)

        model.model.isEditable = false
        undoManager.undo()
        undoManager.undo()

        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)
        #expect(model.model.text == twiceIndentedSource)
        #expect(editorView.textView.string == twiceIndentedSource)

        model.model.isEditable = true

        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(model.model.text == onceIndentedSource)
        #expect(editorView.textView.string == onceIndentedSource)
        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(model.model.text == source)
        #expect(editorView.textView.string == source)
        #expect(undoManager.canRedo)

        model.model.isEditable = false
        undoManager.redo()
        undoManager.redo()

        #expect(model.model.text == source)
        #expect(editorView.textView.string == source)
        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)

        model.model.isEditable = true

        #expect(undoManager.canRedo)
        undoManager.redo()
        undoManager.redo()

        #expect(model.model.text == twiceIndentedSource)
        #expect(editorView.textView.string == twiceIndentedSource)
    }

    @Test("SyntaxEditorViewController enables undo support on macOS")
    @MainActor
    func syntaxEditorViewControllerMacUndo() {
        let model = SyntaxEditorTestContext(text: "{}", language: SyntaxLanguage.javascript)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()

        let textView = controller.textView
        #expect(textView.allowsUndo == true)
    }

    @Test("SyntaxEditorViewController renders source-of-truth state on macOS")
    @MainActor
    func syntaxEditorViewControllerMacRendersSourceOfTruthState() async {
        let model = SyntaxEditorTestContext(text: "{}", language: SyntaxLanguage.javascript)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()

        #expect(controller.model === model.model)
        #expect(controller.model === model.model)
        #expect(
            controller.textView(
                controller.textView,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: "a"
            )
        )

        guard let delivery = controller.editorView.modelDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorViewController to expose its production document delivery")
            return
        }
        let renderedText = await delivery.values {
            controller.textView.string
        }

        #expect(await renderedText.waitUntilValue("{}"))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))
    }

    @Test("SyntaxEditorViewController reflects document text replacements on macOS")
    @MainActor
    func syntaxEditorViewControllerMacTextObservation() async {
        let model = SyntaxEditorTestContext(text: "const answer = 42;", language: SyntaxLanguage.javascript)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()
        guard let delivery = controller.editorView.modelDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorViewController to expose its production document delivery")
            return
        }
        let renderedText = await delivery.values {
            controller.textView.string
        }

        #expect(await renderedText.waitUntilValue("const answer = 42;"))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))
    }

    @Test("SyntaxEditorViewController does not rerun macOS configuration observation for document changes")
    @MainActor
    func syntaxEditorViewControllerMacConfigurationObservationIgnoresDocumentChanges() async {
        let model = SyntaxEditorTestContext(text: "const answer = 42;", language: SyntaxLanguage.javascript)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()
        guard let configurationDelivery = controller.editorView.modelConfigurationDeliveryForTesting,
              let documentDelivery = controller.editorView.modelDeliveryForTesting
        else {
            Issue.record("Expected SyntaxEditorViewController to expose its production deliveries")
            return
        }
        let configurationPassCounter = SyntaxEditorObservationPassCounter()
        let configurationPasses = await configurationDelivery.values {
            configurationPassCounter.next()
        }
        let renderedText = await documentDelivery.values {
            controller.textView.string
        }

        #expect(await configurationPasses.waitUntilValue(1))

        model.model.language = SyntaxLanguage.json

        #expect(await configurationPasses.waitUntilValue(2))

        model.model.replaceText("{\"enabled\":true}")

        #expect(await renderedText.waitUntilValue("{\"enabled\":true}"))
        await syntaxEditorDrainMainActorObservationDelivery(recording: configurationPasses)
        #expect(configurationPasses.snapshot() == [1, 2])
    }

    @Test("SyntaxEditorViewController reflects editable and wrapping changes on macOS")
    @MainActor
    func syntaxEditorViewControllerMacEditorStateObservation() async {
        let model = SyntaxEditorTestContext(text: "body {}", language: SyntaxLanguage.css)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()
        guard let delivery = controller.editorView.modelConfigurationDeliveryForTesting else {
            Issue.record("Expected SyntaxEditorViewController to expose its production configuration delivery")
            return
        }
        let renderedState = await delivery.values {
            SyntaxEditorRenderedEditorState(
                isEditable: controller.textView.isEditable,
                wrapsLines: controller.scrollView.hasHorizontalScroller == false
            )
        }

        model.model.isEditable = false
        model.model.lineWrappingEnabled = true

        #expect(
            await renderedState.waitUntilValue(
                SyntaxEditorRenderedEditorState(isEditable: false, wrapsLines: true)
            )
        )

        model.model.lineWrappingEnabled = false

        #expect(
            await renderedState.waitUntilValue(
                SyntaxEditorRenderedEditorState(isEditable: false, wrapsLines: false)
            )
        )
    }

    @Test("SyntaxEditorViewController keeps synchronizing after language changes on macOS")
    @MainActor
    func syntaxEditorViewControllerMacLanguageChangeKeepsObservationAlive() async {
        let model = SyntaxEditorTestContext(text: "let answer = 42", language: SyntaxLanguage.swift)
        let controller = SyntaxEditorViewController(testContext: model)
        controller.loadViewIfNeeded()

        model.model.language = SyntaxLanguage.json
        model.model.isEditable = false

        controller.synchronizeDocumentForTesting()
        #expect(controller.textView.isEditable == false)

        model.model.replaceText("{\"answer\":42}")

        controller.synchronizeDocumentForTesting()
        #expect(controller.textView.string == "{\"answer\":42}")
    }
}
#endif
