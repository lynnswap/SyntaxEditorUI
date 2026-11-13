#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  enum PendingHighlightEdit {
    case incremental(SyntaxEditorTextChange.Replacement)
    case fullReset
  }

  private struct SyntaxHighlightResolvedStyle {
    let key: HighlightStyleResolver.Key
    let attributes: HighlightRunStyle
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

  extension SyntaxEditorView: HighlightRequestCoordinatorClient {
    package var highlightTextRevision: Int {
      model.textRevision
    }

    package var hasRenderedHighlightRuns: Bool {
      textSystem.styleStore.hasMaterializedRuns
    }

    package func scheduleFullHighlight(source: String, language: SyntaxLanguage, revision: Int) {
      scheduleHighlight(source: source, language: language, revision: revision)
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

    func scheduleHighlight(
      source: String,
      language: SyntaxLanguage,
      revision: Int,
      mutation: SyntaxEditorTextChange.Replacement? = nil
    ) {
      pendingHighlightResult = nil
      highlightCoordinator.schedule(
        source: source,
        language: language,
        revision: revision,
        mutation: mutation,
        visibleRange: textView.visibleCharacterRangeWithoutLayout()
      )
    }

    func reapplyCachedHighlight(
      source: String? = nil,
      language: SyntaxLanguage? = nil,
      revision: Int? = nil
    ) {
      let source = source ?? textView.string
      let language = language ?? model.language
      let revision = revision ?? model.textRevision

      if highlightCoordinator.hasScheduledFullHighlight(language: language, revision: revision) {
        return
      }
      guard
        let tokens = highlightCoordinator.replayableTokens(
          source: source,
          language: language,
          revision: revision
        )
      else {
        scheduleHighlight(source: source, language: language, revision: revision)
        return
      }

      applyHighlight(
        SyntaxEditorHighlighting.Result(
          tokens: tokens,
          source: source,
          language: language,
          revision: revision,
          refreshRanges: [NSRange(location: 0, length: source.utf16.count)]
        )
      )
    }

    func clearHighlightCache() {
      highlightCoordinator.clear()
      pendingHighlightResult = nil
      resetSyntaxHighlightRenderingState(textLength: textStorage.length)
    }

    func replaceEntireStorageText(_ nextText: String) {
      resetSyntaxHighlightRenderingState(textLength: nextText.utf16.count)
      textView.lineMetrics.reset(source: nextText)
      TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
        textStorage.setAttributedString(
          NSAttributedString(string: nextText, attributes: baseAttributes()))
      }
      textView.setSelectedRange(textView.selectedRange())
      textView.invalidateTextLayout()
    }

    func applyStorageTextEdits(_ edits: [SyntaxEditorTextChange.Replacement]) -> Bool {
      guard editsAreValid(edits) else { return false }

      let base = baseAttributes()
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
      if let tokens = highlightCoordinator.replayableTokens(
        source: source,
        language: language,
        revision: revision
      ),
        let baseForeground = base[.foregroundColor] as? NSColor
      {
        var resolver = makeHighlightStyleResolver(baseAttributes: base)
        let runSet = syntaxHighlightRunSet(
          for: tokens,
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
        let tokens = highlightCoordinator.replayableTokens(
          source: source,
          language: language,
          revision: revision
        )
      else {
        return nil
      }

      let resolvedTheme = theme.resolved(for: language, appearance: appearance)
      let baseFont = resolvedBaseFont(for: resolvedTheme, fontSizeDelta: fontSizeDelta)
      var resolver = makeHighlightStyleResolver(
        theme: theme,
        language: language,
        appearance: appearance,
        fontSizeDelta: fontSizeDelta
      )
      let runSet = syntaxHighlightRunSet(
        for: tokens,
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

    /// Renders `result` now, or keeps it for
    /// ``applyPendingHighlightIfSelectionAllows()`` while text is selected.
    @discardableResult
    func applyHighlight(_ result: SyntaxEditorHighlighting.Result) -> Bool {
      guard let targetRanges = highlightTargetRanges(forRendering: result) else { return false }

      if targetRanges.isEmpty {
        applyMatchingBracketHighlight(force: true)
      } else {
        let base = baseAttributes()
        isApplyingHighlight = true
        defer { isApplyingHighlight = false }

        for targetRange in targetRanges {
          installSyntaxHighlightRendering(
            for: result.tokens,
            targetRange: targetRange,
            textLength: textStorage.length,
            baseAttributes: base,
            revision: result.revision,
            language: result.language
          )
        }
        finishApplyingHighlight(in: targetRanges, baseAttributes: base)
      }
      highlightCoordinator.recordApplied(result)
      return true
    }

    package func applyHighlightResult(_ result: SyntaxEditorHighlighting.Result) async -> Bool {
      guard let targetRanges = highlightTargetRanges(forRendering: result) else { return false }
      guard !targetRanges.isEmpty else {
        applyMatchingBracketHighlight(force: true)
        return true
      }

      let textLength = textStorage.length
      let base = baseAttributes()
      guard !Task.isCancelled else { return false }
      isApplyingHighlight = true
      defer { isApplyingHighlight = false }
      for targetRange in targetRanges {
        guard
          await installSyntaxHighlightRenderingIncrementally(
            for: result.tokens,
            targetRange: targetRange,
            textLength: textLength,
            baseAttributes: base,
            expectedRevision: result.revision
          )
        else { return false }
      }
      guard !Task.isCancelled, model.textRevision == result.revision else { return false }

      finishApplyingHighlight(in: targetRanges, baseAttributes: base)
      return true
    }

    /// The ranges `result` asks to repaint, or `nil` when it cannot be rendered
    /// now: it no longer describes the displayed text, or text is selected and
    /// the result is kept until the selection collapses.
    private func highlightTargetRanges(
      forRendering result: SyntaxEditorHighlighting.Result
    ) -> [NSRange]? {
      guard model.textRevision == result.revision else { return nil }
      guard model.language == result.language,
        textView.string == result.source
      else {
        pendingHighlightResult = nil
        return nil
      }
      guard textView.selectedRange().length == 0 else {
        pendingHighlightResult = result
        clearMatchingBracketHighlight()
        return nil
      }

      pendingHighlightResult = nil
      return result.refreshRanges(clampedToTextLength: textStorage.length)
    }

    private func finishApplyingHighlight(
      in targetRanges: [NSRange],
      baseAttributes: [NSAttributedString.Key: Any]
    ) {
      textView.applyMarkedTextAttributes()
      textView.typingAttributes = baseAttributes
      applyMatchingBracketHighlight(force: true)
      for targetRange in targetRanges {
        invalidateSyntaxHighlightDisplay(for: targetRange)
      }
    }

    private func makeHighlightStyleResolver(
      baseAttributes: [NSAttributedString.Key: Any]
    ) -> HighlightStyleResolver {
      HighlightStyleResolver(
        theme: lastAppliedTheme ?? model.theme,
        defaultLanguage: model.language,
        appearance: currentThemeAppearance,
        fontSizeDelta: model.fontSizeDelta
      )
    }

    private func makeHighlightStyleResolver(
      theme: SyntaxEditorTheme,
      language: SyntaxLanguage,
      appearance: SyntaxEditorTheme.Appearance,
      fontSizeDelta: Int
    ) -> HighlightStyleResolver {
      HighlightStyleResolver(
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
      var resolver = makeHighlightStyleResolver(baseAttributes: baseAttributes)
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
      var resolver = makeHighlightStyleResolver(baseAttributes: baseAttributes)
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
      didUpdateSyntaxRendering?(ranges)
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
      resolver: inout HighlightStyleResolver,
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
      resolver: inout HighlightStyleResolver
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

    func applyPendingHighlightIfSelectionAllows() {
      guard textView.selectedRange().length == 0,
        let pendingHighlightResult
      else {
        return
      }

      self.pendingHighlightResult = nil
      applyHighlight(pendingHighlightResult)
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
      highlightCoordinator.clearMaterialized()
      invalidateVisibleTextDisplay()
    }

    private func resetSyntaxHighlightRenderingState(textLength: Int) {
      textSystem.styleStore.reset(textLength: textLength)
      highlightCoordinator.clearMaterialized()
    }

    func prepareSyntaxHighlightRenderingForPendingTextChange(
      mutation: SyntaxEditorTextChange.Replacement?,
      source: String
    ) {
      guard let mutation else {
        clearSyntaxHighlightRendering()
        return
      }
      let invalidatedRange = mutation.repaintRange(inTextOfLength: source.utf16.count)
      textSystem.styleStore.recordPendingEdit(mutation, currentTextLength: source.utf16.count)
      invalidateSyntaxRenderingAttributes(for: invalidatedRange)
      textView.setNeedsDisplayForTextRanges([invalidatedRange])
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
