import Foundation
import Observation
import ObservationBridge

/// An observable comparison between a reference document and an existing editor model.
///
/// Keep this model in persistent app state. The modified document remains the same
/// `SyntaxEditorModel` used for editing and saving. Reference text is read-only in
/// comparison views, but your app can replace it through ``originalText``.
///
/// Differences are calculated asynchronously. ``changeCount`` is `nil` until a
/// result for the current texts is available; zero means the texts are identical.
@MainActor
@Observable
public final class SyntaxEditorComparisonModel {
    /// The way a comparison presents the reference and modified documents.
    public enum Presentation: Sendable {
        /// Shows the modified document with change markers in its margin.
        case changeMarkers
        /// Shows deleted reference text alongside the modified document's lines.
        case inline
        /// Shows the modified document on the left and the reference on the right.
        case sideBySide
    }

    /// The existing model that owns the modified text, selection, and settings.
    public let modified: SyntaxEditorModel

    /// The reference contents used to calculate changes.
    ///
    /// Replacing this text recalculates differences without editing the modified
    /// document or affecting its selection and undo history. Equality compares
    /// UTF-16 code units, so changes to normalization and line endings are preserved.
    public var originalText: String {
        get { original.text }
        set { original.text = newValue }
    }

    /// The comparison's display format. Changing it does not recalculate differences.
    public var presentation: Presentation

    /// The number of changes in the current texts, or `nil` while they are being compared.
    ///
    /// A change groups adjacent added and removed lines. Large ambiguous regions
    /// may be grouped into one change to bound the work needed to compare them.
    public var changeCount: Int? {
        changes?.count
    }

    /// The selected change's zero-based index in the current result, if any.
    ///
    /// Selecting a change highlights and reveals it without replacing the modified
    /// document's text selection. A text change clears the selected change.
    public var selectedChangeIndex: Int? {
        changes == nil ? nil : selection
    }

    package let original: SyntaxEditorModel

    package var changes: [EditorComparisonEngine.Change]? {
        guard let result,
              result.originalRevision == original.textRevision,
              result.modifiedRevision == modified.textRevision
        else { return nil }
        return result.changes
    }

    private struct Result {
        let originalRevision: Int
        let modifiedRevision: Int
        let changes: [EditorComparisonEngine.Change]
    }

    private var result: Result?
    private var selection: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var calculation: Task<Void, Never>?
    @ObservationIgnored private var textObservation: PortableObservationTracking.Token?
    @ObservationIgnored private var configurationObservation: PortableObservationTracking.Token?
    @ObservationIgnored private let compare: @Sendable (String, String) async throws -> [EditorComparisonEngine.Change]

    /// Creates a comparison with an app-owned modified document.
    ///
    /// - Parameters:
    ///   - originalText: Reference contents. No file or source-control operations are performed.
    ///   - modified: The existing model to display and edit.
    ///   - presentation: The initial display format. The default is inline comparison.
    public convenience init(
        originalText: String,
        modified: SyntaxEditorModel,
        presentation: Presentation = .inline
    ) {
        self.init(
            originalText: originalText,
            modified: modified,
            presentation: presentation,
            compare: { try await EditorComparisonEngine.compare(original: $0, modified: $1) }
        )
    }

    package init(
        originalText: String,
        modified: SyntaxEditorModel,
        presentation: Presentation = .inline,
        compare: @escaping @Sendable (String, String) async throws -> [EditorComparisonEngine.Change]
    ) {
        self.modified = modified
        self.presentation = presentation
        self.compare = compare
        let original = SyntaxEditorModel(text: originalText, language: modified.language, isEditable: false)
        self.original = original

        configurationObservation = withPortableContinuousObservation { [modified, original] _ in
            original.language = modified.language
            original.theme = modified.theme
            original.fontSizeDelta = modified.fontSizeDelta
            original.lineWrappingEnabled = modified.lineWrappingEnabled
            original.drawsBackground = modified.drawsBackground
        }
        textObservation = withPortableContinuousObservation { [weak self, original, modified] _ in
            let originalRevision = original.textRevision
            let modifiedRevision = modified.textRevision
            let originalText = original.text
            let modifiedText = modified.text
            self?.scheduleComparison(
                originalText: originalText,
                modifiedText: modifiedText,
                originalRevision: originalRevision,
                modifiedRevision: modifiedRevision
            )
        }
    }

    deinit {
        calculation?.cancel()
    }

    /// Selects and reveals the next change, returning whether a change was selected.
    ///
    /// With no selected change, starts at the modified document's insertion point.
    /// Does not wrap at the last change. Returns `false` while comparison is pending.
    @discardableResult
    public func selectNextChange() -> Bool {
        guard let changes, !changes.isEmpty else { return false }
        let next: Int?
        if let selection {
            next = selection + 1 < changes.count ? selection + 1 : nil
        } else {
            let location = modified.selectedRange.location
            next = changes.firstIndex {
                $0.modifiedRange.location + $0.modifiedRange.length > location
                    || $0.modifiedRange.location == location
            }
        }
        guard let next else { return false }
        selection = next
        return true
    }

    /// Selects and reveals the previous change, returning whether a change was selected.
    ///
    /// With no selected change, starts at or before the modified document's insertion point.
    /// Does not wrap at the first change. Returns `false` while comparison is pending.
    @discardableResult
    public func selectPreviousChange() -> Bool {
        guard let changes, !changes.isEmpty else { return false }
        let previous: Int?
        if let selection {
            previous = selection > 0 ? selection - 1 : nil
        } else {
            let location = modified.selectedRange.location
            previous = changes.lastIndex { $0.modifiedRange.location <= location }
        }
        guard let previous else { return false }
        selection = previous
        return true
    }

    @discardableResult
    package func selectChange(at index: Int) -> Bool {
        guard let changes, changes.indices.contains(index) else { return false }
        selection = index
        return true
    }

    private func scheduleComparison(
        originalText: String,
        modifiedText: String,
        originalRevision: Int,
        modifiedRevision: Int
    ) {
        calculation?.cancel()
        generation += 1
        let generation = generation
        let compare = compare
        result = nil
        selection = nil

        calculation = Task { [weak self] in
            // The engine only throws for cancellation; a cancelled calculation
            // has no result to publish.
            guard let changes = try? await compare(originalText, modifiedText),
                  !Task.isCancelled,
                  let self,
                  self.generation == generation,
                  self.original.textRevision == originalRevision,
                  self.modified.textRevision == modifiedRevision
            else { return }
            self.result = Result(
                originalRevision: originalRevision,
                modifiedRevision: modifiedRevision,
                changes: changes
            )
        }
    }
}
