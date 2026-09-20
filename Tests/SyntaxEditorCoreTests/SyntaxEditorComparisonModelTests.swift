import Foundation
import ObservationBridge
import Testing
import SyntaxEditorCore
@testable import SyntaxEditorModel

@Suite("Editor comparison model", .timeLimit(.minutes(1)))
@MainActor
struct SyntaxEditorComparisonModelTests {
    @Test("Compares existing documents without changing their state")
    func basicComparison() async throws {
        let document = SyntaxEditorModel(text: "a\nnew\nz\n", selectedRange: NSRange(location: 2, length: 0))
        let model = SyntaxEditorComparisonModel(originalText: "a\nold\nz\n", modified: document)
        #expect(model.modified === document)
        #expect(model.changeCount == nil)
        #expect(model.selectedChangeIndex == nil)
        #expect(!model.original.isEditable)
        let changes = try await ready(model)
        #expect(changes.count == 1)
        #expect(model.changeCount == 1)
        #expect(document.text == "a\nnew\nz\n")
        #expect(document.textRevision == 0)
        #expect(model.selectNextChange())
        #expect(model.selectedChangeIndex == 0)
        #expect(!model.selectNextChange())
        #expect(!model.selectPreviousChange())
        #expect(document.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("Reference and document changes invalidate results immediately")
    func updates() async throws {
        let document = SyntaxEditorModel(text: "a\n")
        let model = SyntaxEditorComparisonModel(originalText: "a\n", modified: document)
        #expect(try await ready(model).isEmpty)
        #expect(model.changeCount == 0)
        #expect(!model.selectNextChange())
        document.text = "b\n"
        #expect(model.changeCount == nil)
        #expect(!model.selectNextChange())
        #expect(try await ready(model).count == 1)
        model.originalText = "b\n"
        #expect(model.changeCount == nil)
        #expect(model.selectedChangeIndex == nil)
        #expect(try await ready(model).isEmpty)
        #expect(document.textRevision == 1)
    }

    @Test("Normalization-only replacements remain observable")
    func exactTextChanges() async throws {
        let document = SyntaxEditorModel(text: "é\n")
        let model = SyntaxEditorComparisonModel(originalText: "é\n", modified: document)
        _ = try await ready(model)
        let observation = withPortableContinuousObservation { _ in _ = document.text }
        defer { observation.cancel() }
        let values = await observation.values { Array(document.text.utf16) }

        document.text = "e\u{301}\n"
        #expect(document.textRevision == 1)
        #expect(document.text.utf16.elementsEqual("e\u{301}\n".utf16))
        #expect(await values.waitUntilValue(Array("e\u{301}\n".utf16)))
        #expect(try await ready(model).count == 1)
        model.originalText = "e\u{301}\n"
        #expect(try await ready(model).isEmpty)
    }

    @Test("Configuration and presentation changes preserve the calculated comparison")
    func configuration() async throws {
        let document = SyntaxEditorModel(text: "new")
        let model = SyntaxEditorComparisonModel(originalText: "old", modified: document)
        let changes = try await ready(model)
        #expect(model.selectNextChange())
        let observation = withPortableContinuousObservation { _ in
            _ = model.original.fontSizeDelta
            _ = model.original.language
            _ = model.original.lineWrappingEnabled
        }
        defer { observation.cancel() }
        let values = await observation.values {
            model.original.fontSizeDelta == 3
                && model.original.language == .swift
                && model.original.lineWrappingEnabled
        }
        model.presentation = .sideBySide
        document.fontSizeDelta = 3
        document.language = .swift
        document.lineWrappingEnabled = true
        #expect(await values.waitUntilValue(true))
        #expect(model.changes == changes)
        #expect(model.changeCount == 1)
        #expect(model.selectedChangeIndex == 0)
        #expect(document.textRevision == 0)
    }

    @Test("Navigation includes zero-length deletion anchors and does not wrap")
    func navigation() async throws {
        let document = SyntaxEditorModel(text: "new\nkeep\n")
        let model = SyntaxEditorComparisonModel(originalText: "old\nkeep\ndeleted\n", modified: document)
        let changes = try await ready(model)
        #expect(changes.count == 2)
        #expect(changes.last?.modifiedRange == NSRange(location: document.text.utf16.count, length: 0))
        #expect(model.selectNextChange())
        #expect(model.selectedChangeIndex == 0)
        #expect(model.selectNextChange())
        #expect(model.selectedChangeIndex == 1)
        #expect(!model.selectNextChange())
        #expect(model.selectPreviousChange())
        #expect(model.selectedChangeIndex == 0)

        let atEnd = SyntaxEditorComparisonModel(originalText: "old\nkeep\ndeleted\n", modified: document)
        _ = try await ready(atEnd)
        document.selectedRange = NSRange(location: document.text.utf16.count, length: 0)
        #expect(atEnd.selectNextChange())
        #expect(atEnd.selectedChangeIndex == 1)
    }

    @Test("A cancelled older computation cannot replace a newer result")
    func completionOrder() async throws {
        let gate = ComparisonGate()
        let document = SyntaxEditorModel(text: "first")
        let model = SyntaxEditorComparisonModel(originalText: "base", modified: document) { _, modified in
            await gate.run(modified)
        }
        let firstTask = try #require(model.calculation)
        await gate.waitForRequest("first")
        document.text = "second"
        await gate.waitForRequest("second")
        let secondTask = try #require(model.calculation)
        let change = EditorComparisonEngine.Change(
            originalRange: NSRange(location: 0, length: 4),
            modifiedRange: NSRange(location: 0, length: 6),
            originalLines: 0..<1, modifiedLines: 0..<1, inlineChanges: []
        )
        await gate.finish("second", with: [change])
        await secondTask.value
        #expect(model.changes == [change])
        await gate.finish("first", with: [])
        await firstTask.value
        #expect(model.changes == [change])
        #expect(model.changeCount == 1)
    }

    @Test("Suspended work does not retain the comparison model")
    func lifetime() async throws {
        let gate = ComparisonGate()
        let document = SyntaxEditorModel(text: "pending")
        var model: SyntaxEditorComparisonModel? = SyntaxEditorComparisonModel(originalText: "base", modified: document) { _, modified in
            await gate.run(modified)
        }
        weak var reference = model
        let task = try #require(model?.calculation)
        await gate.waitForRequest("pending")
        model = nil
        #expect(reference == nil)
        #expect(task.isCancelled)
        await gate.finish("pending", with: [])
        await task.value
        #expect(document.text == "pending")
    }

    private func ready(_ model: SyntaxEditorComparisonModel) async throws -> [EditorComparisonEngine.Change] {
        let observation = withPortableContinuousObservation { _ in _ = model.changes }
        defer { observation.cancel() }
        let values = await observation.values { model.changes }
        let result = try #require(await values.waitUntil { $0 != nil })
        return try #require(result)
    }
}

private actor ComparisonGate {
    private var requests: [String: CheckedContinuation<[EditorComparisonEngine.Change], Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func run(_ text: String) async -> [EditorComparisonEngine.Change] {
        await withCheckedContinuation { continuation in
            requests[text] = continuation
            waiters.removeValue(forKey: text)?.resume()
        }
    }

    func waitForRequest(_ text: String) async {
        if requests[text] != nil { return }
        await withCheckedContinuation { waiters[text] = $0 }
    }

    func finish(_ text: String, with changes: [EditorComparisonEngine.Change]) {
        requests.removeValue(forKey: text)?.resume(returning: changes)
    }
}
