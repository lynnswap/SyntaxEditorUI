import Foundation
import ObservationBridge
import Testing
@testable import SyntaxEditorUI

#if canImport(UIKit)
import UIKit
@testable import SyntaxEditorUIUIKit
#endif

#if canImport(AppKit)
import AppKit
@testable import SyntaxEditorUIAppKit
#endif

@MainActor
struct SyntaxEditorTestContext {
    let model: SyntaxEditorModel

    init(
        text: String = "",
        language: SyntaxLanguage = .javascript,
        isEditable: Bool = true,
        lineWrappingEnabled: Bool = false,
        theme: SyntaxEditorTheme = .default,
        drawsBackground: Bool = true,
        fontSizeDelta: Int = 0
    ) {
        self.model = SyntaxEditorModel(
            text: text,
            language: language,
            isEditable: isEditable,
            lineWrappingEnabled: lineWrappingEnabled,
            theme: theme,
            drawsBackground: drawsBackground,
            fontSizeDelta: fontSizeDelta
        )
    }
}

struct SyntaxEditorRenderedEditorState: Sendable, Equatable {
    var isEditable: Bool
    var wrapsLines: Bool
}

@MainActor
final class SyntaxEditorObservationPassCounter {
    var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

@MainActor
func syntaxEditorDrainMainActorObservationDelivery<Value>(
    recording values: ObservedValues<Value>,
    stablePassCount: Int = 2,
    maximumDrainPasses: Int = 8
) async {
    var previousCount = values.snapshot().count
    var stableCount = 0

    for _ in 0..<maximumDrainPasses {
        await Task { @MainActor in }.value

        let currentCount = values.snapshot().count
        if currentCount == previousCount {
            stableCount += 1
            if stableCount >= stablePassCount {
                return
            }
        } else {
            previousCount = currentCount
            stableCount = 0
        }
    }
}

extension SyntaxEditorView {
    convenience init(testContext: SyntaxEditorTestContext) {
        self.init(model: testContext.model)
    }

    convenience init(testContext: SyntaxEditorTestContext, highlighter: any SyntaxEditorHighlighting.Engine) {
        self.init(model: testContext.model, highlighter: highlighter)
    }
}

extension SyntaxEditorViewController {
    convenience init(testContext: SyntaxEditorTestContext) {
        self.init(model: testContext.model)
    }
}

func syntaxEditorUITestColor(hex: UInt32) -> SyntaxEditorTheme.Color {
    let red = CGFloat((hex >> 16) & 0xFF) / 255.0
    let green = CGFloat((hex >> 8) & 0xFF) / 255.0
    let blue = CGFloat(hex & 0xFF) / 255.0

#if canImport(UIKit)
    return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
#elseif canImport(AppKit)
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
#endif
}

func syntaxEditorUITestTheme(
    baseForeground: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x101112),
    bracketBackground: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x202122),
    comment: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x303132),
    string: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x404142),
    keyword: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x505152),
    number: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x606162),
    function: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x707172),
    type: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x808182),
    constant: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0x909192),
    variable: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0xA0A1A2),
    punctuation: SyntaxEditorTheme.Color = syntaxEditorUITestColor(hex: 0xB0B1B2),
    font: SyntaxEditorTheme.Font = SyntaxEditorTheme.Font.monospacedSystemFont(ofSize: 12, weight: .regular),
    background: SyntaxEditorTheme.Color = .clear
) -> SyntaxEditorTheme {
    SyntaxEditorTheme(
        baseForeground: baseForeground,
        bracketBackground: bracketBackground,
        comment: comment,
        string: string,
        keyword: keyword,
        number: number,
        function: function,
        type: type,
        constant: constant,
        variable: variable,
        punctuation: punctuation,
        font: font,
        background: background
    )
}

func syntaxEditorUITestColorsEqual(_ lhs: SyntaxEditorTheme.Color?, _ rhs: SyntaxEditorTheme.Color) -> Bool {
    guard let lhs else { return false }

#if canImport(UIKit)
    var lhsRed: CGFloat = 0
    var lhsGreen: CGFloat = 0
    var lhsBlue: CGFloat = 0
    var lhsAlpha: CGFloat = 0
    var rhsRed: CGFloat = 0
    var rhsGreen: CGFloat = 0
    var rhsBlue: CGFloat = 0
    var rhsAlpha: CGFloat = 0

    guard lhs.getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha),
          rhs.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha)
    else {
        return lhs.isEqual(rhs)
    }
#elseif canImport(AppKit)
    guard let lhs = lhs.usingColorSpace(.genericRGB),
          let rhs = rhs.usingColorSpace(.genericRGB)
    else {
        return lhs.isEqual(rhs)
    }

    let lhsRed = lhs.redComponent
    let lhsGreen = lhs.greenComponent
    let lhsBlue = lhs.blueComponent
    let lhsAlpha = lhs.alphaComponent
    let rhsRed = rhs.redComponent
    let rhsGreen = rhs.greenComponent
    let rhsBlue = rhs.blueComponent
    let rhsAlpha = rhs.alphaComponent
#endif

    return abs(lhsRed - rhsRed) < 0.002
        && abs(lhsGreen - rhsGreen) < 0.002
        && abs(lhsBlue - rhsBlue) < 0.002
        && abs(lhsAlpha - rhsAlpha) < 0.002
}

actor ManualSyntaxHighlightGate {
    struct SuspensionWaiter {
        let id: Int
        let minimumCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    struct ResumeWaiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    var suspensionCount = 0
    var nextSuspensionWaiterID = 0
    var suspensionWaiters: [SuspensionWaiter] = []
    var nextResumeWaiterID = 0
    var resumeContinuations: [ResumeWaiter] = []

    func suspend() async {
        let waiterID = nextResumeWaiterID
        nextResumeWaiterID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                resumeContinuations.append(ResumeWaiter(id: waiterID, continuation: continuation))
                suspensionCount += 1
                resumeReadySuspensionWaiters()
            }
        } onCancel: {
            Task {
                await self.cancelResumeContinuation(id: waiterID)
            }
        }
    }

    func currentSuspensionCount() -> Int {
        suspensionCount
    }

    @discardableResult
    func waitUntilSuspended(_ minimumCount: Int = 1) async -> Bool {
        guard suspensionCount < minimumCount else { return true }

        let waiterID = nextSuspensionWaiterID
        nextSuspensionWaiterID += 1

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }

                suspensionWaiters.append(
                    SuspensionWaiter(
                        id: waiterID,
                        minimumCount: minimumCount,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.resumeSuspensionWaiter(id: waiterID, result: false)
            }
        }
    }

    @discardableResult
    func waitUntilSuspended(after previousCount: Int) async -> Bool {
        await waitUntilSuspended(previousCount + 1)
    }

    @discardableResult
    func resumeOne() -> Bool {
        guard !resumeContinuations.isEmpty else { return false }
        let waiter = resumeContinuations.removeFirst()
        waiter.continuation.resume()
        return true
    }

    func resumeAll() {
        let waiters = resumeContinuations
        resumeContinuations.removeAll()

        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    func resumeSuspensionWaiter(id: Int, result: Bool) {
        guard let index = suspensionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = suspensionWaiters.remove(at: index)
        waiter.continuation.resume(returning: result)
    }

    func resumeReadySuspensionWaiters() {
        var readyWaiters: [SuspensionWaiter] = []
        suspensionWaiters.removeAll { waiter in
            guard suspensionCount >= waiter.minimumCount else {
                return false
            }
            readyWaiters.append(waiter)
            return true
        }

        for waiter in readyWaiters {
                waiter.continuation.resume(returning: true)
        }
    }

    func cancelResumeContinuation(id: Int) {
        guard let index = resumeContinuations.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = resumeContinuations.remove(at: index)
        waiter.continuation.resume()
    }
}

actor SyntaxEditorUITestHighlighter: SyntaxEditorHighlighting.Engine {
    let tokens: [SyntaxEditorHighlighting.Token]
    let updateTokens: [SyntaxEditorHighlighting.Token]?
    let resetGate: ManualSyntaxHighlightGate?
    let updateGate: ManualSyntaxHighlightGate?
    let updateRefreshRange: NSRange?
    let updateTokenPayload: SyntaxEditorHighlighting.Result.Payload
    var resetCount = 0
    var updateCount = 0

    init(
        tokens: [SyntaxEditorHighlighting.Token] = [],
        updateTokens: [SyntaxEditorHighlighting.Token]? = nil,
        resetGate: ManualSyntaxHighlightGate? = nil,
        updateGate: ManualSyntaxHighlightGate? = nil,
        updateRefreshRange: NSRange? = nil,
        updateTokenPayload: SyntaxEditorHighlighting.Result.Payload = .replacement
    ) {
        self.tokens = tokens
        self.updateTokens = updateTokens
        self.resetGate = resetGate
        self.updateGate = updateGate
        self.updateRefreshRange = updateRefreshRange
        self.updateTokenPayload = updateTokenPayload
    }

    func replaceCurrentRequest(
        with request: SyntaxEditorHighlighting.Request
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        syntaxEditorTestHighlightStream { [self] in
            switch request.operation {
            case .reset:
                await reset(source: request.source, language: request.language, revision: request.revision)
            case .update(let mutation):
                await update(
                    source: request.source,
                    language: request.language,
                    mutation: mutation,
                    revision: request.revision
                )
            }
        }
    }

    func reset(source: String, language: SyntaxLanguage, revision: Int) async -> SyntaxEditorHighlighting.Result {
        resetCount += 1
        if let resetGate {
            await resetGate.suspend()
        }
        return result(source: source, language: language, revision: revision, refreshRange: nil)
    }

    func update(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int
    ) async -> SyntaxEditorHighlighting.Result {
        updateCount += 1
        if let updateGate {
            await updateGate.suspend()
        }
        return result(
            tokens: updateTokens ?? tokens,
            source: source,
            language: language,
            revision: revision,
            refreshRange: updateRefreshRange,
            tokenPayload: updateTokenPayload
        )
    }

    func callCount() -> Int {
        resetCount + updateCount
    }

    func result(
        tokens: [SyntaxEditorHighlighting.Token]? = nil,
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        refreshRange: NSRange?,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) -> SyntaxEditorHighlighting.Result {
        let resolvedTokens = language == .plainText ? [] : tokens ?? self.tokens
        return SyntaxEditorHighlighting.Result(
            tokens: resolvedTokens,
            source: source,
            language: language,
            revision: revision,
            refreshRanges: [syntaxEditorTestClampedRange(
                refreshRange ?? NSRange(location: 0, length: source.utf16.count),
                textLength: source.utf16.count
            )],
            tokenPayload: tokenPayload
        )
    }
}

actor SyntaxEditorPhasedTestHighlighter: SyntaxEditorHighlighting.Engine {
    let fastTokens: [SyntaxEditorHighlighting.Token]
    let updateFastTokens: [SyntaxEditorHighlighting.Token]?
    let completeTokens: [SyntaxEditorHighlighting.Token]
    let updateCompleteTokens: [SyntaxEditorHighlighting.Token]?
    let completeGate: ManualSyntaxHighlightGate?
    let updateRefreshRange: NSRange?
    var resetCount = 0
    var updateCount = 0

    init(
        fastTokens: [SyntaxEditorHighlighting.Token],
        updateFastTokens: [SyntaxEditorHighlighting.Token]? = nil,
        completeTokens: [SyntaxEditorHighlighting.Token],
        updateCompleteTokens: [SyntaxEditorHighlighting.Token]? = nil,
        completeGate: ManualSyntaxHighlightGate? = nil,
        updateRefreshRange: NSRange? = nil
    ) {
        self.fastTokens = fastTokens
        self.updateFastTokens = updateFastTokens
        self.completeTokens = completeTokens
        self.updateCompleteTokens = updateCompleteTokens
        self.completeGate = completeGate
        self.updateRefreshRange = updateRefreshRange
    }

    func replaceCurrentRequest(
        with request: SyntaxEditorHighlighting.Request
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        switch request.operation {
        case .reset:
            resetPhases(source: request.source, language: request.language, revision: request.revision)
        case .update:
            updatePhases(source: request.source, language: request.language, revision: request.revision)
        }
    }

    private func resetPhases(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) -> AsyncStream<SyntaxEditorHighlighting.Result> {
        resetCount += 1
        return Self.phases(
            fastTokens: fastTokens,
            completeTokens: completeTokens,
            completeGate: completeGate,
            refreshRange: nil,
            source: source,
            language: language,
            revision: revision
        )
    }

    private func updatePhases(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) -> AsyncStream<SyntaxEditorHighlighting.Result> {
        updateCount += 1
        return Self.phases(
            fastTokens: updateFastTokens ?? fastTokens,
            completeTokens: updateCompleteTokens ?? completeTokens,
            completeGate: completeGate,
            refreshRange: updateRefreshRange,
            tokenPayload: .replacement,
            source: source,
            language: language,
            revision: revision
        )
    }

    func callCount() -> Int {
        resetCount + updateCount
    }

    private static func phases(
        fastTokens: [SyntaxEditorHighlighting.Token],
        completeTokens: [SyntaxEditorHighlighting.Token],
        completeGate: ManualSyntaxHighlightGate?,
        refreshRange: NSRange?,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot,
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) -> AsyncStream<SyntaxEditorHighlighting.Result> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(
                    result(
                        tokens: fastTokens,
                        source: source,
                        language: language,
                        revision: revision,
                        phase: .syntacticFastPass,
                        refreshRange: refreshRange,
                        tokenPayload: tokenPayload
                    )
                )
                if let completeGate {
                    await completeGate.suspend()
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(
                    result(
                        tokens: completeTokens,
                        source: source,
                        language: language,
                        revision: revision,
                        phase: .complete,
                        refreshRange: refreshRange,
                        tokenPayload: tokenPayload
                    )
                )
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func result(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        phase: SyntaxEditorHighlighting.Result.Phase,
        refreshRange: NSRange?,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) -> SyntaxEditorHighlighting.Result {
        return SyntaxEditorHighlighting.Result(
            tokens: tokens,
            source: source,
            language: language,
            revision: revision,
            refreshRanges: [syntaxEditorTestClampedRange(
                refreshRange ?? NSRange(location: 0, length: source.utf16.count),
                textLength: source.utf16.count
            )],
            phase: phase,
            tokenPayload: tokenPayload
        )
    }
}

/// The stream an engine returns for a request that produces one result.
private func syntaxEditorTestHighlightStream(
    _ operation: @escaping @Sendable () async -> SyntaxEditorHighlighting.Result
) -> AsyncStream<SyntaxEditorHighlighting.Result> {
    AsyncStream { continuation in
        let task = Task {
            let result = await operation()
            if !Task.isCancelled {
                continuation.yield(result)
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
    }
}

private func syntaxEditorTestClampedRange(_ range: NSRange, textLength: Int) -> NSRange {
    let textLength = max(0, textLength)
    let location = min(max(0, range.location), textLength)
    let upperBound = min(max(location, range.location + max(0, range.length)), textLength)
    return NSRange(location: location, length: upperBound - location)
}

actor SyntaxEditorLanguageAwareTestHighlighter: SyntaxEditorHighlighting.Engine {
    let swiftTokens: [SyntaxEditorHighlighting.Token]
    let jsonTokens: [SyntaxEditorHighlighting.Token]
    let resetGate: ManualSyntaxHighlightGate?
    let updateGate: ManualSyntaxHighlightGate?

    init(
        swiftTokens: [SyntaxEditorHighlighting.Token],
        jsonTokens: [SyntaxEditorHighlighting.Token],
        resetGate: ManualSyntaxHighlightGate? = nil,
        updateGate: ManualSyntaxHighlightGate? = nil
    ) {
        self.swiftTokens = swiftTokens
        self.jsonTokens = jsonTokens
        self.resetGate = resetGate
        self.updateGate = updateGate
    }

    func replaceCurrentRequest(
        with request: SyntaxEditorHighlighting.Request
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        syntaxEditorTestHighlightStream { [self] in
            switch request.operation {
            case .reset:
                await reset(source: request.source, language: request.language, revision: request.revision)
            case .update(let mutation):
                await update(
                    source: request.source,
                    language: request.language,
                    mutation: mutation,
                    revision: request.revision
                )
            }
        }
    }

    func reset(source: String, language: SyntaxLanguage, revision: Int) async -> SyntaxEditorHighlighting.Result {
        if let resetGate {
            await resetGate.suspend()
        }
        return result(source: source, language: language, revision: revision)
    }

    func update(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int
    ) async -> SyntaxEditorHighlighting.Result {
        if let updateGate {
            await updateGate.suspend()
        }
        return result(source: source, language: language, revision: revision)
    }

    func result(source: String, language: SyntaxLanguage, revision: Int) -> SyntaxEditorHighlighting.Result {
        let tokens: [SyntaxEditorHighlighting.Token] = if language == SyntaxLanguage.swift {
            swiftTokens
        } else if language == SyntaxLanguage.json {
            jsonTokens
        } else {
            []
        }
        return SyntaxEditorHighlighting.Result(
            tokens: tokens,
            source: source,
            language: language,
            revision: revision,
            refreshRanges: [NSRange(location: 0, length: source.utf16.count)]
        )
    }
}

func syntaxEditorDenseHighlightFixture(
    tokenCount: Int = 2_400
) -> (source: String, tokens: [SyntaxEditorHighlighting.Token]) {
    let source = String(repeating: "x", count: tokenCount)
    let tokens = (0..<tokenCount).map { index in
        SyntaxEditorHighlighting.Token(
            range: NSRange(location: index, length: 1),
            rawCaptureName: syntaxEditorDenseHighlightCaptureName(at: index)
        )
    }
    return (source, tokens)
}

func syntaxEditorDenseHighlightCaptureName(at index: Int) -> String {
    switch index % 3 {
    case 0: "editor.syntax.swift.keyword"
    case 1: "editor.syntax.swift.string"
    default: "editor.syntax.swift.comment"
    }
}

func syntaxEditorDenseHighlightColor(
    in theme: SyntaxEditorTheme,
    at index: Int
) -> SyntaxEditorTheme.Color {
    switch index % 3 {
    case 0: theme.keyword
    case 1: theme.string
    default: theme.comment
    }
}

#if canImport(UIKit)
let syntaxEditorKeyCommandModifierMask: UIKeyModifierFlags = [
    .command,
    .control,
    .alternate,
    .shift,
]

@MainActor
func syntaxEditorKeyCommand(
    _ commands: [UIKeyCommand]?,
    input: String,
    modifierFlags: UIKeyModifierFlags
) -> UIKeyCommand? {
    commands?.first { command in
        command.input == input
            && command.modifierFlags.intersection(syntaxEditorKeyCommandModifierMask) == modifierFlags
    }
}

@MainActor
func hasSyntaxEditorKeyCommand(
    _ commands: [UIKeyCommand]?,
    input: String,
    modifierFlags: UIKeyModifierFlags
) -> Bool {
    syntaxEditorKeyCommand(commands, input: input, modifierFlags: modifierFlags) != nil
}

@MainActor
func syntaxEditorChildMenu(_ menu: UIMenu, title: String) -> UIMenu? {
    menu.children.compactMap { $0 as? UIMenu }.first { $0.title == title }
}

@MainActor
func syntaxEditorChildKeyCommand(_ menu: UIMenu, title: String) -> UIKeyCommand? {
    for child in menu.children {
        if let command = child as? UIKeyCommand,
           command.title == title {
            return command
        }

        if let submenu = child as? UIMenu,
           let command = syntaxEditorChildKeyCommand(submenu, title: title) {
            return command
        }
    }

    return nil
}

@MainActor
@discardableResult
func performSyntaxEditorSelector(_ selectorName: String, on view: SyntaxEditorView) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard view.responds(to: selector) else {
        Issue.record("SyntaxEditorView does not respond to \(selectorName)")
        return false
    }

    _ = view.perform(selector, with: nil)
    return true
}

let longSyntaxEditorLine = String(
    repeating: "let extremelyLongIdentifierName = syntaxEditorHorizontalScrollValue; ",
    count: 4
)

let longSyntaxEditorMultilineText = """
const answer = 42;
function greet(name) {
    \(String(repeating: "return HelloName; ", count: 10))
}
"""

let visibleMidSyntaxEditorLocation = 20

final class SyntaxEditorUITestInputDelegate: NSObject, UITextInputDelegate {
    var textWillChangeCount = 0
    var textDidChangeCount = 0
    var selectionWillChangeCount = 0
    var selectionDidChangeCount = 0
    var textDidChangeHandler: (((any UITextInput)?) -> Void)?

    func textWillChange(_ textInput: (any UITextInput)?) {
        textWillChangeCount += 1
    }

    func textDidChange(_ textInput: (any UITextInput)?) {
        textDidChangeCount += 1
        textDidChangeHandler?(textInput)
    }

    func selectionWillChange(_ textInput: (any UITextInput)?) {
        selectionWillChangeCount += 1
    }

    func selectionDidChange(_ textInput: (any UITextInput)?) {
        selectionDidChangeCount += 1
    }

    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
}

final class SyntaxEditorUITestForeignTextPosition: UITextPosition {}

let offscreenWideSyntaxEditorText: String = {
    let leadingShortLines = (0..<20).map { "let short\($0) = true;" }
    let wideLine = [String(repeating: "let offscreenHorizontalScrollRange = value; ", count: 24)]
    let trailingShortLines = (20..<60).map { "let short\($0) = false;" }
    return (leadingShortLines + wideLine + trailingShortLines).joined(separator: "\n")
}()

let offscreenWideUnicodeSyntaxEditorLine = String(repeating: "漢字🙂", count: 80)

let offscreenWideUnicodeSyntaxEditorText: String = {
    let leadingShortLines = (0..<20).map { "let short\($0) = true;" }
    let trailingShortLines = (20..<60).map { "let short\($0) = false;" }
    return (leadingShortLines + [offscreenWideUnicodeSyntaxEditorLine] + trailingShortLines)
        .joined(separator: "\n")
}()

@MainActor
func layoutIOSEditorView(
    _ editorView: SyntaxEditorView,
    width: CGFloat = 160,
    height: CGFloat = 120
) {
    editorView.frame = CGRect(x: 0, y: 0, width: width, height: height)
    editorView.setNeedsLayout()
    editorView.layoutIfNeeded()
}

@MainActor
func iOSEditorStableHorizontalOffset(_ editorView: SyntaxEditorView) -> CGFloat {
    max(0, (editorView.contentSize.width - editorView.bounds.width) * 0.25)
}

@MainActor
func iOSEditorLineMidY(_ editorView: SyntaxEditorView, lineIndex: Int) -> CGFloat {
    editorView.textContainerInset.top + editorView.font.lineHeight * (CGFloat(lineIndex) + 0.5)
}

@MainActor
func iOSEditorHasHorizontalOverflow(_ editorView: SyntaxEditorView) -> Bool {
    layoutIOSEditorView(editorView)
    return !editorView.textContainer.widthTracksTextView
        && editorView.contentSize.width > editorView.bounds.width + 1
        && editorView.textContainer.size.width > editorView.bounds.width
}

@MainActor
func iOSEditorHorizontalOverflowDiagnostics(_ editorView: SyntaxEditorView) -> String {
    layoutIOSEditorView(editorView)
    return "widthTracksTextView=\(editorView.textContainer.widthTracksTextView) "
        + "contentSize=\(editorView.contentSize) "
        + "bounds=\(editorView.bounds) "
        + "textContainer.size=\(editorView.textContainer.size) "
        + "lineBreakMode=\(String(describing: iOSEditorLineBreakMode(editorView)))"
}

@MainActor
func iOSEditorRenderedContentFrame(_ editorView: SyntaxEditorView) -> CGRect? {
    let frame = editorView.renderedTextContentFrameForTesting
    guard frame.width > 0 else { return nil }

    return frame
}

@MainActor
func iOSEditorTextUsageHeight(_ editorView: SyntaxEditorView) -> CGFloat {
    (editorView.textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0)
        + editorView.textContainerInset.top
        + editorView.textContainerInset.bottom
}

@MainActor
func iOSEditorVisibleTextContainerRect(_ editorView: SyntaxEditorView) -> CGRect {
    CGRect(
        x: max(0, editorView.contentOffset.x - editorView.textContainerInset.left),
        y: max(0, editorView.contentOffset.y - editorView.textContainerInset.top),
        width: min(
            editorView.textContainer.size.width,
            editorView.bounds.width + editorView.textContainerInset.left + editorView.textContainerInset.right
        ),
        height: editorView.bounds.height
            + editorView.textContainerInset.top
            + editorView.textContainerInset.bottom
    )
}

@MainActor
func editorTextLayoutUsageBoundsCoverVisibleHorizontalViewport(_ editorView: SyntaxEditorView) -> Bool {
    guard let textLayoutManager = editorView.textLayoutManager else {
        return false
    }

    let visibleRect = iOSEditorVisibleTextContainerRect(editorView)
    textLayoutManager.ensureLayout(for: visibleRect)

    return textLayoutManager.usageBoundsForTextContainer.maxX >= visibleRect.maxX - 1
}

@MainActor
func editorTextLayoutDiagnostics(_ editorView: SyntaxEditorView) -> String {
    let visibleRect = iOSEditorVisibleTextContainerRect(editorView)
    let usageBounds = editorView.textLayoutManager?.usageBoundsForTextContainer ?? .null
    return "textLayoutManager=\(String(describing: editorView.textLayoutManager)) "
        + "offset=\(editorView.contentOffset) "
        + "bounds=\(editorView.bounds) "
        + "contentSize=\(editorView.contentSize) "
        + "textContainer.size=\(editorView.textContainer.size) "
        + "visibleTextContainerRect=\(visibleRect) "
        + "usageBounds=\(usageBounds)"
}

@MainActor
func iOSEditorHasBackgroundAttribute(_ editorView: SyntaxEditorView, at location: Int) -> Bool {
    editorView.bracketHighlightRangesForTesting.contains { NSLocationInRange(location, $0) }
}

@MainActor
func iOSEditorForegroundColor(_ editorView: SyntaxEditorView, at location: Int) -> UIColor? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    if let color = editorView.syntaxForegroundColorForTesting(at: location) {
        return color
    }

    if let color = attributedText.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor {
        return color
    }

    return editorView.baseForegroundColorForTesting()
}

@MainActor
func iOSEditorPermanentForegroundColor(_ editorView: SyntaxEditorView, at location: Int) -> UIColor? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    return attributedText.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
}

@MainActor
func iOSEditorFont(_ editorView: SyntaxEditorView, at location: Int) -> UIFont? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    if let font = editorView.syntaxFontForTesting(at: location) {
        return font
    }

    return attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont
}

@MainActor
func iOSEditorPermanentFont(_ editorView: SyntaxEditorView, at location: Int) -> UIFont? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    return attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont
}

func syntaxEditorUITestFontsEqual(_ lhs: UIFont?, _ rhs: UIFont?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.fontName == rhs.fontName
        && abs(lhs.pointSize - rhs.pointSize) < 0.01
}

@MainActor
func iOSEditorLineFragmentForegroundColor(_ editorView: SyntaxEditorView, at location: Int) -> UIColor? {
    if let color = editorView.syntaxForegroundColorForTesting(at: location) {
        return color
    }

    guard let textLayoutManager = editorView.textLayoutManager,
          let textLocation = editorView.textLocation(forUTF16Offset: location)
    else {
        return nil
    }

    guard let layoutFragment = textLayoutManager.textLayoutFragment(for: textLocation),
          let lineFragment = layoutFragment.textLineFragments.first(where: {
              NSLocationInRange(location, $0.characterRange)
          })
    else {
        return nil
    }

    let localLocation = location - lineFragment.characterRange.location
    guard localLocation >= 0, localLocation < lineFragment.attributedString.length else {
        return nil
    }
    if let color = lineFragment.attributedString.attribute(.foregroundColor, at: localLocation, effectiveRange: nil) as? UIColor {
        return color
    }

    return editorView.baseForegroundColorForTesting()
}

@MainActor
func iOSEditorLineBreakMode(_ editorView: SyntaxEditorView, at location: Int = 0) -> NSLineBreakMode? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    return (attributedText.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
        .lineBreakMode
}

@MainActor
func iOSEditorParagraphSpacing(_ editorView: SyntaxEditorView, at location: Int = 0) -> CGFloat? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    return (attributedText.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
        .paragraphSpacing
}

@MainActor
func iOSEditorUnderlineStyle(_ editorView: SyntaxEditorView, at location: Int) -> Int? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    let value = attributedText.attribute(.underlineStyle, at: location, effectiveRange: nil)
    if let number = value as? NSNumber {
        return number.intValue
    }
    return value as? Int
}

@MainActor
func iOSEditorUnderlineColor(_ editorView: SyntaxEditorView, at location: Int) -> UIColor? {
    guard let attributedText = editorView.attributedText,
          location >= 0,
          location < attributedText.length
    else {
        return nil
    }

    return attributedText.attribute(.underlineColor, at: location, effectiveRange: nil) as? UIColor
}

#endif

#if canImport(AppKit)
let syntaxEditorMenuItemModifierMask: NSEvent.ModifierFlags = [
    .command,
    .control,
    .option,
    .shift,
]

final class SyntaxEditorNotificationRecorder: NSObject {
    private(set) var count = 0

    @objc
    func record(_ notification: Notification) {
        count += 1
    }
}

@MainActor
func macEditorForegroundColor(_ editorView: SyntaxEditorView, at location: Int) -> NSColor? {
    guard let textStorage = editorView.textView.textStorage else {
        return nil
    }
    guard location >= 0,
          location < textStorage.length
    else {
        return nil
    }

    if let color = editorView.syntaxForegroundColorForTesting(at: location) {
        return color
    }

    if let color = textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor {
        return color
    }

    return editorView.baseForegroundColorForTesting()
}

@MainActor
func macEditorPermanentForegroundColor(_ editorView: SyntaxEditorView, at location: Int) -> NSColor? {
    guard let textStorage = editorView.textView.textStorage else {
        return nil
    }
    guard location >= 0,
          location < textStorage.length
    else {
        return nil
    }

    return textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
}

@MainActor
func macEditorFont(_ editorView: SyntaxEditorView, at location: Int) -> NSFont? {
    guard let textStorage = editorView.textView.textStorage else {
        return nil
    }
    guard location >= 0,
          location < textStorage.length
    else {
        return nil
    }

    if let font = editorView.syntaxFontForTesting(at: location) {
        return font
    }

    return textStorage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
}

func syntaxEditorUITestFontsEqual(_ lhs: NSFont?, _ rhs: NSFont?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.fontName == rhs.fontName
        && abs(lhs.pointSize - rhs.pointSize) < 0.01
}

@MainActor
func macEditorUnderlineStyle(_ editorView: SyntaxEditorView, at location: Int) -> Int? {
    guard let textStorage = editorView.textView.textStorage else {
        return nil
    }
    guard location >= 0,
          location < textStorage.length
    else {
        return nil
    }

    let value = textStorage.attribute(.underlineStyle, at: location, effectiveRange: nil)
    if let number = value as? NSNumber {
        return number.intValue
    }
    return value as? Int
}

@MainActor
func macEditorBackgroundColor(_ editorView: SyntaxEditorView, at location: Int) -> NSColor? {
    guard let textStorage = editorView.textView.textStorage else {
        return nil
    }
    guard location >= 0,
          location < textStorage.length
    else {
        return nil
    }

    if let color = editorView.textView.layoutManager?.temporaryAttribute(
        .backgroundColor,
        atCharacterIndex: location,
        effectiveRange: nil
    ) as? NSColor {
        return color
    }

    return textStorage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
}

@MainActor
func macEditorHasBackgroundAttribute(_ editorView: SyntaxEditorView, at location: Int) -> Bool {
    if editorView.bracketHighlightRangesForTesting.contains(where: { NSLocationInRange(location, $0) }) {
        return true
    }
    return macEditorBackgroundColor(editorView, at: location) != nil
}

@MainActor
func macEditorTextStorageBackgroundColor(_ editorView: SyntaxEditorView, at location: Int) -> NSColor? {
    guard let textStorage = editorView.textView.textStorage else {
        return nil
    }
    guard location >= 0,
          location < textStorage.length
    else {
        return nil
    }

    return textStorage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
}

@MainActor
func macEditorVisibleFragmentViews(_ editorView: SyntaxEditorView) -> [SyntaxEditorTextInputView.TextLayoutFragmentView] {
    editorView.textView.layoutVisibleViewport()
    return editorView.textView.textContentView.subviews.compactMap { $0 as? SyntaxEditorTextInputView.TextLayoutFragmentView }
}

@MainActor
func macEditorRenderedFragmentContainsDominantColor(
    _ fragmentView: SyntaxEditorTextInputView.TextLayoutFragmentView,
    targetColor: NSColor,
    backgroundColor: NSColor,
    minimumPixelCount: Int = 8
) -> Bool {
    let bounds = fragmentView.bounds
    guard bounds.width > 0, bounds.height > 0 else {
        return false
    }

    let renderSize = NSSize(
        width: min(ceil(bounds.width), 600),
        height: min(ceil(bounds.height), 200)
    )
    guard renderSize.width > 0, renderSize.height > 0 else {
        return false
    }

    let image = NSImage(size: renderSize)
    image.lockFocus()
    backgroundColor.setFill()
    NSRect(origin: .zero, size: renderSize).fill()
    fragmentView.draw(NSRect(origin: .zero, size: renderSize))
    image.unlockFocus()

    guard let tiffRepresentation = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffRepresentation)
    else {
        return false
    }

    var matchingPixels = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y),
                  syntaxEditorUITestRenderedColor(color, matchesDominantTarget: targetColor)
            else {
                continue
            }

            matchingPixels += 1
            if matchingPixels >= minimumPixelCount {
                return true
            }
        }
    }
    return false
}

@MainActor
func macEditorDrawFragment(
    _ fragmentView: SyntaxEditorTextInputView.TextLayoutFragmentView,
    dirtyRect: NSRect,
    backgroundColor: NSColor
) {
    let renderSize = NSSize(
        width: max(1, ceil(fragmentView.bounds.width)),
        height: max(1, ceil(fragmentView.bounds.height))
    )
    let image = NSImage(size: renderSize)
    image.lockFocus()
    backgroundColor.setFill()
    NSRect(origin: .zero, size: renderSize).fill()
    fragmentView.draw(dirtyRect)
    image.unlockFocus()
}

private func syntaxEditorUITestRenderedColor(
    _ color: NSColor,
    matchesDominantTarget targetColor: NSColor
) -> Bool {
    guard let color = color.usingColorSpace(.deviceRGB),
          color.alphaComponent > 0.05,
          let targetColor = targetColor.usingColorSpace(.deviceRGB)
    else {
        return false
    }

    let components = [
        color.redComponent,
        color.greenComponent,
        color.blueComponent,
    ]
    let targetComponents = [
        targetColor.redComponent,
        targetColor.greenComponent,
        targetColor.blueComponent,
    ]
    guard let dominantIndex = targetComponents.indices.max(by: {
        targetComponents[$0] < targetComponents[$1]
    }) else {
        return false
    }

    let dominant = components[dominantIndex]
    let strongestOther = components.enumerated()
        .filter { $0.offset != dominantIndex }
        .map(\.element)
        .max() ?? 0
    return dominant > 0.22 && dominant > strongestOther * 1.8
}

func makeMacCommandKeyEvent(
    _ character: String,
    modifierFlags: NSEvent.ModifierFlags = [.command]
) -> NSEvent? {
    makeMacKeyEvent(character, modifierFlags: modifierFlags)
}

func makeMacKeyEvent(
    _ character: String,
    modifierFlags: NSEvent.ModifierFlags = []
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: 0
    )
}

@MainActor
func syntaxEditorSubmenu(_ menu: NSMenu, title: String) -> NSMenu? {
    menu.item(withTitle: title)?.submenu
}
#endif
