import Foundation
import SyntaxEditorCore

/// The editor view a ``HighlightRequestCoordinator`` schedules highlighting for.
@MainActor
package protocol HighlightRequestCoordinatorClient: AnyObject {
    /// The revision of the text the editor currently displays.
    var highlightTextRevision: Int { get }

    /// Whether the editor currently renders any syntax runs.
    var hasRenderedHighlightRuns: Bool { get }

    /// Starts a full highlight of `source`, replacing the request in flight.
    ///
    /// The coordinator calls this when a partial result arrives that the editor
    /// has no baseline to apply onto.
    func scheduleFullHighlight(source: String, language: SyntaxLanguage, revision: Int)

    /// Renders `result`, returning whether it was applied.
    ///
    /// Return `false` when the result went stale while it was being applied or
    /// when the editor keeps it for later. In the latter case the editor calls
    /// ``HighlightRequestCoordinator/recordApplied(_:)`` once it renders it.
    func applyHighlightResult(_ result: SyntaxEditorHighlighting.Result) async -> Bool
}

/// Owns an editor's highlight request.
///
/// The coordinator hands requests to the engine, decides which of the results
/// that come back may be applied, and remembers what the editor has rendered so
/// later results and theme changes can build on it. Rendering itself stays in
/// the platform view, which acts as the coordinator's client.
@MainActor
package final class HighlightRequestCoordinator {
    package struct ScheduledRequest: Equatable {
        package let id: Int
        package let language: SyntaxLanguage
        package let revision: Int
        package let mutation: SyntaxEditorTextChange.Replacement?
    }

    /// The most recent result the editor rendered.
    package struct MaterializedHighlight: Equatable {
        package let phase: SyntaxEditorHighlighting.Result.Phase
        package let revision: Int
        package let language: SyntaxLanguage
    }

    package enum Event: Equatable {
        /// A request was scheduled or the cache was cleared. Earlier phase
        /// events no longer describe the editor.
        case requestsReset
        case applied(SyntaxEditorHighlighting.Result.Phase, revision: Int)
        case skipped(SyntaxEditorHighlighting.Result.Phase, revision: Int)
        /// The scheduled request for `revision` ended without a successor.
        case requestFinished(revision: Int)
    }

    private struct TokenSnapshot {
        let tokens: [SyntaxEditorHighlighting.Token]
        let source: String
        let revision: Int
        let language: SyntaxLanguage
    }

    package weak var client: (any HighlightRequestCoordinatorClient)?

    /// Receives each scheduling and phase event as it happens.
    package var eventObserver: ((Event) -> Void)?

    package private(set) var task: Task<Void, Never>?
    package private(set) var scheduledRequest: ScheduledRequest?
    /// The number of requests scheduled so far. A change while awaiting
    /// ``task`` means a successor was scheduled.
    package private(set) var scheduledRequestCount = 0
    package private(set) var materialized: MaterializedHighlight?

    private let engine: any SyntaxEditorHighlighting.Engine
    private var tokenSnapshot: TokenSnapshot?

    package init(engine: any SyntaxEditorHighlighting.Engine) {
        self.engine = engine
    }

    isolated deinit {
        task?.cancel()
    }

    // MARK: - Scheduling

    /// Replaces the request in flight with a highlight of `source`.
    ///
    /// - Parameters:
    ///   - mutation: The single replacement that produced `source` from the
    ///     previously highlighted text, or `nil` to highlight from scratch.
    ///   - visibleRange: The range on screen, which the engine processes first.
    package func schedule(
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        mutation: SyntaxEditorTextChange.Replacement?,
        visibleRange: NSRange?
    ) {
        task?.cancel()
        let requestID = scheduledRequestCount
        scheduledRequestCount += 1
        scheduledRequest = ScheduledRequest(
            id: requestID,
            language: language,
            revision: revision,
            mutation: mutation
        )
        eventObserver?(.requestsReset)

        let request = SyntaxEditorHighlighting.Request(
            source: source,
            language: language,
            revision: revision,
            operation: mutation.map { SyntaxEditorHighlighting.Request.Operation.update($0) } ?? .reset,
            visibleRange: visibleRange
        )
        let shouldYieldBeforeReplacingRequest = !source.isEmpty
        // The user is actively waiting on this pipeline (it recolors the text
        // just typed); .utility let loaded hosts starve it for long stretches.
        task = Task.detached(priority: .userInitiated) { [
            weak self,
            engine,
            request,
            mutation,
            requestID,
            shouldYieldBeforeReplacingRequest
        ] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishScheduledRequestIfCurrent(id: requestID)
                }
            }
            if shouldYieldBeforeReplacingRequest {
                await Task.yield()
            }
            guard !Task.isCancelled else {
                return
            }
            let phases = await engine.replaceCurrentRequest(with: request)
            for await result in phases {
                guard !Task.isCancelled else { return }
                await self?.handle(result, mutation: mutation)
            }
        }
    }

    /// Whether a from-scratch highlight of this language and revision is in flight.
    package func hasScheduledFullHighlight(language: SyntaxLanguage, revision: Int) -> Bool {
        guard let scheduledRequest, scheduledRequest.mutation == nil else {
            return false
        }
        return scheduledRequest.language == language && scheduledRequest.revision == revision
    }

    /// Cancels the request in flight and forgets everything rendered so far.
    package func clear() {
        task?.cancel()
        task = nil
        scheduledRequest = nil
        tokenSnapshot = nil
        materialized = nil
        eventObserver?(.requestsReset)
    }

    private func finishScheduledRequestIfCurrent(id: Int) {
        guard let request = scheduledRequest, request.id == id else { return }
        scheduledRequest = nil
        eventObserver?(.requestFinished(revision: request.revision))
    }

    // MARK: - Results

    private func handle(
        _ result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) async {
        guard !Task.isCancelled, let client else { return }
        guard client.highlightTextRevision == result.revision else { return }
        guard canApplyTokenPayload(of: result, mutation: mutation) else {
            eventObserver?(.skipped(result.phase, revision: result.revision))
            client.scheduleFullHighlight(
                source: result.source,
                language: result.language,
                revision: result.revision
            )
            return
        }
        guard !wouldDowngradeCompletedHighlight(result, mutation: mutation, client: client) else {
            eventObserver?(.skipped(result.phase, revision: result.revision))
            return
        }
        guard await client.applyHighlightResult(result) else { return }
        recordApplied(result)
    }

    /// A replacement payload only lists tokens inside its refresh ranges, so
    /// it needs a rendered baseline to apply onto.
    private func canApplyTokenPayload(
        of result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) -> Bool {
        guard result.tokenPayload == .replacement else {
            return true
        }
        // Reset-origin streams paint progressively: the reset itself defines
        // the (initially bare) baseline these replacements apply onto, so no
        // prior materialization is required.
        if mutation == nil {
            return true
        }
        guard let materialized, materialized.language == result.language else {
            return false
        }
        return materialized.revision <= result.revision
    }

    /// A syntactic fast pass after an edit carries no semantic overlays. When
    /// the editor still shows the previous revision's complete highlight,
    /// applying the fast pass would strip those overlays until the complete
    /// result lands.
    private func wouldDowngradeCompletedHighlight(
        _ result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?,
        client: any HighlightRequestCoordinatorClient
    ) -> Bool {
        guard mutation != nil,
              result.phase == .syntacticFastPass,
              let materialized,
              materialized.phase == .complete,
              materialized.language == result.language,
              client.hasRenderedHighlightRuns
        else {
            return false
        }
        return materialized.revision < result.revision
    }

    // MARK: - Rendered state

    /// Records that the editor rendered `result`.
    package func recordApplied(_ result: SyntaxEditorHighlighting.Result) {
        recordMaterialized(phase: result.phase, revision: result.revision, language: result.language)
        guard result.phase == .complete else { return }
        // Only a full snapshot can be replayed later; a replacement payload
        // makes the previous snapshot stale without providing a new one.
        tokenSnapshot = result.tokenPayload == .fullSnapshot
            ? TokenSnapshot(
                tokens: result.tokens,
                source: result.source,
                revision: result.revision,
                language: result.language
            )
            : nil
    }

    /// Records what the editor shows after it re-rendered tokens it already had.
    package func recordMaterialized(
        phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int,
        language: SyntaxLanguage
    ) {
        materialized = MaterializedHighlight(phase: phase, revision: revision, language: language)
        eventObserver?(.applied(phase, revision: revision))
    }

    /// Forgets what the editor rendered, after its syntax runs were cleared.
    package func clearMaterialized() {
        materialized = nil
    }

    /// The complete token list last rendered for exactly this text, if any.
    package func replayableTokens(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) -> [SyntaxEditorHighlighting.Token]? {
        guard let tokenSnapshot,
              tokenSnapshot.revision == revision,
              tokenSnapshot.language == language,
              tokenSnapshot.source == source
        else {
            return nil
        }
        return tokenSnapshot.tokens
    }
}

extension SyntaxEditorTextChange.Replacement {
    /// The range to repaint as soon as this replacement lands in a text of
    /// `textLength` UTF-16 units, before its highlight result arrives: the
    /// inserted text, or the unit at the join when nothing was inserted.
    package func repaintRange(inTextOfLength textLength: Int) -> NSRange {
        let location = min(max(0, self.location), textLength)
        let replacementLength = min(replacement.utf16.count, textLength - location)
        if replacementLength > 0 {
            return NSRange(location: location, length: replacementLength)
        }
        guard textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: min(location, textLength - 1), length: 1)
    }
}

extension SyntaxEditorHighlighting.Result {
    /// The refresh ranges that fall inside a text of `textLength` UTF-16 units.
    ///
    /// `refreshRanges` is already sorted and merged, so clamping keeps it that way.
    package func refreshRanges(clampedToTextLength textLength: Int) -> [NSRange] {
        refreshRanges
            .map { SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: textLength) }
            .filter { $0.length > 0 }
    }
}
