#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  struct PendingHighlightApplication {
    let tokens: [SyntaxEditorHighlighting.Token]
    let expectedRevision: Int
    let source: String
    let language: SyntaxLanguage
    let refreshRanges: [NSRange]
    let mutation: SyntaxEditorTextChange.Replacement?
    let recordsCache: Bool
    let phase: SyntaxEditorHighlighting.Result.Phase
    let tokenPayload: SyntaxEditorHighlighting.Result.Payload
  }

  struct ScheduledHighlightRequest {
    let id: Int
    let model: SyntaxEditorModel
    let language: SyntaxLanguage
    let revision: Int
    let mutation: SyntaxEditorTextChange.Replacement?
  }

  enum PendingHighlightEdit {
    case incremental(SyntaxEditorTextChange.Replacement)
    case fullReset
  }

  private struct SyntaxHighlightAttributeKey: Hashable {
    let syntaxID: EditorSourceSyntax.ID
    let language: SyntaxLanguage
  }

  private struct SyntaxHighlightStyle {
    let foregroundColor: NSColor
    let font: NSFont
  }

  private struct SyntaxHighlightResolvedStyle {
    let key: SyntaxHighlightAttributeKey
    let attributes: SyntaxHighlightStyle
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

    private var styleCache: [SyntaxHighlightAttributeKey: SyntaxHighlightStyle] = [:]
    private var missingAttributeKeys: Set<SyntaxHighlightAttributeKey> = []
    private var fontCache: [SyntaxEditorTheme.FontDescriptor: NSFont] = [:]

    init(
      theme: SyntaxEditorTheme,
      defaultLanguage: SyntaxLanguage,
      appearance: SyntaxEditorTheme.Appearance,
      fontSizeDelta: Int
    ) {
      self.theme = theme
      self.defaultLanguage = defaultLanguage
      self.appearance = appearance
      self.fontSizeDelta = fontSizeDelta
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

      guard
        let style = SyntaxEditorHighlightTheme.style(
          for: syntaxID,
          in: theme,
          language: effectiveLanguage,
          appearance: appearance
        )
      else {
        missingAttributeKeys.insert(key)
        return nil
      }

      let resolvedStyle = SyntaxHighlightStyle(
        foregroundColor: style.foreground,
        font: platformFont(for: style.font)
      )
      styleCache[key] = resolvedStyle
      return (key, resolvedStyle)
    }

    private mutating func platformFont(for descriptor: SyntaxEditorTheme.FontDescriptor) -> NSFont {
      if let cached = fontCache[descriptor] {
        return cached
      }
      let font = descriptor.platformFont(fontSizeDelta: fontSizeDelta)
      fontCache[descriptor] = font
      return font
    }
  }

  extension NSColor {
    static func syntaxEditorAlpha(_ color: NSColor, alpha: CGFloat) -> NSColor {
      NSColor(name: nil) { appearance in
        var resolvedColor = color.withAlphaComponent(alpha)
        appearance.performAsCurrentDrawingAppearance {
          resolvedColor = color.withAlphaComponent(alpha)
        }
        return resolvedColor
      }
    }
  }

  extension SyntaxEditorView {

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

    internal var bracketHighlightRangesForTesting: [NSRange] {
      matchedBracketRanges
    }

    internal var visibleTextDisplayInvalidationCountForTesting: Int {
      visibleTextDisplayInvalidationCount
    }

    internal var fullTextDisplayInvalidationCountForTesting: Int {
      fullTextDisplayInvalidationCount
    }

    internal var fragmentDisplayInvalidationCountForTesting: Int {
      textView.fragmentDisplayInvalidationCount
    }

    internal var syntaxForegroundMaterializationCountForTesting: Int {
      textSystem.styleStore.epoch
    }

    internal var syntaxRenderingAttributeApplicationCountForTesting: Int {
      textView.syntaxRenderingAttributeApplicationCountForTesting
    }

    internal var syntaxColorRunCountForTesting: Int {
      textSystem.styleStore.appliedColorRunsForTesting.count
    }

    internal var lineMetricsFullRebuildCountForTesting: Int {
      textView.lineMetrics.fullRebuildCount
    }

    internal func materializeSyntaxForegroundForTesting(in range: NSRange) {
      textView.setNeedsDisplayForTextRanges([range])
    }

    internal func syntaxForegroundColorForTesting(at location: Int) -> NSColor? {
      guard location >= 0,
        location < textStorage.length
      else {
        return nil
      }
      return textSystem.styleStore.foregroundColor(at: location)
    }

    internal func syntaxFontForTesting(at location: Int) -> NSFont? {
      guard location >= 0,
        location < textStorage.length
      else {
        return nil
      }
      return textSystem.styleStore.font(at: location)
    }

    internal func baseForegroundColorForTesting() -> NSColor? {
      textSystem.styleStore.baseForeground
    }

    private func resetHighlightPhaseTrackingForTesting() {
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
      guard
        let waiterIndex = skippedHighlightPhaseWaitersForTesting.firstIndex(where: { $0.id == id })
      else {
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
      refreshStartUTF16 _: Int = 0
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
      pendingHighlightApplication = nil
      resetHighlightPhaseTrackingForTesting()

      let highlighter = self.highlighter
      // Viewport hint: progressive opens and background semantic drains
      // process the chunk nearest this range first (pure ordering hint).
      let visibleRange = textView.visibleCharacterRangeWithoutLayout()
      let operation: SyntaxEditorHighlighting.Request.Operation =
        if let mutation {
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
      highlightTask = Task.detached(priority: .utility) {
        [
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
        scheduleHighlight(
          source: result.source, language: result.language, revision: result.revision)
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
      await applyHighlightFromScheduledTask(
        result.tokens,
        expectedRevision: result.revision,
        source: result.source,
        language: result.language,
        refreshRanges: refreshRanges,
        mutation: mutation,
        recordsCache: result.phase == .complete,
        phase: result.phase,
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

    private func hasMaterializedCompletedHighlightToAvoidDowngrade(
      for result: SyntaxEditorHighlighting.Result
    ) -> Bool {
      guard materializedHighlightPhase == .complete,
        materializedHighlightLanguage == result.language,
        textSystem.styleStore.hasMaterializedRuns,
        let materializedHighlightRevision
      else {
        return false
      }

      return materializedHighlightRevision < result.revision
    }

    private func highlightApplicationRefreshRanges(
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
      let source = source ?? textView.string
      let language = language ?? model.language
      let revision = revision ?? model.textRevision

      if hasScheduledFullResetHighlight(language: language, revision: revision) {
        return
      }
      guard
        hasReusableRecordedHighlightSnapshot(
          source: source,
          language: language,
          revision: revision
        )
      else {
        scheduleHighlight(source: source, language: language, revision: revision)
        return
      }

      applyHighlight(
        lastHighlightTokens,
        expectedRevision: revision,
        source: source,
        language: language,
        refreshRanges: [NSRange(location: 0, length: source.utf16.count)],
        mutation: nil
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
      lastHighlightTokens = []
      lastHighlightSource = nil
      lastHighlightRevision = nil
      lastHighlightLanguage = nil
      clearMaterializedHighlightState()
      pendingHighlightApplication = nil
      resetHighlightPhaseTrackingForTesting()
      resetSyntaxHighlightRenderingState(textLength: textStorage.length)
    }

    func replaceEntireStorageText(_ nextText: String) {
      resetSyntaxHighlightRenderingState(textLength: nextText.utf16.count)
      textView.lineMetrics.reset(source: nextText)
      TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
        textStorage.setAttributedString(
          NSAttributedString(string: nextText, attributes: storageBaseAttributes()))
      }
      textView.setSelectedRange(textView.selectedRange())
      textView.invalidateTextLayout()
    }

    func applyStorageTextEdits(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
      guard editsAreValid(edits) else { return false }

      let base = storageBaseAttributes()
      let previousSource = textStorage.string
      TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
          let replacement = NSAttributedString(string: edit.replacement, attributes: base)
          textStorage.replaceCharacters(in: edit.range, with: replacement)
        }
      }
      textView.lineMetrics.apply(edits: edits, previousSource: previousSource)
      textView.invalidateTextLayout()
      return true
    }

    func applyResolvedFontsToExistingText() {
      applyResolvedFontsToExistingText(
        source: textView.string,
        language: model.language,
        revision: model.textRevision
      )
    }

    func applyResolvedFontsToExistingText(
      source: String,
      language: SyntaxLanguage,
      revision: Int
    ) {
      let textRange = NSRange(location: 0, length: textStorage.length)
      let base = baseAttributes()
      guard textRange.length > 0,
        let baseFont = base[.font] as? NSFont
      else {
        return
      }

      TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
        textStorage.addAttribute(.font, value: baseFont, range: textRange)
      }

      var didRecomputeSyntaxFontRuns = false
      if hasReusableRecordedHighlightSnapshot(
        source: source,
        language: language,
        revision: revision
      ),
        let baseForeground = base[.foregroundColor] as? NSColor
      {
        var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: base)
        let runSet = syntaxHighlightRunSet(
          for: lastHighlightTokens,
          targetRange: textRange,
          textLength: textStorage.length,
          resolver: &resolver,
          baseFont: baseFont
        )
        textSystem.styleStore.commitSnapshot(
          runSet: runSet,
          range: textRange,
          revision: revision,
          language: language,
          textLength: textStorage.length,
          baseForeground: baseForeground,
          baseFont: baseFont,
          suppressionRanges: foregroundSuppressionRanges(textLength: textStorage.length)
        )
        didRecomputeSyntaxFontRuns = true
      }
      if !didRecomputeSyntaxFontRuns {
        let invalidatedFontRuns = textSystem.styleStore.updateBaseFont(
          baseFont,
          textLength: textStorage.length,
          clearsFontRuns: true
        )
        invalidateSyntaxRenderingAttributes(for: invalidatedFontRuns)
      }

      clearMaterializedSyntaxHighlightRendering()
      invalidateSyntaxRenderingAttributes(for: textRange)
      textView.invalidateTextLayout()
      invalidateVisibleTextDisplay()
    }

    func cachedSyntaxFontRunsChanged(
      from previousTheme: SyntaxEditorTheme,
      previousAppearance: SyntaxEditorTheme.Appearance,
      previousFontSizeDelta: Int,
      to nextTheme: SyntaxEditorTheme,
      nextAppearance: SyntaxEditorTheme.Appearance,
      nextFontSizeDelta: Int,
      language: SyntaxLanguage,
      revision: Int? = nil
    ) -> Bool {
      let source = textView.string
      let textLength = textStorage.length
      let revision = revision ?? model.textRevision
      guard
        let previousRuns = cachedSyntaxFontRuns(
          for: previousTheme,
          language: language,
          appearance: previousAppearance,
          fontSizeDelta: previousFontSizeDelta,
          source: source,
          textLength: textLength,
          revision: revision
        ),
        let nextRuns = cachedSyntaxFontRuns(
          for: nextTheme,
          language: language,
          appearance: nextAppearance,
          fontSizeDelta: nextFontSizeDelta,
          source: source,
          textLength: textLength,
          revision: revision
        )
      else {
        return false
      }

      return !syntaxFontRunsEqual(previousRuns, nextRuns)
    }

    private func cachedSyntaxFontRuns(
      for theme: SyntaxEditorTheme,
      language: SyntaxLanguage,
      appearance: SyntaxEditorTheme.Appearance,
      fontSizeDelta: Int,
      source: String,
      textLength: Int,
      revision: Int
    ) -> [HighlightFontRun]? {
      guard textLength > 0,
        hasReusableRecordedHighlightSnapshot(
          source: source,
          language: language,
          revision: revision
        )
      else {
        return nil
      }

      let resolvedTheme = theme.resolved(for: language, appearance: appearance)
      let baseFont = resolvedBaseFont(for: resolvedTheme, fontSizeDelta: fontSizeDelta)
      var resolver = makeSyntaxHighlightAttributeResolver(
        theme: theme,
        language: language,
        appearance: appearance,
        fontSizeDelta: fontSizeDelta
      )
      let runSet = syntaxHighlightRunSet(
        for: lastHighlightTokens,
        targetRange: NSRange(location: 0, length: textLength),
        textLength: textLength,
        resolver: &resolver,
        baseFont: baseFont
      )
      return runSet.fontRuns
    }

    private func syntaxFontRunsEqual(_ lhs: [HighlightFontRun], _ rhs: [HighlightFontRun]) -> Bool {
      guard lhs.count == rhs.count else { return false }

      for (leftRun, rightRun) in zip(lhs, rhs) {
        guard NSEqualRanges(leftRun.range, rightRun.range),
          leftRun.font.isEqual(rightRun.font)
        else {
          return false
        }
      }
      return true
    }

    func editsAreValid(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
      let textLength = textStorage.length
      return edits.allSatisfy { edit in
        edit.range.location >= 0 && edit.range.location + edit.range.length <= textLength
      }
    }

    static func highlightMutation(_ change: SyntaxEditorTextChange) -> SyntaxEditorTextChange
      .Replacement?
    {
      guard change.replacements.count == 1, let edit = change.replacements.first else { return nil }
      return SyntaxEditorTextChange.Replacement(
        location: edit.range.location,
        length: edit.range.length,
        replacement: edit.replacement
      )
    }

    @discardableResult
    func applyHighlight(
      _ tokens: [SyntaxEditorHighlighting.Token],
      expectedRevision: Int,
      source expectedSource: String,
      language expectedLanguage: SyntaxLanguage,
      refreshRanges: [NSRange],
      mutation: SyntaxEditorTextChange.Replacement?,
      recordsCache: Bool = true,
      phase: SyntaxEditorHighlighting.Result.Phase = .complete,
      tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) -> Bool {
      guard model.textRevision == expectedRevision else { return false }
      guard model.language == expectedLanguage,
        textView.string == expectedSource
      else {
        pendingHighlightApplication = nil
        return false
      }
      let pendingApplication = PendingHighlightApplication(
        tokens: tokens,
        expectedRevision: expectedRevision,
        source: expectedSource,
        language: expectedLanguage,
        refreshRanges: refreshRanges,
        mutation: mutation,
        recordsCache: recordsCache,
        phase: phase,
        tokenPayload: tokenPayload
      )
      guard textView.selectedRange().length == 0 else {
        pendingHighlightApplication = pendingApplication
        clearMatchingBracketHighlight()
        return false
      }

      pendingHighlightApplication = nil

      let textLength = textStorage.length
      let targetRanges = Self.highlightTargetRanges(
        refreshRanges,
        textLength: textLength
      )
      guard !targetRanges.isEmpty else {
        if recordsCache {
          recordAppliedHighlight(
            tokens: tokens,
            source: expectedSource,
            revision: expectedRevision,
            language: expectedLanguage,
            tokenPayload: tokenPayload
          )
        }
        applyMatchingBracketHighlight(force: true)
        recordMaterializedHighlight(
          phase: phase,
          revision: expectedRevision,
          language: expectedLanguage
        )
        return true
      }
      let base = baseAttributes()

      isApplyingHighlight = true
      defer { isApplyingHighlight = false }

      for targetRange in targetRanges {
        installSyntaxHighlightRendering(
          for: tokens,
          targetRange: targetRange,
          textLength: textLength,
          baseAttributes: base,
          revision: expectedRevision,
          language: expectedLanguage
        )
      }
      textView.applyMarkedTextAttributes()
      textView.typingAttributes = base
      applyMatchingBracketHighlight(force: true)
      for targetRange in targetRanges {
        invalidateSyntaxHighlightDisplay(for: targetRange)
      }
      if recordsCache {
        recordAppliedHighlight(
          tokens: tokens,
          source: expectedSource,
          revision: expectedRevision,
          language: expectedLanguage,
          tokenPayload: tokenPayload
        )
      }
      recordMaterializedHighlight(
        phase: phase,
        revision: expectedRevision,
        language: expectedLanguage
      )
      return true
    }

    @discardableResult
    private func applyHighlightFromScheduledTask(
      _ tokens: [SyntaxEditorHighlighting.Token],
      expectedRevision: Int,
      source expectedSource: String,
      language expectedLanguage: SyntaxLanguage,
      refreshRanges: [NSRange],
      mutation: SyntaxEditorTextChange.Replacement?,
      recordsCache: Bool = true,
      phase: SyntaxEditorHighlighting.Result.Phase = .complete,
      tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) async -> Bool {
      guard model.textRevision == expectedRevision else { return false }
      guard model.language == expectedLanguage,
        textView.string == expectedSource
      else {
        pendingHighlightApplication = nil
        return false
      }
      let pendingApplication = PendingHighlightApplication(
        tokens: tokens,
        expectedRevision: expectedRevision,
        source: expectedSource,
        language: expectedLanguage,
        refreshRanges: refreshRanges,
        mutation: mutation,
        recordsCache: recordsCache,
        phase: phase,
        tokenPayload: tokenPayload
      )
      guard textView.selectedRange().length == 0 else {
        pendingHighlightApplication = pendingApplication
        clearMatchingBracketHighlight()
        return false
      }

      pendingHighlightApplication = nil

      let textLength = textStorage.length
      let targetRanges = Self.highlightTargetRanges(
        refreshRanges,
        textLength: textLength
      )
      guard !targetRanges.isEmpty else {
        if recordsCache {
          recordAppliedHighlight(
            tokens: tokens,
            source: expectedSource,
            revision: expectedRevision,
            language: expectedLanguage,
            tokenPayload: tokenPayload
          )
        }
        applyMatchingBracketHighlight(force: true)
        recordMaterializedHighlight(
          phase: phase,
          revision: expectedRevision,
          language: expectedLanguage
        )
        return true
      }
      let base = baseAttributes()
      guard !Task.isCancelled else { return false }
      isApplyingHighlight = true
      defer { isApplyingHighlight = false }
      for targetRange in targetRanges {
        guard
          await installSyntaxHighlightRenderingIncrementally(
            for: tokens,
            targetRange: targetRange,
            textLength: textLength,
            baseAttributes: base,
            expectedRevision: expectedRevision
          )
        else { return false }
      }
      guard !Task.isCancelled, model.textRevision == expectedRevision else { return false }

      textView.applyMarkedTextAttributes()
      textView.typingAttributes = base
      applyMatchingBracketHighlight(force: true)
      for targetRange in targetRanges {
        invalidateSyntaxHighlightDisplay(for: targetRange)
      }
      if recordsCache {
        recordAppliedHighlight(
          tokens: tokens,
          source: expectedSource,
          revision: expectedRevision,
          language: expectedLanguage,
          tokenPayload: tokenPayload
        )
      }
      recordMaterializedHighlight(
        phase: phase,
        revision: expectedRevision,
        language: expectedLanguage
      )
      return true
    }

    private func makeSyntaxHighlightAttributeResolver(
      baseAttributes: [NSAttributedString.Key: Any]
    ) -> SyntaxHighlightAttributeResolver {
      SyntaxHighlightAttributeResolver(
        theme: lastAppliedTheme ?? model.theme,
        defaultLanguage: model.language,
        appearance: currentThemeAppearance,
        fontSizeDelta: model.fontSizeDelta
      )
    }

    private func makeSyntaxHighlightAttributeResolver(
      theme: SyntaxEditorTheme,
      language: SyntaxLanguage,
      appearance: SyntaxEditorTheme.Appearance,
      fontSizeDelta: Int
    ) -> SyntaxHighlightAttributeResolver {
      SyntaxHighlightAttributeResolver(
        theme: theme,
        defaultLanguage: language,
        appearance: appearance,
        fontSizeDelta: fontSizeDelta
      )
    }

    private func installSyntaxHighlightRendering(
      for tokens: [SyntaxEditorHighlighting.Token],
      targetRange: NSRange,
      textLength: Int,
      baseAttributes: [NSAttributedString.Key: Any],
      revision: Int,
      language: SyntaxLanguage
    ) {
      guard let baseForeground = baseAttributes[.foregroundColor] as? NSColor else {
        return
      }
      var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: baseAttributes)
      let runSet = syntaxHighlightRunSet(
        for: tokens,
        targetRange: targetRange,
        textLength: textLength,
        resolver: &resolver,
        baseFont: baseAttributes[.font] as? NSFont
      )
      let invalidatedDirtyRanges = textSystem.styleStore.commitSnapshot(
        runSet: runSet,
        range: targetRange,
        revision: revision,
        language: language,
        textLength: textLength,
        baseForeground: baseForeground,
        baseFont: baseAttributes[.font] as? NSFont,
        suppressionRanges: foregroundSuppressionRanges(textLength: textLength)
      )
      invalidateSyntaxRenderingAttributes(for: [targetRange] + invalidatedDirtyRanges)
    }

    private func installSyntaxHighlightRenderingIncrementally(
      for tokens: [SyntaxEditorHighlighting.Token],
      targetRange: NSRange,
      textLength: Int,
      baseAttributes: [NSAttributedString.Key: Any],
      expectedRevision: Int
    ) async -> Bool {
      guard let baseForeground = baseAttributes[.foregroundColor] as? NSColor else {
        return false
      }
      var resolver = makeSyntaxHighlightAttributeResolver(baseAttributes: baseAttributes)
      let runSet = syntaxHighlightRunSet(
        for: tokens,
        targetRange: targetRange,
        textLength: textLength,
        resolver: &resolver,
        baseFont: baseAttributes[.font] as? NSFont
      )
      guard !Task.isCancelled, model.textRevision == expectedRevision else { return false }
      let invalidatedDirtyRanges = textSystem.styleStore.commitSnapshot(
        runSet: runSet,
        range: targetRange,
        revision: expectedRevision,
        language: model.language,
        textLength: textLength,
        baseForeground: baseForeground,
        baseFont: baseAttributes[.font] as? NSFont,
        suppressionRanges: foregroundSuppressionRanges(textLength: textLength)
      )
      invalidateSyntaxRenderingAttributes(for: [targetRange] + invalidatedDirtyRanges)
      return true
    }

    private func invalidateSyntaxRenderingAttributes(for range: NSRange) {
      invalidateSyntaxRenderingAttributes(for: [range])
    }

    private func invalidateSyntaxRenderingAttributes(for ranges: [NSRange]) {
      textView.invalidateSyntaxRenderingAttributes(for: ranges)
    }

    private func foregroundSuppressionRanges(textLength: Int) -> [NSRange] {
      let markedRange = textView.markedRange()
      guard markedRange.location != NSNotFound else { return [] }
      let clamped = SyntaxEditorRangeUtilities.clampedRange(markedRange, utf16Length: textLength)
      return clamped.length > 0 ? [clamped] : []
    }

    func syncMarkedTextSuppressionRanges() {
      let textLength = textStorage.length
      textSystem.styleStore.updateSuppressionRanges(
        foregroundSuppressionRanges(textLength: textLength),
        textLength: textLength
      )
    }

    private func syntaxHighlightRunSet(
      for tokens: [SyntaxEditorHighlighting.Token],
      targetRange: NSRange,
      textLength: Int,
      resolver: inout SyntaxHighlightAttributeResolver,
      baseFont: NSFont?
    ) -> HighlightRunSet {
      let resolvedRuns = syntaxHighlightResolvedRuns(
        for: tokens,
        targetRange: targetRange,
        textLength: textLength,
        resolver: &resolver
      )
      var colorRuns: [HighlightColorRun] = []
      colorRuns.reserveCapacity(resolvedRuns.count)
      var fontRuns: [HighlightFontRun] = []
      fontRuns.reserveCapacity(resolvedRuns.count)

      for run in resolvedRuns {
        if var last = colorRuns.last,
          last.color.isEqual(run.style.attributes.foregroundColor),
          last.range.upperBound >= run.range.location,
          run.range.upperBound >= last.range.location
        {
          let lowerBound = min(last.range.location, run.range.location)
          let upperBound = max(last.range.upperBound, run.range.upperBound)
          last.range = NSRange(location: lowerBound, length: upperBound - lowerBound)
          colorRuns[colorRuns.count - 1] = last
        } else {
          colorRuns.append(
            HighlightColorRun(range: run.range, color: run.style.attributes.foregroundColor))
        }
        let font = run.style.attributes.font
        guard baseFont.map({ !font.isEqual($0) }) ?? true
        else {
          continue
        }
        fontRuns.append(HighlightFontRun(range: run.range, font: font))
      }

      return HighlightRunSet(colorRuns: colorRuns, fontRuns: fontRuns)
    }

    private func syntaxHighlightResolvedRuns(
      for tokens: [SyntaxEditorHighlighting.Token],
      targetRange: NSRange,
      textLength: Int,
      resolver: inout SyntaxHighlightAttributeResolver
    ) -> [HighlightAssembledRun<SyntaxHighlightResolvedStyle>] {
      HighlightRunAssembler.assembleRuns(
        for: tokens,
        targetRange: targetRange,
        textLength: textLength
      ) { token in
        guard let resolved = resolver.style(for: token.syntaxID, language: token.language) else {
          return nil
        }
        return SyntaxHighlightResolvedStyle(key: resolved.key, attributes: resolved.style)
      } stylesCanCoalesce: { lhs, rhs in
        lhs.key == rhs.key
      }
    }

    private func recordAppliedHighlight(
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

    func applyPendingHighlightIfSelectionAllows() {
      guard textView.selectedRange().length == 0,
        let pendingHighlightApplication
      else {
        return
      }

      self.pendingHighlightApplication = nil
      applyHighlight(
        pendingHighlightApplication.tokens,
        expectedRevision: pendingHighlightApplication.expectedRevision,
        source: pendingHighlightApplication.source,
        language: pendingHighlightApplication.language,
        refreshRanges: pendingHighlightApplication.refreshRanges,
        mutation: pendingHighlightApplication.mutation,
        recordsCache: pendingHighlightApplication.recordsCache,
        phase: pendingHighlightApplication.phase,
        tokenPayload: pendingHighlightApplication.tokenPayload
      )
    }

    private func invalidateTextDisplay(forCharacterRanges ranges: [NSRange]) {
      textView.setNeedsDisplayForTextRanges(ranges)
    }

    private func invalidateSyntaxHighlightDisplay(for refreshRange: NSRange) {
      guard let visibleRange = visibleTextCharacterRange() else { return }
      let intersection = SyntaxEditorRangeUtilities.intersection(
        of: refreshRange, and: visibleRange)
      guard intersection.length > 0 else { return }
      invalidateTextDisplay(forCharacterRanges: [intersection])
    }

    private func clearSyntaxHighlightRendering() {
      let base = baseAttributes()
      if let baseForeground = base[.foregroundColor] as? NSColor {
        textSystem.styleStore.clear(
          textLength: textStorage.length,
          baseForeground: baseForeground,
          baseFont: base[.font] as? NSFont
        )
        invalidateSyntaxRenderingAttributes(for: NSRange(location: 0, length: textStorage.length))
      }
      clearMaterializedHighlightState()
      invalidateVisibleTextDisplay()
    }

    private func resetSyntaxHighlightRenderingState(textLength: Int) {
      textSystem.styleStore.reset(textLength: textLength)
      clearMaterializedHighlightState()
    }

    func prepareSyntaxHighlightRenderingForPendingTextChange(
      mutation: SyntaxEditorTextChange.Replacement?,
      source: String,
      refreshStartUTF16 _: Int
    ) {
      guard let mutation else {
        clearSyntaxHighlightRendering()
        return
      }
      let invalidatedRange = pendingTextReplacementRange(in: source, mutation: mutation)
      textSystem.styleStore.recordPendingEdit(mutation, currentTextLength: source.utf16.count)
      invalidateSyntaxRenderingAttributes(for: invalidatedRange)
      textView.setNeedsDisplayForTextRanges([invalidatedRange])
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

    private func suspendSyntaxHighlightMaterialization() {
      invalidateVisibleTextDisplay()
    }

    private func clearMaterializedSyntaxHighlightRendering() {
      invalidateVisibleTextDisplay()
    }

    func invalidateVisibleTextDisplay() {
      guard textStorage.length > 0 else { return }
      visibleTextDisplayInvalidationCount += 1

      guard let visibleRange = visibleTextCharacterRange() else {
        textView.setNeedsDisplayForVisibleTextFragments()
        return
      }
      textView.setNeedsDisplayForTextRanges([visibleRange])
    }

    private func visibleTextCharacterRange() -> NSRange? {
      guard textStorage.length > 0 else { return nil }
      textView.layoutVisibleViewport()
      return textView.visibleCharacterRange()
    }

  }
#endif
