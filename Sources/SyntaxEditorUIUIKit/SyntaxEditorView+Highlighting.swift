#if canImport(UIKit)
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

private struct SyntaxHighlightAttributeKey: Hashable {
    let syntaxID: EditorSourceSyntax.ID
    let language: SyntaxLanguage
}

private struct SyntaxHighlightStyle {
    let foregroundColor: UIColor
    let font: UIFont
}

struct ScheduledHighlightRequest {
    let id: Int
    let model: SyntaxEditorModel
    let language: SyntaxLanguage
    let revision: Int
    let mutation: SyntaxEditorTextChange.Replacement?
}

struct HighlightPhaseRecord: Equatable {
    let revision: Int
    let phase: SyntaxEditorHighlighting.Result.Phase
}

struct HighlightPhaseWaiter {
    let id: Int
    let revision: Int
    let phase: SyntaxEditorHighlighting.Result.Phase
    let continuation: CheckedContinuation<Bool, Never>
}

private struct SyntaxHighlightAttributeResolver {
    let theme: SyntaxEditorTheme
    let defaultLanguage: SyntaxLanguage
    let appearance: SyntaxEditorTheme.Appearance
    let fontSizeDelta: Int
    let resolveColor: (UIColor) -> UIColor

    private var styleCache: [SyntaxHighlightAttributeKey: SyntaxHighlightStyle] = [:]
    private var missingAttributeKeys: Set<SyntaxHighlightAttributeKey> = []
    private var fontCache: [SyntaxEditorTheme.FontDescriptor: UIFont] = [:]

    init(
        theme: SyntaxEditorTheme,
        defaultLanguage: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance,
        fontSizeDelta: Int,
        resolveColor: @escaping (UIColor) -> UIColor
    ) {
        self.theme = theme
        self.defaultLanguage = defaultLanguage
        self.appearance = appearance
        self.fontSizeDelta = fontSizeDelta
        self.resolveColor = resolveColor
    }

    mutating func style(
        for syntaxID: EditorSourceSyntax.ID,
        language: SyntaxLanguage?
    ) -> (key: SyntaxHighlightAttributeKey, style: SyntaxHighlightStyle)? {
        let effectiveLanguage = language ?? defaultLanguage
        let key = SyntaxHighlightAttributeKey(syntaxID: syntaxID, language: effectiveLanguage)

        if let cached = styleCache[key] {
            return (key, cached)
        }
        guard !missingAttributeKeys.contains(key) else {
            return nil
        }

        guard let style = SyntaxEditorHighlightTheme.style(
            for: syntaxID,
            in: theme,
            language: effectiveLanguage,
            appearance: appearance
        ) else {
            missingAttributeKeys.insert(key)
            return nil
        }

        let resolvedStyle = SyntaxHighlightStyle(
            foregroundColor: resolveColor(style.foreground),
            font: platformFont(for: style.font)
        )
        styleCache[key] = resolvedStyle
        return (key, resolvedStyle)
    }

    private mutating func platformFont(for descriptor: SyntaxEditorTheme.FontDescriptor) -> UIFont {
        if let cached = fontCache[descriptor] {
            return cached
        }
        let font = descriptor.platformFont(fontSizeDelta: fontSizeDelta)
        fontCache[descriptor] = font
        return font
    }
}

@MainActor
extension SyntaxEditorView {
    @discardableResult
    internal func waitForPendingHighlightForTesting() async -> Bool {
        // Deterministic: a result that cannot apply yet (payload gating,
        // revision races) reschedules and lets its task complete unapplied, so
        // follow reschedules by generation until a waited task finishes
        // without scheduling a successor. No wall-clock is involved — a
        // pipeline that never settles is a real bug and surfaces as the
        // suite's time limit, never as a racy early false.
        while true {
            guard let task = highlightTask else { return true }
            let generation = nextScheduledHighlightRequestID
            await task.value
            if nextScheduledHighlightRequestID == generation {
                return true
            }
        }
    }

    internal func waitForAppliedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase
    ) async -> Bool {
        let expectedRevision = model.textRevision
        guard !hasAppliedHighlightPhaseForTesting(phase, revision: expectedRevision) else {
            return true
        }

        let waiterID = nextHighlightPhaseWaiterID
        nextHighlightPhaseWaiterID += 1
        return await withCheckedContinuation { continuation in
            appliedHighlightPhaseWaitersForTesting.append(
                HighlightPhaseWaiter(
                    id: waiterID,
                    revision: expectedRevision,
                    phase: phase,
                    continuation: continuation
                )
            )
        }
    }

    internal func waitForSkippedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase
    ) async -> Bool {
        let expectedRevision = model.textRevision
        guard !hasSkippedHighlightPhaseForTesting(phase, revision: expectedRevision) else {
            return true
        }

        let waiterID = nextHighlightPhaseWaiterID
        nextHighlightPhaseWaiterID += 1
        return await withCheckedContinuation { continuation in
            skippedHighlightPhaseWaitersForTesting.append(
                HighlightPhaseWaiter(
                    id: waiterID,
                    revision: expectedRevision,
                    phase: phase,
                    continuation: continuation
                )
            )
        }
    }

    internal func setApplyingHighlightForTesting(_ isApplying: Bool) {
        isApplyingHighlight = isApplying
    }

    func configureSyntaxRenderingAttributesValidator() {
        layoutManager.renderingAttributesValidator = { [weak self] textLayoutManager, textLayoutFragment in
            MainActor.assumeIsolated {
                self?.validateSyntaxRenderingAttributes(
                    in: textLayoutFragment,
                    using: textLayoutManager
                )
            }
        }
    }

    func validateSyntaxRenderingAttributes(
        in textLayoutFragment: NSTextLayoutFragment,
        using textLayoutManager: NSTextLayoutManager
    ) {
        let fragmentRange = textRange(for: textLayoutFragment)
        guard fragmentRange.length > 0 else { return }

        guard let targetTextRange = textRange(forUTF16Range: fragmentRange) else { return }
        if let baseForeground = typingAttributes[.foregroundColor] as? UIColor {
            textLayoutManager.addRenderingAttribute(
                .foregroundColor,
                value: baseForeground,
                for: targetTextRange
            )
        }

        let resolvedRuns = highlightStyleStore.resolveVisibleRuns(in: fragmentRange)
        for colorRun in resolvedRuns.colorRuns {
            guard let textRange = textRange(forUTF16Range: colorRun.range) else { continue }
            textLayoutManager.addRenderingAttribute(
                .foregroundColor,
                value: colorRun.color,
                for: textRange
            )
        }

        for fontRun in resolvedRuns.fontRuns {
            guard let textRange = textRange(forUTF16Range: fontRun.range) else { continue }
            textLayoutManager.addRenderingAttribute(
                .font,
                value: fontRun.font,
                for: textRange
            )
        }
    }
    public override func tintColorDidChange() {
        super.tintColorDidChange()
        applyMarkedTextAttributes()
    }
    func configureTraitChangeObservation() {
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) {
            (self: Self, previousTraitCollection: UITraitCollection) in
            guard previousTraitCollection.hasDifferentColorAppearance(comparedTo: self.traitCollection) else {
                return
            }
            self.refreshForColorAppearanceChange()
        }
    }

    func refreshForColorAppearanceChange() {
        let previousAppearance = lastAppliedThemeAppearance ?? currentThemeAppearance
        let nextAppearance = currentThemeAppearance
        let theme = lastAppliedTheme
        let baseFontChanged = !resolvedBaseFont(
            for: theme.resolved(for: model.language, appearance: previousAppearance),
            fontSizeDelta: lastAppliedFontSizeDelta
        ).isEqual(resolvedBaseFont(
            for: theme.resolved(for: model.language, appearance: nextAppearance),
            fontSizeDelta: lastAppliedFontSizeDelta
        ))
        lastAppliedThemeAppearance = nextAppearance

        updateEditorBackgroundColor()
        invalidateHorizontalMeasurement()
        applyBaseForegroundColorChange(from: theme, to: theme)
        updateTypingAttributes()
        if baseFontChanged {
            applyResolvedFontsToExistingText()
        }
        reapplyCachedHighlight()
        updateFindHighlightFragmentViews()
        updateBracketHighlightFragmentViews()
        updateTextContainerForCurrentWrappingMode()
        invalidateTextLayout()
    }
    func updateTypingAttributes() {
        if let baseForeground = baseAttributes()[.foregroundColor] as? UIColor {
            highlightStyleStore.updateBaseForeground(baseForeground, textLength: storage.length)
        }
        typingAttributes = storageBaseAttributes()
    }
    func applyResolvedFontsToExistingText(
        source: String? = nil,
        language: SyntaxLanguage? = nil,
        revision: Int? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0,
              let baseFont = baseAttributes()[.font] as? UIFont
        else { return }

        let source = source ?? text
        let language = language ?? model.language
        let revision = revision ?? model.textRevision

        TextEditingTransaction.perform(on: textContentStorage) { storage in
            storage.addAttribute(.font, value: baseFont, range: fullRange)
        }
        var didRecomputeSyntaxFontRuns = false
        if hasReusableRecordedHighlightSnapshot(
            source: source,
            language: language,
            revision: revision
        ),
           let baseForeground = baseAttributes()[.foregroundColor] as? UIColor {
            var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: baseAttributes())
            let runSet = syntaxHighlightRunSet(
                for: lastHighlightTokens,
                renderRange: fullRange,
                textLength: storage.length,
                resolver: &resolver
            )
            highlightStyleStore.commitSnapshot(
                runSet: runSet,
                range: fullRange,
                revision: revision,
                language: language,
                textLength: storage.length,
                baseForeground: baseForeground,
                baseFont: baseFont,
                suppressionRanges: foregroundSuppressionRanges(textLength: storage.length)
            )
            invalidateSyntaxRenderingAttributes(for: [fullRange])
            didRecomputeSyntaxFontRuns = true
        }
        if !didRecomputeSyntaxFontRuns {
            let invalidatedFontRuns = highlightStyleStore.updateBaseFont(
                baseFont,
                textLength: storage.length,
                clearsFontRuns: true
            )
            invalidateSyntaxRenderingAttributes(for: invalidatedFontRuns)
        }
        invalidateTextLayout()
    }

    func applyBaseForegroundColorChange(
        from _: SyntaxEditorTheme,
        to theme: SyntaxEditorTheme,
        language: SyntaxLanguage? = nil
    ) {
        let language = language ?? model.language
        let nextBaseForeground = resolvedSyntaxColor(
            theme
                .resolved(for: language, appearance: currentThemeAppearance)
                .baseForeground
        )
        highlightStyleStore.updateBaseForeground(nextBaseForeground, textLength: storage.length)
        let fullRange = NSRange(location: 0, length: storage.length)
        if fullRange.length > 0 {
            TextEditingTransaction.perform(on: textContentStorage) { storage in
                storage.addAttribute(.foregroundColor, value: nextBaseForeground, range: fullRange)
            }
            invalidateSyntaxRenderingAttributes(for: [fullRange])
        }
        setNeedsDisplayForVisibleTextFragments()
    }
    private func resetAppliedHighlightPhaseTrackingForTesting() {
        appliedHighlightPhaseRecordsForTesting.removeAll()
        skippedHighlightPhaseRecordsForTesting.removeAll()
        resumeAppliedHighlightPhaseWaitersForTesting(result: false)
        resumeSkippedHighlightPhaseWaitersForTesting(result: false)
    }

    private func hasAppliedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) -> Bool {
        appliedHighlightPhaseRecordsForTesting.contains {
            $0.revision == revision && $0.phase == phase
        }
    }

    private func recordAppliedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) {
        appliedHighlightPhaseRecordsForTesting.append(
            HighlightPhaseRecord(revision: revision, phase: phase)
        )
        if appliedHighlightPhaseRecordsForTesting.count > 16 {
            appliedHighlightPhaseRecordsForTesting.removeFirst(
                appliedHighlightPhaseRecordsForTesting.count - 16
            )
        }

        resumeAppliedHighlightPhaseWaitersForTesting(
            revision: revision,
            phase: phase,
            result: true
        )
    }

    private func hasSkippedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) -> Bool {
        skippedHighlightPhaseRecordsForTesting.contains {
            $0.revision == revision && $0.phase == phase
        }
    }

    private func recordSkippedHighlightPhaseForTesting(
        _ phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int
    ) {
        skippedHighlightPhaseRecordsForTesting.append(
            HighlightPhaseRecord(revision: revision, phase: phase)
        )
        if skippedHighlightPhaseRecordsForTesting.count > 16 {
            skippedHighlightPhaseRecordsForTesting.removeFirst(
                skippedHighlightPhaseRecordsForTesting.count - 16
            )
        }

        resumeSkippedHighlightPhaseWaitersForTesting(
            revision: revision,
            phase: phase,
            result: true
        )
    }

    private func resumeAppliedHighlightPhaseWaiterForTesting(id: Int, result: Bool) {
        guard let waiterIndex = appliedHighlightPhaseWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = appliedHighlightPhaseWaitersForTesting.remove(at: waiterIndex)
        waiter.continuation.resume(returning: result)
    }

    private func resumeAppliedHighlightPhaseWaitersForTesting(
        revision: Int? = nil,
        phase: SyntaxEditorHighlighting.Result.Phase? = nil,
        result: Bool
    ) {
        var matchedWaiters: [HighlightPhaseWaiter] = []
        appliedHighlightPhaseWaitersForTesting.removeAll { waiter in
            guard revision == nil || waiter.revision == revision,
                  phase == nil || waiter.phase == phase
            else {
                return false
            }
            matchedWaiters.append(waiter)
            return true
        }

        for waiter in matchedWaiters {
            waiter.continuation.resume(returning: result)
        }
    }

    private func resumeSkippedHighlightPhaseWaiterForTesting(id: Int, result: Bool) {
        guard let waiterIndex = skippedHighlightPhaseWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = skippedHighlightPhaseWaitersForTesting.remove(at: waiterIndex)
        waiter.continuation.resume(returning: result)
    }

    private func resumeSkippedHighlightPhaseWaitersForTesting(
        revision: Int? = nil,
        phase: SyntaxEditorHighlighting.Result.Phase? = nil,
        result: Bool
    ) {
        var matchedWaiters: [HighlightPhaseWaiter] = []
        skippedHighlightPhaseWaitersForTesting.removeAll { waiter in
            guard revision == nil || waiter.revision == revision,
                  phase == nil || waiter.phase == phase
            else {
                return false
            }
            matchedWaiters.append(waiter)
            return true
        }

        for waiter in matchedWaiters {
            waiter.continuation.resume(returning: result)
        }
    }

    func scheduleHighlight(
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        mutation: SyntaxEditorTextChange.Replacement? = nil,
        refreshStartUTF16: Int = 0
    ) {
        highlightTask?.cancel()
        let requestID = nextScheduledHighlightRequestID
        nextScheduledHighlightRequestID += 1
        scheduledHighlightRequest = ScheduledHighlightRequest(
            id: requestID,
            model: model,
            language: language,
            revision: revision,
            mutation: mutation
        )
        resetAppliedHighlightPhaseTrackingForTesting()
        prepareSyntaxHighlightRenderingForPendingHighlight(
            mutation: mutation,
            source: source,
            refreshStartUTF16: refreshStartUTF16
        )

        let highlighter = self.highlighter
        // Viewport hint: progressive opens and background semantic drains
        // process the chunk nearest this range first (pure ordering hint).
        let visibleRange = visibleCharacterRangeForHighlightHint()
        let operation: SyntaxEditorHighlighting.Request.Operation = if let mutation {
            .update(mutation)
        } else {
            .reset
        }
        let request = SyntaxEditorHighlighting.Request(
            source: source,
            language: language,
            revision: revision,
            operation: operation,
            visibleRange: visibleRange
        )
        let shouldYieldBeforeReplacingRequest = !source.isEmpty
        highlightTask = Task.detached(priority: .utility) { [
            weak self,
            highlighter,
            request,
            mutation,
            requestID,
            shouldYieldBeforeReplacingRequest
        ] in
            defer {
                Task { @MainActor [weak self] in
                    self?.clearScheduledHighlightRequestIfCurrent(id: requestID)
                }
            }
            if shouldYieldBeforeReplacingRequest {
                await Task.yield()
            }
            guard !Task.isCancelled else {
                return
            }
            let phases = await highlighter.replaceCurrentRequest(with: request)
            for await result in phases {
                guard !Task.isCancelled else { return }
                await self?.applyHighlightResultFromScheduledTask(result, mutation: mutation)
            }
        }
    }

    private func clearScheduledHighlightRequestIfCurrent(id: Int) {
        guard scheduledHighlightRequest?.id == id else { return }
        scheduledHighlightRequest = nil
    }

    private func applyHighlightResultFromScheduledTask(
        _ result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) async {
        guard !Task.isCancelled else { return }
        guard model.textRevision == result.revision else { return }
        guard canApplyHighlightTokenPayload(for: result, mutation: mutation) else {
            recordSkippedHighlightPhaseForTesting(result.phase, revision: result.revision)
            scheduleHighlight(source: result.source, language: result.language, revision: result.revision)
            return
        }
        guard shouldMaterializeHighlightResult(result, mutation: mutation) else {
            recordSkippedHighlightPhaseForTesting(result.phase, revision: result.revision)
            return
        }
        let refreshRanges = highlightApplicationRefreshRanges(
            for: result,
            mutation: mutation
        )
        let didApplyHighlight = await applyHighlightFromScheduledTask(
            result.tokens,
            expectedRevision: result.revision,
            source: result.source,
            language: result.language,
            refreshRanges: refreshRanges,
            mutation: mutation,
            tokenPayload: result.tokenPayload
        )
        guard didApplyHighlight else { return }
        recordMaterializedHighlight(
            phase: result.phase,
            revision: result.revision,
            language: result.language
        )
        guard result.phase == .complete else { return }
        recordAppliedHighlightTokenSnapshot(
            tokens: result.tokens,
            source: result.source,
            revision: result.revision,
            language: result.language,
            tokenPayload: result.tokenPayload
        )
    }

    private func shouldMaterializeHighlightResult(
        _ result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) -> Bool {
        guard mutation != nil,
              result.phase == .syntacticFastPass
        else {
            return true
        }

        return !hasMaterializedCompletedHighlightToAvoidDowngrade(for: result)
    }

    private func hasMaterializedCompletedHighlightToAvoidDowngrade(for result: SyntaxEditorHighlighting.Result) -> Bool {
        guard materializedHighlightPhase == .complete,
              materializedHighlightLanguage == result.language,
              highlightStyleStore.hasMaterializedRuns,
              let materializedHighlightRevision
        else {
            return false
        }

        return materializedHighlightRevision < result.revision
    }

    func highlightApplicationRefreshRanges(
        for result: SyntaxEditorHighlighting.Result,
        mutation: SyntaxEditorTextChange.Replacement?
    ) -> [NSRange] {
        _ = mutation
        return result.refreshRanges
    }

    private static func highlightTargetRanges(_ ranges: [NSRange], textLength: Int) -> [NSRange] {
        let validRanges = ranges.filter { $0.location != NSNotFound }
        let clampedRanges = validRanges.map {
            SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: textLength)
        }
        let nonEmptyRanges = clampedRanges.filter { $0.length > 0 }
        let clamped = nonEmptyRanges.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
        guard var current = clamped.first else { return [] }
        var merged: [NSRange] = []
        for range in clamped.dropFirst() {
            if range.location <= current.upperBound {
                current = NSRange(
                    location: current.location,
                    length: max(current.upperBound, range.upperBound) - current.location
                )
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private func canApplyHighlightTokenPayload(
        for result: SyntaxEditorHighlighting.Result,
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
        guard materializedHighlightLanguage == result.language,
              let materializedHighlightRevision
        else {
            return false
        }
        return materializedHighlightRevision <= result.revision
    }

    func reapplyCachedHighlight(
        source: String? = nil,
        language: SyntaxLanguage? = nil,
        revision: Int? = nil
    ) {
        let source = source ?? text
        let language = language ?? model.language
        let revision = revision ?? model.textRevision

        if hasScheduledFullResetHighlight(language: language, revision: revision) {
            return
        }
        guard hasReusableRecordedHighlightSnapshot(
            source: source,
            language: language,
            revision: revision
        ) else {
            scheduleHighlight(source: source, language: language, revision: revision)
            return
        }

        applyHighlight(
            lastHighlightTokens,
            expectedRevision: revision,
            source: source,
            refreshRange: NSRange(location: 0, length: source.utf16.count)
        )
    }

    private func hasReusableRecordedHighlightSnapshot(
        source: String,
        language: SyntaxLanguage,
        revision: Int
    ) -> Bool {
        lastHighlightRevision == revision
            && lastHighlightLanguage == language
            && lastHighlightSource == source
    }

    private func hasScheduledFullResetHighlight(
        language: SyntaxLanguage,
        revision: Int
    ) -> Bool {
        guard let scheduledHighlightRequest,
              scheduledHighlightRequest.mutation == nil
        else {
            return false
        }
        return scheduledHighlightRequest.model === model
            && scheduledHighlightRequest.language == language
            && scheduledHighlightRequest.revision == revision
    }

    func clearHighlightCache() {
        highlightTask?.cancel()
        highlightTask = nil
        scheduledHighlightRequest = nil
        resetAppliedHighlightPhaseTrackingForTesting()
        lastHighlightTokens = []
        lastHighlightSource = nil
        lastHighlightRevision = nil
        lastHighlightLanguage = nil
        clearMaterializedHighlightState()
        resetSyntaxHighlightRenderingState(textLength: storage.length)
    }

    private func recordMaterializedHighlight(
        phase: SyntaxEditorHighlighting.Result.Phase,
        revision: Int,
        language: SyntaxLanguage
    ) {
        materializedHighlightPhase = phase
        materializedHighlightRevision = revision
        materializedHighlightLanguage = language
        recordAppliedHighlightPhaseForTesting(phase, revision: revision)
    }

    private func clearMaterializedHighlightState() {
        materializedHighlightPhase = nil
        materializedHighlightRevision = nil
        materializedHighlightLanguage = nil
    }

    static func highlightMutation(_ change: SyntaxEditorTextChange) -> SyntaxEditorTextChange.Replacement? {
        guard change.replacements.count == 1, let edit = change.replacements.first else { return nil }
        return SyntaxEditorTextChange.Replacement(
            location: edit.range.location,
            length: edit.range.length,
            replacement: edit.replacement
        )
    }

    func applyHighlight(
        _ tokens: [SyntaxEditorHighlighting.Token],
        expectedRevision: Int,
        source expectedSource: String,
        refreshRange: NSRange
    ) {
        guard model.textRevision == expectedRevision else { return }

        let textLength = expectedSource.utf16.count
        let targetRange = SyntaxEditorRangeUtilities.clampedRange(refreshRange, utf16Length: textLength)
        guard targetRange.length > 0 else {
            applyMatchingBracketHighlight(force: true)
            return
        }
        let base = baseAttributes()

        isApplyingHighlight = true
        defer { isApplyingHighlight = false }

        commitSyntaxHighlightSnapshot(
            for: tokens,
            targetRange: targetRange,
            baseAttributes: base,
            textLength: textLength,
            revision: expectedRevision,
            language: model.language
        )
        applyMarkedTextAttributes()
        updateTypingAttributes()
        applyMatchingBracketHighlight(force: true)
        setNeedsDisplayForVisibleTextFragments()
        recordMaterializedHighlight(
            phase: .complete,
            revision: expectedRevision,
            language: model.language
        )
    }

    private func applyHighlightFromScheduledTask(
        _ tokens: [SyntaxEditorHighlighting.Token],
        expectedRevision: Int,
        source expectedSource: String,
        language expectedLanguage: SyntaxLanguage,
        refreshRanges: [NSRange],
        mutation: SyntaxEditorTextChange.Replacement?,
        tokenPayload _: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) async -> Bool {
        guard model.textRevision == expectedRevision else { return false }
        guard model.language == expectedLanguage,
              text == expectedSource
        else {
            return false
        }

        let textLength = expectedSource.utf16.count
        let targetRanges = Self.highlightTargetRanges(
            refreshRanges,
            textLength: textLength
        )
        guard !targetRanges.isEmpty else {
            applyMatchingBracketHighlight(force: true)
            return true
        }
        let base = baseAttributes()

        for targetRange in targetRanges {
            guard await commitSyntaxHighlightSnapshotFromScheduledTask(
                for: tokens,
                targetRange: targetRange,
                baseAttributes: base,
                textLength: textLength,
                revision: expectedRevision,
                language: expectedLanguage
            ) else {
                return false
            }
        }

        applyMarkedTextAttributes()
        updateTypingAttributes()
        applyMatchingBracketHighlight(force: true)
        setNeedsDisplayForVisibleTextFragments()
        return true
    }

    private func recordAppliedHighlightTokenSnapshot(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        revision: Int,
        language: SyntaxLanguage,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload
    ) {
        guard tokenPayload == .fullSnapshot else {
            clearRecordedHighlightTokenSnapshot()
            return
        }
        lastHighlightTokens = tokens
        lastHighlightSource = source
        lastHighlightRevision = revision
        lastHighlightLanguage = language
    }

    private func clearRecordedHighlightTokenSnapshot() {
        lastHighlightTokens = []
        lastHighlightSource = nil
        lastHighlightRevision = nil
        lastHighlightLanguage = nil
    }

    private func makeSyntaxHighlightAttributeResolver(
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> SyntaxHighlightAttributeResolver {
        SyntaxHighlightAttributeResolver(
            theme: lastAppliedTheme,
            defaultLanguage: model.language,
            appearance: currentThemeAppearance,
            fontSizeDelta: model.fontSizeDelta,
            resolveColor: { [weak self] color in
                self?.resolvedSyntaxColor(color) ?? color
            }
        )
    }

    private func syntaxHighlightRunSet(
        for tokens: [SyntaxEditorHighlighting.Token],
        renderRange: NSRange,
        textLength: Int,
        resolver: inout SyntaxHighlightAttributeResolver
    ) -> HighlightRunSet {
        HighlightRunAssembler.assembleRunSet(
            for: tokens,
            targetRange: renderRange,
            textLength: textLength
        ) { token in
            guard let resolved = resolver.style(for: token.syntaxID, language: token.language) else {
                return nil
            }
            return HighlightRunStyle(
                foregroundColor: resolved.style.foregroundColor,
                font: resolved.style.font
            )
        }
    }

    private func commitSyntaxHighlightSnapshot(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        baseAttributes: [NSAttributedString.Key: Any],
        textLength: Int,
        revision: Int,
        language: SyntaxLanguage
    ) {
        guard let baseForeground = baseAttributes[.foregroundColor] as? UIColor else { return }
        var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: baseAttributes)
        let runSet = syntaxHighlightRunSet(
            for: tokens,
            renderRange: targetRange,
            textLength: textLength,
            resolver: &resolver
        )
        let invalidatedDirtyRanges = highlightStyleStore.commitSnapshot(
            runSet: runSet,
            range: targetRange,
            revision: revision,
            language: language,
            textLength: textLength,
            baseForeground: baseForeground,
            baseFont: baseAttributes[.font] as? UIFont,
            suppressionRanges: foregroundSuppressionRanges(textLength: textLength)
        )
        let invalidatedRanges = [targetRange] + invalidatedDirtyRanges
        invalidateSyntaxRenderingAttributes(for: invalidatedRanges)
        setNeedsDisplayForTextRanges(invalidatedRanges)
    }

    private func foregroundSuppressionRanges(textLength: Int) -> [NSRange] {
        markedRange.map { [SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: textLength)] } ?? []
    }

    private func prepareSyntaxHighlightRenderingForPendingHighlight(
        mutation: SyntaxEditorTextChange.Replacement?,
        source: String,
        refreshStartUTF16 _: Int
    ) {
        let textLength = source.utf16.count
        guard let mutation else {
            clearSyntaxHighlightRendering()
            return
        }

        let invalidatedRange = pendingTextReplacementRange(in: source, mutation: mutation)
        highlightStyleStore.recordPendingEdit(mutation, currentTextLength: textLength)
        invalidateSyntaxRenderingAttributes(for: [invalidatedRange])
        guard invalidatedRange.length > 0 else { return }
        setNeedsDisplayForTextRanges([invalidatedRange])
    }

    private func clearSyntaxHighlightRendering() {
        let base = baseAttributes()
        guard let baseForeground = base[.foregroundColor] as? UIColor else { return }
        highlightStyleStore.clear(
            textLength: storage.length,
            baseForeground: baseForeground,
            baseFont: base[.font] as? UIFont
        )
        invalidateSyntaxRenderingAttributes(for: [NSRange(location: 0, length: storage.length)])
        clearMaterializedHighlightState()
        setNeedsDisplayForVisibleTextFragments()
    }

    func resetSyntaxHighlightRenderingState(textLength: Int) {
        highlightStyleStore.reset(textLength: textLength)
        clearMaterializedHighlightState()
    }

    private func pendingTextReplacementRange(
        in source: String,
        mutation: SyntaxEditorTextChange.Replacement
    ) -> NSRange {
        let textLength = source.utf16.count
        let location = min(max(0, mutation.location), textLength)
        let replacementLength = min(max(0, mutation.replacement.utf16.count), textLength - location)
        if replacementLength > 0 {
            return NSRange(location: location, length: replacementLength)
        }
        guard textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let fallbackLocation = min(location, textLength - 1)
        return NSRange(location: fallbackLocation, length: 1)
    }

    private func commitSyntaxHighlightSnapshotFromScheduledTask(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        baseAttributes: [NSAttributedString.Key: Any],
        textLength: Int,
        revision: Int,
        language: SyntaxLanguage
    ) async -> Bool {
        guard !Task.isCancelled, model.textRevision == revision else {
            return false
        }
        isApplyingHighlight = true
        defer { isApplyingHighlight = false }
        commitSyntaxHighlightSnapshot(
            for: tokens,
            targetRange: targetRange,
            baseAttributes: baseAttributes,
            textLength: textLength,
            revision: revision,
            language: language
        )
        await Task.yield()
        return !Task.isCancelled && model.textRevision == revision
    }

    func reapplyTextAttributes(in range: NSRange) {
        let textLength = text.utf16.count
        let targetRange = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
        guard targetRange.length > 0 else { return }

        if hasReusableRecordedHighlightSnapshot(
            source: text,
            language: model.language,
            revision: model.textRevision
        ) {
            applyHighlight(
                lastHighlightTokens,
                expectedRevision: model.textRevision,
                source: text,
                refreshRange: targetRange
            )
        } else {
            TextEditingTransaction.perform(on: textContentStorage) { storage in
                storage.addAttributes(storageBaseAttributes(), range: targetRange)
            }
            setNeedsDisplayForVisibleTextFragments()
        }
    }

    func applyMarkedTextAttributes() {
        let textLength = text.utf16.count
        let suppressionRanges = foregroundSuppressionRanges(textLength: textLength)
        highlightStyleStore.updateSuppressionRanges(
            suppressionRanges,
            textLength: textLength
        )
        invalidateSyntaxRenderingAttributes(for: suppressionRanges)
        guard let markedRange else { return }
        let targetRange = SyntaxEditorRangeUtilities.clampedRange(markedRange, utf16Length: textLength)
        guard targetRange.length > 0 else { return }

        TextEditingTransaction.perform(on: textContentStorage) { storage in
            storage.addAttributes(markedTextAttributes(), range: targetRange)
        }
        setNeedsDisplayForVisibleTextFragments()
    }

    func clearMarkedTextAttributes(in range: NSRange) {
        let textLength = text.utf16.count
        let targetRange = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
        guard targetRange.length > 0 else { return }

        TextEditingTransaction.perform(on: textContentStorage) { storage in
            storage.removeAttribute(.underlineStyle, range: targetRange)
            storage.removeAttribute(.underlineColor, range: targetRange)
        }
        highlightStyleStore.updateSuppressionRanges(
            foregroundSuppressionRanges(textLength: textLength),
            textLength: textLength
        )
        invalidateSyntaxRenderingAttributes(for: [targetRange])
        reapplyTextAttributes(in: targetRange)
        setNeedsDisplayForVisibleTextFragments()
    }

    func markedTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: tintColor ?? UIColor.systemBlue,
        ]
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let theme = resolvedTheme()
        return [
            .font: resolvedBaseFont(for: theme),
            .foregroundColor: resolvedSyntaxColor(theme.baseForeground),
            .paragraphStyle: baseParagraphStyle(),
        ]
    }

    func storageBaseAttributes() -> [NSAttributedString.Key: Any] {
        baseAttributes()
    }

    func resolvedBaseFont(for theme: SyntaxEditorTheme.Resolved? = nil) -> UIFont {
        resolvedBaseFont(for: theme, fontSizeDelta: model.fontSizeDelta)
    }

    func resolvedBaseFont(
        for theme: SyntaxEditorTheme.Resolved? = nil,
        fontSizeDelta: Int
    ) -> UIFont {
        let theme = theme ?? resolvedTheme()
        return theme.base.font.platformFont(fontSizeDelta: fontSizeDelta)
    }

    func baseParagraphStyle() -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = lastAppliedLineWrappingEnabled ? .byCharWrapping : .byClipping
        return paragraphStyle
    }

    func applyParagraphStyleToExistingText() {
        let textRange = NSRange(location: 0, length: storage.length)
        guard textRange.length > 0 else { return }

        let targetLineBreakMode: NSLineBreakMode = lastAppliedLineWrappingEnabled ? .byCharWrapping : .byClipping
        var updates: [(range: NSRange, style: NSParagraphStyle)] = []

        unsafe storage.enumerateAttribute(.paragraphStyle, in: textRange) { value, range, _ in
            let paragraphStyle = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            guard value == nil || paragraphStyle.lineBreakMode != targetLineBreakMode else { return }

            paragraphStyle.lineBreakMode = targetLineBreakMode
            updates.append((range, paragraphStyle.copy() as! NSParagraphStyle))
        }

        guard !updates.isEmpty else { return }

        TextEditingTransaction.perform(on: textContentStorage) { storage in
            for update in updates {
                storage.addAttribute(.paragraphStyle, value: update.style, range: update.range)
            }
        }
    }

    func resolvedSyntaxColor(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: traitCollection)
    }

    var currentThemeAppearance: SyntaxEditorTheme.Appearance {
        traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    func resolvedTheme() -> SyntaxEditorTheme.Resolved {
        lastAppliedTheme.resolved(
            for: model.language,
            appearance: currentThemeAppearance
        )
    }

    func updateEditorBackgroundColor() {
        updateEditorBackgroundColor(drawsBackground: model.drawsBackground)
    }

    func updateEditorBackgroundColor(drawsBackground: Bool) {
        let color = drawsBackground ? resolvedSyntaxColor(resolvedTheme().background) : .clear
        isOpaque = drawsBackground && color.cgColor.alpha >= 1
        backgroundColor = color
        textContentView.backgroundColor = backgroundColor
    }
}

private extension UIFont {
    func syntaxEditorFontSizeAdjusted(by delta: Int) -> UIFont {
        withSize(SyntaxEditorTheme.FontSize.pointSize(pointSize, applying: delta))
    }
}
#endif
