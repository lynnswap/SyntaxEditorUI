import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguages
import SwiftTreeSitter
import SwiftTreeSitterLayer

package actor SyntaxHighlighterEngine: SyntaxEditorHighlighting.Engine {
    private let worker: HighlightRequestWorker
    private var currentRequestTask: Task<Void, Never>?
    private var currentRequestGeneration = 0

    package init() {
        worker = HighlightRequestWorker(registry: .shared)
    }

    // MARK: - SyntaxEditorHighlighting.Engine

    package func reset(source: String, language: SyntaxLanguage, revision: Int) async -> SyntaxEditorHighlighting.Result {
        await worker.reset(source: source, language: language, revision: revision)
    }

    package func resetPhases(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        await worker.resetPhases(source: source, language: language, revision: revision)
    }

    package func update(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int
    ) async -> SyntaxEditorHighlighting.Result {
        await worker.update(source: source, language: language, mutation: mutation, revision: revision)
    }

    package func updatePhases(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        await worker.updatePhases(source: source, language: language, mutation: mutation, revision: revision)
    }

    package func replaceCurrentRequest(with request: SyntaxEditorHighlighting.Request) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        currentRequestGeneration += 1
        let generation = currentRequestGeneration
        currentRequestTask?.cancel()
        currentRequestTask = nil
        await worker.cancelOutstandingWork()
        guard currentRequestGeneration == generation else {
            return Self.finishedStream()
        }
        await worker.setVisibleRange(request.visibleRange)
        guard currentRequestGeneration == generation else {
            return Self.finishedStream()
        }

        let stream = AsyncStream<SyntaxEditorHighlighting.Result>.makeStream()
        let task = Task {
            await runCurrentRequest(
                request,
                generation: generation,
                continuation: stream.continuation
            )
        }
        currentRequestTask = task
        stream.continuation.onTermination = { @Sendable _ in
            task.cancel()
            Task {
                await self.cancelCurrentRequestIfCurrent(generation: generation)
            }
        }
        return stream.stream
    }

    package func cancelCurrentRequest() async {
        currentRequestGeneration += 1
        currentRequestTask?.cancel()
        currentRequestTask = nil
        await worker.cancelOutstandingWork()
    }

    package func setVisibleRange(_ range: NSRange?) async {
        await worker.setVisibleRange(range)
    }

    package func render(source: String, language: SyntaxLanguage) async -> [SyntaxEditorHighlighting.Token] {
        await worker.render(source: source, language: language)
    }

    package func currentTokensForTesting() async -> [SyntaxEditorHighlighting.Token] {
        await worker.currentTokensForTesting()
    }

    // MARK: - Internals

    private func runCurrentRequest(
        _ request: SyntaxEditorHighlighting.Request,
        generation: Int,
        continuation: AsyncStream<SyntaxEditorHighlighting.Result>.Continuation
    ) async {
        let result = await worker.perform(
            request,
            emitFastPass: { result in
                guard !Task.isCancelled else { return }
                continuation.yield(result)
            }
        )
        guard !Task.isCancelled, isCurrentRequest(generation: generation) else {
            continuation.finish()
            return
        }
        continuation.yield(result)
        clearCurrentRequestIfCurrent(generation: generation)
        continuation.finish()
    }

    private func isCurrentRequest(generation: Int) -> Bool {
        currentRequestGeneration == generation
    }

    private func clearCurrentRequestIfCurrent(generation: Int) {
        guard currentRequestGeneration == generation else { return }
        currentRequestTask = nil
    }

    private func cancelCurrentRequestIfCurrent(generation: Int) async {
        guard currentRequestGeneration == generation,
              currentRequestTask != nil
        else {
            return
        }
        currentRequestGeneration += 1
        currentRequestTask?.cancel()
        currentRequestTask = nil
        await worker.cancelOutstandingWork()
    }

    private static func finishedStream() -> AsyncStream<SyntaxEditorHighlighting.Result> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

/// The highlighting worker: one actor-confined session per editor document.
///
/// Ground-up rebuild. The synchronous pipeline per edit is strictly edit-local:
/// tree-sitter incremental reparse, an envelope-clipped capture query, a per-line
/// base-plane patch (unedited lines shift algebraically), then the language's
/// semantic pass. Stage S1 ships every language on the conservative semantic
/// path (full-document merge per update — correct by construction); locality
/// lands per-language in later stages behind the same seam.
private actor HighlightRequestWorker {
    private var session: HighlightSession?
    private let registry: LanguageConfigurationRegistry
    private var visibleRangeHint: NSRange?

    init(registry: LanguageConfigurationRegistry) {
        self.registry = registry
    }

    func reset(source: String, language: SyntaxLanguage, revision: Int) async -> SyntaxEditorHighlighting.Result {
        await reset(source: source, language: language, revision: revision, emitFastPass: nil)
    }

    func resetPhases(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        AsyncStream { continuation in
            let task = Task {
                let result = await self.reset(
                    source: source,
                    language: language,
                    revision: revision,
                    emitFastPass: { continuation.yield($0) }
                )
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(result)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func update(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int
    ) async -> SyntaxEditorHighlighting.Result {
        await update(source: source, language: language, mutation: mutation, revision: revision, emitFastPass: nil)
    }

    func updatePhases(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int
    ) async -> AsyncStream<SyntaxEditorHighlighting.Result> {
        AsyncStream { continuation in
            let task = Task {
                let result = await self.update(
                    source: source,
                    language: language,
                    mutation: mutation,
                    revision: revision,
                    emitFastPass: { continuation.yield($0) }
                )
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(result)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func cancelOutstandingWork() {
        session?.cancelOutstandingWork()
    }

    func setVisibleRange(_ range: NSRange?) {
        visibleRangeHint = range
        session?.visibleRangeHint = range
    }

    func perform(
        _ request: SyntaxEditorHighlighting.Request,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?
    ) async -> SyntaxEditorHighlighting.Result {
        await result(for: request, emitFastPass: emitFastPass)
    }

    private func result(
        for request: SyntaxEditorHighlighting.Request,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?
    ) async -> SyntaxEditorHighlighting.Result {
        switch request.operation {
        case .reset:
            return await reset(
                source: request.source,
                language: request.language,
                revision: request.revision,
                emitFastPass: emitFastPass
            )
        case .update(let mutation):
            return await update(
                source: request.source,
                language: request.language,
                mutation: mutation,
                revision: request.revision,
                emitFastPass: emitFastPass
            )
        }
    }

    private func reset(
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?
    ) async -> SyntaxEditorHighlighting.Result {
        guard !source.isEmpty else {
            guard !Task.isCancelled else {
                return SyntaxEditorHighlighting.Result.empty(source: source, language: language, revision: revision)
            }
            session = nil
            return SyntaxEditorHighlighting.Result.empty(source: source, language: language, revision: revision)
        }

        let setup = await registry.highlightingSetup(for: language)
        guard !Task.isCancelled else {
            return SyntaxEditorHighlighting.Result.empty(source: source, language: language, revision: revision)
        }
        guard let setup else {
            session = nil
            return SyntaxEditorHighlighting.Result.empty(source: source, language: language, revision: revision)
        }

        // Always a fresh session: a half-built one is never installed (a cancelled
        // reset keeps the previous session usable — pinned behavior).
        let nextSession = HighlightSession(language: language, setup: setup)
        nextSession.visibleRangeHint = visibleRangeHint
        let result = await nextSession.reset(source: source, revision: revision, emitFastPass: emitFastPass)
        guard !Task.isCancelled, let result else {
            return SyntaxEditorHighlighting.Result(
                tokens: [],
                source: source,
                language: language,
                revision: revision,
                refreshRanges: [NSRange(location: 0, length: source.utf16.count)]
            )
        }
        session = nextSession
        return result
    }

    private func update(
        source: String,
        language: SyntaxLanguage,
        mutation: SyntaxEditorTextChange.Replacement,
        revision: Int,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?
    ) async -> SyntaxEditorHighlighting.Result {
        if let session,
           let result = await session.update(
               source: source,
               language: language,
               mutation: mutation,
               revision: revision,
               emitFastPass: emitFastPass
           ) {
            return result
        }
        return await reset(source: source, language: language, revision: revision, emitFastPass: emitFastPass)
    }

    func render(source: String, language: SyntaxLanguage) async -> [SyntaxEditorHighlighting.Token] {
        await reset(source: source, language: language, revision: 0).tokens
    }

    func currentTokensForTesting() -> [SyntaxEditorHighlighting.Token] {
        session?.currentTokens() ?? []
    }
}

/// Per-document highlighting state. Confined to the worker actor; all methods
/// are synchronous (no suspension points inside an update).
package final class HighlightSession {
    let setup: HighlightingSetup
    let language: SyntaxLanguage
    var visibleRangeHint: NSRange?

    private var source = ""
    private var layeredSource = ""
    /// UTF-16 image of `layeredSource` for zero-copy parser reads; kept in
    /// sync at every commit point (reset, committed update).
    private let sourceBuffer = UTF16SourceBuffer()
    private var layer: LanguageLayer?
    private let styleTable = HighlightStyleTable()
    private let lineTable = HighlightLineTable()
    private let planes: LineTokenPlanes
    private var semanticPass: SemanticPass?
    /// Committed-but-undelivered refresh obligations (results dropped by
    /// cancellation); unioned into the next emitted result.
    private var refreshDebt = EditedRangeSet()
    /// Pending document ranges whose semantic overlays are stale (conservative
    /// passes converted to chunked work). Spliced through every committed edit;
    /// survives cancellation, so convergence is guaranteed by whichever update
    /// drains last. Stale overlays stay visible until their chunk lands.
    private var semanticDebt = EditedRangeSet()
    /// Single-flight handle for the off-actor monolithic merge (passes without
    /// chunk support). The actor never blocks behind the merge: drains await
    /// the in-flight task (suspended, actor free) and re-validate against
    /// `editGeneration` before committing.
    private var monolithicMergeTask: (
        id: Int,
        task: Task<(tokens: [SyntaxEditorHighlighting.Token], isCancelled: Bool), Never>
    )?
    private var nextMonolithicMergeTaskID = 0
    /// Bumped at every committed edit and reset; a merge started under an older
    /// generation is stale and its result is discarded.
    private var editGeneration = 0
    private static let semanticDrainChunkBudget = 10_000
    /// Documents above this UTF-16 length open progressively (viewport chunk
    /// first); below it the monolithic reset keeps the historical two-phase
    /// delivery. Tests lower the override to run the fixture suite through the
    /// progressive path and assert equivalence.
    private static let defaultProgressiveResetThreshold = 65_536
    private static let syntacticResetChunkBudget = 16_384
    /// Test-only escape hatch (serial test execution); never written in production.
    package nonisolated(unsafe) static var progressiveResetThresholdOverrideForTesting: Int?
    private static var progressiveResetThreshold: Int {
        unsafe progressiveResetThresholdOverrideForTesting ?? defaultProgressiveResetThreshold
    }

    init(language: SyntaxLanguage, setup: HighlightingSetup) {
        self.language = language
        self.setup = setup
        planes = LineTokenPlanes(styles: styleTable)
        semanticPass = SemanticPassFactory.make(language: language)
    }

    func currentTokens() -> [SyntaxEditorHighlighting.Token] {
        planes.tokens(lineTable: lineTable)
    }

    func cancelOutstandingWork() {
        editGeneration += 1
        monolithicMergeTask?.task.cancel()
    }

    // MARK: - Reset

    /// Full highlight of `source`. Returns nil when cancelled before completion
    /// (the engine then refuses to install this session).
    func reset(
        source: String,
        revision: Int,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?,
        isolation: isolated (any Actor)? = #isolation
    ) async -> SyntaxEditorHighlighting.Result? {
        self.source = source
        layeredSource = SyntacticPatcher.layeredSource(for: source, setup: setup)
        sourceBuffer.reset(layeredSource)
        lineTable.reset(source: layeredSource)
        semanticPass?.invalidate()
        refreshDebt.clear()
        semanticDebt.clear()
        editGeneration += 1
        monolithicMergeTask?.task.cancel()
        monolithicMergeTask = nil

        guard !layeredSource.isEmpty else {
            layer = nil
            planes.clear(lineCount: lineTable.lineCount)
            return SyntaxEditorHighlighting.Result.empty(source: source, language: language, revision: revision)
        }

        do {
            let nextLayer = try SyntacticPatcher.makeLayer(setup: setup)
            guard let fullEdit = SyntacticPatcher.fullReplacementInputEdit(for: layeredSource) else {
                layer = nil
                planes.clear(lineCount: lineTable.lineCount)
                return SyntaxEditorHighlighting.Result.empty(source: source, language: language, revision: revision)
            }
            _ = nextLayer.didChangeContent(
                SyntacticPatcher.layerContent(buffer: sourceBuffer, source: layeredSource),
                using: fullEdit,
                resolveSublayers: true
            )
            layer = nextLayer

            let fullRange = NSRange(location: 0, length: layeredSource.utf16.count)
            if fullRange.length > Self.progressiveResetThreshold {
                // Progressive open for large documents: the viewport chunk paints
                // first (parse + one bounded query instead of the whole-document
                // query), then the remaining base chunks land with yields between
                // them. Outcome identical to the monolithic path; only the
                // delivery schedule differs.
                guard await progressiveSyntacticReset(
                    layer: nextLayer,
                    fullRange: fullRange,
                    revision: revision,
                    emitFastPass: emitFastPass
                ) else {
                    layer = nil
                    planes.clear(lineCount: lineTable.lineCount)
                    return nil
                }
            } else {
                let tokens = SyntacticPatcher.highlightTokens(
                    in: fullRange,
                    layer: nextLayer,
                    source: layeredSource,
                    language: language,
                    clipTo: nil
                )
                planes.reset(tokens: tokens, lineTable: lineTable)

                emitDeferredSemanticFastPassIfNeeded(
                    tokens: tokens,
                    source: source,
                    revision: revision,
                    refreshRange: NSRange(location: 0, length: source.utf16.count),
                    tokenPayload: .fullSnapshot,
                    emitFastPass: emitFastPass
                )
            }

            if let semanticPass {
                // Initial semantic pass through the drain (chunked for passes
                // that support it, one yielded monolithic merge otherwise): same
                // outcome as running it inline, but the actor stays responsive.
                // A cancelled reset is never installed, so leftover debt is
                // irrelevant.
                var prepared = !semanticPass.supportsChunkedFullPass
                    || semanticPass.prepareFullPass(
                        source: layeredSource,
                        rootNode: semanticRootNodeSnapshot()
                    )
                if prepared {
                    semanticDebt.insert(fullRange)
                    _ = await drainSemanticDebt(revision: revision, emit: emitFastPass)
                    prepared = semanticDebt.isEmpty
                }
                guard prepared, !Task.isCancelled else {
                    layer = nil
                    self.semanticPass?.invalidate()
                    planes.clear(lineCount: lineTable.lineCount)
                    return nil
                }
            } else if Task.isCancelled {
                layer = nil
                planes.clear(lineCount: lineTable.lineCount)
                return nil
            }
        } catch {
            layer = nil
            planes.clear(lineCount: lineTable.lineCount)
        }

        return SyntaxEditorHighlighting.Result(
            tokens: planes.tokens(lineTable: lineTable),
            source: source,
            language: language,
            revision: revision,
            refreshRanges: [NSRange(location: 0, length: source.utf16.count)]
        )
    }

    /// Chunked base-plane construction for large-document opens. The chunk
    /// nearest the viewport runs first and emits the first paint (a
    /// `.fullSnapshot` fast pass — on a fresh document the not-yet-tokenized
    /// remainder is legitimately uncolored); later chunks emit progressive
    /// replacements with a yield between them. Chunks stay in
    /// `.syntacticFastPass` when a semantic pass still has to merge overlays.
    /// Returns false on cancellation — the caller never installs a half-built
    /// session.
    private func progressiveSyntacticReset(
        layer: LanguageLayer,
        fullRange: NSRange,
        revision: Int,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        planes.clear(lineCount: lineTable.lineCount)
        var syntacticDebt = EditedRangeSet()
        syntacticDebt.insert(fullRange)
        var emittedFirstPaint = false
        let syntacticChunkPhase: SyntaxEditorHighlighting.Result.Phase =
            semanticPass == nil ? .complete : .syntacticFastPass

        while !syntacticDebt.isEmpty {
            if Task.isCancelled {
                return false
            }
            guard let chunk = syntacticDebt.popChunk(
                near: visibleRangeHint?.location,
                budget: Self.syntacticResetChunkBudget
            ) else {
                break
            }
            let target = SyntacticPatcher.lineEnvelope(
                containing: SyntaxEditorRangeUtilities.clampedRange(chunk, utf16Length: fullRange.length),
                source: layeredSource
            )
            guard target.length > 0 else { continue }
            syntacticDebt.remove(target)
            let tokens = SyntacticPatcher.highlightTokens(
                in: target,
                layer: layer,
                source: layeredSource,
                language: language,
                clipTo: target
            )
            _ = planes.replaceTokens(in: target, with: tokens, plane: .base, lineTable: lineTable)
            if !emittedFirstPaint {
                emittedFirstPaint = true
                // .replacement, not .fullSnapshot: the payload contract says a
                // full snapshot carries the revision's COMPLETE token list, and
                // consumers may replace caches wholesale on that promise. The
                // viewport chunk is a partial paint; reset-origin streams may
                // apply replacements onto the fresh baseline (the view gates on
                // the request's origin).
                emitProgressiveResetChunk(
                    tokens: planes.tokens(in: target, lineTable: lineTable),
                    source: source,
                    revision: revision,
                    refreshRange: target,
                    phase: syntacticChunkPhase,
                    emitFastPass: emitFastPass
                )
            } else if let emitFastPass, !syntacticDebt.isEmpty {
                emitProgressiveResetChunk(
                    tokens: planes.tokens(in: target, lineTable: lineTable),
                    source: source,
                    revision: revision,
                    refreshRange: target,
                    phase: syntacticChunkPhase,
                    emitFastPass: emitFastPass
                )
            }
            await Task.yield()
        }
        return !Task.isCancelled
    }

    // MARK: - Update

    /// Incremental update. Returns nil when preconditions fail; the engine then
    /// falls back to a full reset.
    func update(
        source nextSource: String,
        language nextLanguage: SyntaxLanguage,
        mutation originalMutation: SyntaxEditorTextChange.Replacement,
        revision: Int,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?,
        isolation: isolated (any Actor)? = #isolation
    ) async -> SyntaxEditorHighlighting.Result? {
        guard nextLanguage == language, let layer else {
            return nil
        }

        // Mutation validation: cheap probes (length consistency, replacement
        // match, boundary windows); a mismatch coalesces via full diff — the
        // legacy recovery behavior without its per-keystroke O(N) compares.
        let effectiveMutation: SyntaxEditorTextChange.Replacement
        switch SyntacticPatcher.validateMutation(originalMutation, previousSource: source, nextSource: nextSource) {
        case .valid:
            effectiveMutation = originalMutation
        case .mismatch:
            guard let coalesced = SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: nextSource) else {
                return nil
            }
            effectiveMutation = coalesced
        }

        let nextLayeredSource = SyntacticPatcher.layeredSource(for: nextSource, setup: setup)
        let layeredMutation: SyntaxEditorTextChange.Replacement
        if setup.usesHTMLPreprocessing {
            guard let masked = SyntaxEditorTextChange.Replacement.singleReplacement(from: layeredSource, to: nextLayeredSource) else {
                return nil
            }
            layeredMutation = masked
        } else {
            layeredMutation = effectiveMutation
        }

        if setup.supportsLayeredHighlighting,
           SyntacticPatcher.mutationTouchesMarkupBoundary(
               mutation: layeredMutation,
               previousSource: layeredSource,
               nextSource: nextLayeredSource
           ) {
            // Injection-boundary edits re-resolve sublayers via a full reset.
            return nil
        }

        let previousLayeredSource = layeredSource
        guard let inputEdit = SyntacticPatcher.inputEdit(
            mutation: layeredMutation,
            previousSource: previousLayeredSource,
            nextSource: nextLayeredSource,
            lineTable: lineTable
        ) else {
            return nil
        }

        guard !Task.isCancelled else {
            return cancelledResult(revision: revision)
        }

        // ---- Critical section: the invalidation set is a one-shot product of
        // this reparse; no cancellation or nil-return until the base plane,
        // line table, and session sources are committed together. ----
        sourceBuffer.apply(mutation: layeredMutation)
        let invalidated = layer.didChangeContent(
            SyntacticPatcher.layerContent(buffer: sourceBuffer, source: nextLayeredSource),
            using: inputEdit,
            resolveSublayers: setup.supportsLayeredHighlighting
        )
        let nextLength = nextLayeredSource.utf16.count
        let envelope = SyntacticPatcher.patchEnvelope(
            invalidated: invalidated,
            mutation: layeredMutation,
            source: nextLayeredSource,
            sourceUTF16Length: nextLength
        )
        let replacementTokens = SyntacticPatcher.highlightTokens(
            in: envelope,
            layer: layer,
            source: nextLayeredSource,
            language: language,
            clipTo: envelope
        )

        let editResult = planes.applyEdit(
            layeredMutation,
            previousSource: previousLayeredSource,
            lineTable: lineTable
        )
        lineTable.apply(mutation: layeredMutation, previousSource: previousLayeredSource)
        // The replace must cover every line the edit cleared (the edit leaves
        // base chains into those lines dangling for this call to reconcile),
        // so widen the envelope to the replacement lines' whole-line span.
        var baseReplaceRange = envelope
        let replacedSpan = editResult.replacedLines.lowerBound
            ..< (editResult.replacedLines.lowerBound + editResult.replacementLineCount)
        if let replacedWhole = wholeLineRange(ofLines: replacedSpan, sourceUTF16Length: nextLength) {
            baseReplaceRange = SyntacticPatcher.union(baseReplaceRange, replacedWhole)
        }
        let baseChanged = planes.replaceTokens(
            in: baseReplaceRange,
            with: replacementTokens,
            plane: .base,
            lineTable: lineTable
        )
        source = nextSource
        layeredSource = nextLayeredSource
        refreshDebt.splice(
            location: layeredMutation.location,
            oldLength: layeredMutation.length,
            newLength: layeredMutation.replacement.utf16.count,
            documentLength: nextLength
        )
        semanticDebt.splice(
            location: layeredMutation.location,
            oldLength: layeredMutation.length,
            newLength: layeredMutation.replacement.utf16.count,
            documentLength: nextLength
        )
        // Any in-flight off-actor merge is now stale; cancel it so its polls
        // abort the wasted work early.
        editGeneration += 1
        monolithicMergeTask?.task.cancel()
        // ---- End critical section. ----

        // The edited extent itself always refreshes (replacement + one unit so a
        // pure deletion still repaints the join point) — but NOT the whole line:
        // sub-line refresh ranges are pinned by the test suite.
        let editedExtent = SyntaxEditorRangeUtilities.clampedRange(
            NSRange(
                location: layeredMutation.location,
                length: max(1, layeredMutation.replacement.utf16.count + 1)
            ),
            utf16Length: nextLength
        )
        var syntacticRefresh = baseChanged.map { SyntacticPatcher.union($0, editedExtent) }
            ?? editedExtent
        if let dropped = editResult.droppedLines,
           let droppedRange = wholeLineRange(ofLines: dropped, sourceUTF16Length: nextLength) {
            syntacticRefresh = SyntacticPatcher.union(syntacticRefresh, droppedRange)
        }
        if !refreshDebt.isEmpty {
            for range in refreshDebt.ranges.rangeView {
                syntacticRefresh = SyntacticPatcher.union(
                    syntacticRefresh,
                    NSRange(location: range.lowerBound, length: range.count)
                )
            }
            refreshDebt.clear()
        }
        syntacticRefresh = SyntaxEditorRangeUtilities.clampedRange(syntacticRefresh, utf16Length: nextLength)

        emitDeferredSemanticFastPassIfNeeded(
            tokens: planes.tokens(in: syntacticRefresh, lineTable: lineTable),
            source: nextSource,
            revision: revision,
            refreshRange: syntacticRefresh,
            tokenPayload: .replacement,
            emitFastPass: emitFastPass
        )

        var resultRefresh = syntacticRefresh
        var resultRefreshRanges = [syntacticRefresh]
        if let semanticPass {
            let rootNode = semanticRootNodeSnapshot()
            // Overlays go stale exactly where base tokens changed (shifts are
            // algebraic); the raw reparse envelope can span an entire re-lexed
            // multi-line token whose visible tokens didn't change, and feeding
            // it here made every keystroke inside a big comment re-run the
            // comment scanners over the whole token.
            let planEnvelope = SyntacticPatcher.lineEnvelope(
                containing: syntacticRefresh,
                source: nextLayeredSource
            )
            var runConservative = true
            // A monolithic merge writes the pass's state from its detached
            // task on completion; planning against that state mid-flight
            // would race the write. The merge was already cancelled above —
            // skip planning and let the drain settle it.
            if monolithicMergeTask == nil,
               let plan = semanticPass.plannedUpdate(
                mutation: layeredMutation,
                envelope: planEnvelope,
                source: nextLayeredSource,
                rootNode: rootNode
            ) {
                switch plan {
                case .full:
                    runConservative = true
                case .reuse, .targets, .tokenTextTargets:
                    var targets: [NSRange] = [planEnvelope]
                    let appendBoundedTargets: ([NSRange]) -> Void = { bounded in
                        targets.append(contentsOf: bounded.map {
                            SyntacticPatcher.lineEnvelope(
                                containing: SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: nextLength),
                                source: nextLayeredSource
                            )
                        })
                    }
                    switch plan {
                    case .reuse:
                        break
                    case .targets(let bounded):
                        appendBoundedTargets(bounded)
                    case .tokenTextTargets(let names, let bounded):
                        appendBoundedTargets(bounded)
                        targets.append(contentsOf: tokenTextTargetLineRanges(
                            names: names,
                            source: nextLayeredSource,
                            sourceLength: nextLength
                        ))
                    case .full:
                        break
                    }
                    let merged = Self.mergedRanges(targets)
                    let totalLength = merged.reduce(0) { $0 + $1.length }
                    if totalLength * 2 > nextLength {
                        // Fan-out exceeds half the document: the full merge is cheaper
                        // and strictly more complete.
                        runConservative = true
                    } else {
                        runConservative = false
                        var cancelled = false
                        for target in merged {
                            if Task.isCancelled {
                                cancelled = true
                                break
                            }
                            let baseTokens = planes.baseTokens(in: target, lineTable: lineTable)
                            let overlays = semanticPass.overlayTokens(
                                in: target,
                                baseTokens: baseTokens,
                                source: nextLayeredSource
                            )
                            if let diff = planes.replaceTokens(
                                in: target,
                                with: overlays,
                                plane: .overlay,
                                lineTable: lineTable
                            ) {
                                resultRefresh = SyntacticPatcher.union(resultRefresh, diff)
                                resultRefreshRanges.append(diff)
                            }
                        }
                        if cancelled {
                            semanticPass.invalidate()
                            refreshDebt.insert(resultRefresh)
                        }
                    }
                }
            }
            if runConservative {
                // Convert the document-sized pass into drainable debt: stale
                // overlays stay visible until the drain lands, and a cancelled
                // drain leaves the remainder to the next update.
                if !semanticPass.supportsChunkedFullPass
                    || semanticPass.prepareFullPass(source: nextLayeredSource, rootNode: rootNode) {
                    semanticDebt.insert(NSRange(location: 0, length: nextLength))
                } else {
                    // Cancelled mid-build; the base patch below still needs
                    // redelivery because this result is about to be dropped.
                    refreshDebt.insert(resultRefresh)
                }
            }
        }
        if let drained = await drainSemanticDebt(
            revision: revision,
            emit: emitFastPass,
            priorityHint: layeredMutation.location
        ) {
            resultRefresh = SyntacticPatcher.union(resultRefresh, drained)
            resultRefreshRanges.append(drained)
        }
        if Task.isCancelled {
            // The phase stream drops a cancelled task's result: keep the whole
            // repaint duty (base patch included) for the successor.
            refreshDebt.insert(resultRefresh)
        }
        resultRefresh = SyntaxEditorRangeUtilities.clampedRange(resultRefresh, utf16Length: nextSource.utf16.count)
        let normalizedResultRefreshRanges = Self.mergedRanges(resultRefreshRanges.map {
            SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: nextSource.utf16.count)
        })
        let replacementPayloadTokens = normalizedResultRefreshRanges.flatMap {
            planes.tokens(in: $0, lineTable: lineTable)
        }

        return SyntaxEditorHighlighting.Result(
            tokens: resultTokens(
                from: replacementPayloadTokens,
                refreshRanges: normalizedResultRefreshRanges,
                tokenPayload: .replacement
            ),
            source: nextSource,
            language: language,
            revision: revision,
            refreshRanges: normalizedResultRefreshRanges,
            tokenPayload: .replacement
        )
    }

    // MARK: - Semantic drain

    /// Drains pending semantic obligations in ~10k-unit line-aligned chunks,
    /// nearest the viewport first, with a yield between chunks so interleaved
    /// actor work — the next keystroke — never waits behind a document-sized
    /// pass. Cancellation stops between chunks and leaves the remaining debt
    /// (plus the accumulated repaint duty) to the next update; an awaited,
    /// uncancelled call always converges, which is what keeps incremental ==
    /// full equivalence observable at the API.
    ///
    /// `emit` (the phase stream) receives a progressive `.complete` per chunk
    /// while more debt remains, so the viewport recolors without waiting for
    /// the tail. Single-chunk drains stay silent — small documents keep the
    /// historical one-complete-per-update observable behavior.
    private func drainSemanticDebt(
        revision: Int,
        emit: ((SyntaxEditorHighlighting.Result) -> Void)?,
        priorityHint: Int? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async -> NSRange? {
        guard let semanticPass, !semanticDebt.isEmpty else { return nil }
        // Update-initiated drains recolor outward from the edit (the text the
        // user is looking at); opens spread from the viewport.
        let chunkHint = priorityHint ?? visibleRangeHint?.location

        // Passes without chunk support (ObjC's position-keyed classification,
        // the CSS scanners) run their document pass OFF the actor: the drain
        // suspends on the detached merge (actor free for the next keystroke),
        // re-validates the edit generation on resume, and commits or retries.
        // Single flight — interleaved drains await the same in-flight merge,
        // so the pass state has exactly one writer at a time.
        guard semanticPass.supportsChunkedFullPass else {
            while !semanticDebt.isEmpty {
                // Let an already-queued keystroke land before each round: its
                // cancellation bails this drain out before the document-sized
                // input materialization below, so a typing burst funds one
                // merge start instead of one per keystroke.
                await Task.yield()
                if Task.isCancelled {
                    return nil
                }
                if let inFlight = monolithicMergeTask {
                    _ = await inFlight.task.value
                    continue
                }
                let startGeneration = editGeneration
                let mergeTaskID = nextMonolithicMergeTaskID
                nextMonolithicMergeTaskID += 1
                let fullRange = NSRange(location: 0, length: (layeredSource as NSString).length)
                // Passes receive base-plane tokens only and re-derive every
                // overlay: feeding stale overlays back in tripped the ObjC
                // provider's preservation heuristics into keeping shifted
                // leftovers.
                let inputTokens = planes.baseTokens(lineTable: lineTable)
                let mergeSource = layeredSource
                // Safety: single flight gives the pass one writer at a time,
                // and the root node comes from a private tree snapshot copy.
                nonisolated(unsafe) let pass = semanticPass
                nonisolated(unsafe) let rootNode = semanticRootNodeSnapshot()
                let mergeTask = Task.detached(priority: .utility) {
                    unsafe pass.fullMerge(tokens: inputTokens, source: mergeSource, rootNode: rootNode)
                }
                monolithicMergeTask = (id: mergeTaskID, task: mergeTask)
                let merged = await mergeTask.value
                if monolithicMergeTask?.id == mergeTaskID {
                    monolithicMergeTask = nil
                }
                guard startGeneration == editGeneration else {
                    // An edit landed mid-merge (it also cancelled the merge);
                    // the result is stale — go around with the new text. Any
                    // state the merge wrote describes the stale text; drop it
                    // so planning never shifts a stale index.
                    semanticPass.invalidate()
                    continue
                }
                if merged.isCancelled || Task.isCancelled {
                    semanticPass.invalidate()
                    return nil
                }
                semanticDebt.clear()
                return planes.replaceTokens(
                    in: fullRange,
                    with: merged.tokens,
                    plane: .both,
                    lineTable: lineTable
                )
            }
            return nil
        }

        var refresh: NSRange?
        while !semanticDebt.isEmpty {
            await Task.yield()
            if Task.isCancelled {
                if let refresh { refreshDebt.insert(refresh) }
                return refresh
            }
            let sourceLength = (layeredSource as NSString).length
            guard sourceLength > 0,
                  let chunk = semanticDebt.popChunk(
                      near: chunkHint,
                      budget: Self.semanticDrainChunkBudget
                  )
            else {
                semanticDebt.clear()
                break
            }
            let target = SyntacticPatcher.lineEnvelope(
                containing: SyntaxEditorRangeUtilities.clampedRange(chunk, utf16Length: sourceLength),
                source: layeredSource
            )
            guard target.length > 0 else { continue }
            // The line envelope can exceed the popped chunk; drop the overlap so
            // adjacent chunks never reclassify the same lines twice.
            semanticDebt.remove(target)
            let baseTokens = planes.baseTokens(in: target, lineTable: lineTable)
            let overlays = semanticPass.overlayTokens(
                in: target,
                baseTokens: baseTokens,
                source: layeredSource
            )
            if let diff = planes.replaceTokens(
                in: target,
                with: overlays,
                plane: .overlay,
                lineTable: lineTable
            ) {
                refresh = refresh.map { SyntacticPatcher.union($0, diff) } ?? diff
                if let emit, !semanticDebt.isEmpty {
                    emit(SyntaxEditorHighlighting.Result(
                        tokens: resultTokens(
                            from: planes.tokens(in: diff, lineTable: lineTable),
                            refreshRange: diff,
                            tokenPayload: .replacement
                        ),
                        source: source,
                        language: language,
                        revision: revision,
                        refreshRanges: [diff],
                        tokenPayload: .replacement
                    ))
                }
            }
        }
        return refresh
    }

    // MARK: - Helpers


    /// Sorts and merges overlapping/adjacent ranges.
    static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges.filter { $0.length > 0 } }
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= last.upperBound {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(last.upperBound, range.upperBound) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func semanticRootNodeSnapshot() -> Node? {
        guard language == .swift || language == .objectiveC else { return nil }
        return layer?.snapshot()?.rootSnapshot.tree.rootNode
    }

    private func tokenTextTargetLineRanges(
        names: Set<String>,
        source: String,
        sourceLength: Int
    ) -> [NSRange] {
        guard !names.isEmpty, sourceLength > 0 else { return [] }
        let nsSource = source as NSString
        return planes.tokens(lineTable: lineTable).compactMap { token in
            guard !token.isSemanticOverlay,
                  token.syntaxID == .plain,
                  token.language == language || token.language == nil,
                  token.range.location >= 0,
                  token.range.length > 0,
                  token.range.upperBound <= nsSource.length,
                  names.contains(nsSource.nativeSubstring(with: token.range))
            else {
                return nil
            }
            return SyntacticPatcher.lineEnvelope(containing: token.range, source: source)
        }
    }

    private var usesDeferredSemanticHighlighting: Bool {
        language == .swift || language == .objectiveC
    }

    private func emitDeferredSemanticFastPassIfNeeded(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        revision: Int,
        refreshRange: NSRange,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?
    ) {
        guard usesDeferredSemanticHighlighting, let emitFastPass else { return }
        emitFastPass(
            SyntaxEditorHighlighting.Result(
                tokens: resultTokens(from: tokens, refreshRange: refreshRange, tokenPayload: tokenPayload),
                source: source,
                language: language,
                revision: revision,
                refreshRanges: [refreshRange],
                phase: .syntacticFastPass,
                tokenPayload: tokenPayload
            )
        )
    }

    private func emitProgressiveResetChunk(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        revision: Int,
        refreshRange: NSRange,
        phase: SyntaxEditorHighlighting.Result.Phase,
        emitFastPass: ((SyntaxEditorHighlighting.Result) -> Void)?
    ) {
        guard let emitFastPass else { return }
        emitFastPass(
            SyntaxEditorHighlighting.Result(
                tokens: resultTokens(from: tokens, refreshRange: refreshRange, tokenPayload: .replacement),
                source: source,
                language: language,
                revision: revision,
                refreshRanges: [refreshRange],
                phase: phase,
                tokenPayload: .replacement
            )
        )
    }

    private func resultTokens(
        from tokens: [SyntaxEditorHighlighting.Token],
        refreshRange: NSRange,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload
    ) -> [SyntaxEditorHighlighting.Token] {
        resultTokens(from: tokens, refreshRanges: [refreshRange], tokenPayload: tokenPayload)
    }

    private func resultTokens(
        from tokens: [SyntaxEditorHighlighting.Token],
        refreshRanges: [NSRange],
        tokenPayload: SyntaxEditorHighlighting.Result.Payload
    ) -> [SyntaxEditorHighlighting.Token] {
        switch tokenPayload {
        case .fullSnapshot:
            return tokens
        case .replacement:
            let refreshRanges = Self.mergedRanges(refreshRanges)
            let filtered = tokens.filter {
                token in refreshRanges.contains {
                    token.range.location < $0.upperBound && token.range.upperBound > $0.location
                }
            }
            return Self.deduplicatedSortedTokens(filtered)
        }
    }

    private static func deduplicatedSortedTokens(
        _ tokens: [SyntaxEditorHighlighting.Token]
    ) -> [SyntaxEditorHighlighting.Token] {
        var seen = Set<TokenIdentity>()
        var unique: [SyntaxEditorHighlighting.Token] = []
        unique.reserveCapacity(tokens.count)
        for token in tokens where seen.insert(TokenIdentity(token)).inserted {
            unique.append(token)
        }
        return unique.enumerated().sorted {
            if $0.element.range.location != $1.element.range.location {
                return $0.element.range.location < $1.element.range.location
            }
            if $0.element.range.length != $1.element.range.length {
                return $0.element.range.length > $1.element.range.length
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private struct TokenIdentity: Hashable {
        let location: Int
        let length: Int
        let syntaxID: EditorSourceSyntax.ID
        let language: SyntaxLanguage?
        let rawCaptureName: String
        let isSemanticOverlay: Bool

        init(_ token: SyntaxEditorHighlighting.Token) {
            location = token.range.location
            length = token.range.length
            syntaxID = token.syntaxID
            language = token.language
            rawCaptureName = token.rawCaptureName
            isSemanticOverlay = token.isSemanticOverlay
        }
    }

    /// Cancelled results are dropped before the phase streams yield them; carry
    /// no tokens and a no-op refresh range (never materialize the store here).
    private func cancelledResult(revision: Int) -> SyntaxEditorHighlighting.Result {
        SyntaxEditorHighlighting.Result(
            tokens: [],
            source: source,
            language: language,
            revision: revision,
            refreshRanges: [],
            tokenPayload: .replacement
        )
    }

    private func wholeLineRange(ofLines lines: Range<Int>, sourceUTF16Length: Int) -> NSRange? {
        guard !lines.isEmpty else { return nil }
        let lower = lineTable.lineStartOffset(at: max(0, lines.lowerBound))
        let upperLine = min(lines.upperBound, lineTable.lineCount) - 1
        guard upperLine >= 0 else { return nil }
        let upper = min(max(lower, lineTable.lineEndOffset(at: upperLine)), sourceUTF16Length)
        return NSRange(location: min(lower, sourceUTF16Length), length: max(0, upper - min(lower, sourceUTF16Length)))
    }
}
