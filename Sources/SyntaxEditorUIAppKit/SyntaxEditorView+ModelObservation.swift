#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  extension SyntaxEditorView {

    public var text: String {
      get { textView.string }
      set {
        guard let change = model.replaceText(newValue, selectedRange: selectedRange) else {
          updateTypingAttributes()
          return
        }
        applyObservedModelChange(forceTextUpdate: true, observedRevision: change.textRevision)
      }
    }

    public var selectedRange: NSRange {
      get { textView.selectedRange() }
      set {
        textView.setSelectedRange(newValue)
        model.selectedRange = textView.selectedRange()
      }
    }

    public var isEditable: Bool {
      get { model.isEditable }
      set {
        guard model.isEditable != newValue else { return }
        model.isEditable = newValue
      }
    }

    var modelDeliveryForTesting: PortableObservationTracking.Token? { modelObservation }
    var modelConfigurationDeliveryForTesting: PortableObservationTracking.Token? {
      modelConfigurationObservation
    }

    internal func synchronizeDocumentForTesting() {
      applyObservedConfiguration(
        language: model.language,
        isEditable: model.isEditable,
        lineWrappingEnabled: model.lineWrappingEnabled,
        theme: model.theme,
        drawsBackground: model.drawsBackground,
        fontSizeDelta: model.fontSizeDelta
      )
      applyObservedModelChange()
      applyObservedSelection(model.selectedRange)
    }

    func startModelObservation(
      schedulesInitialHighlight: Bool = true,
      skipsInitialModelDelivery: Bool = false
    ) {
      let model = model
      modelConfigurationObservation = withPortableContinuousObservation {
        [weak self, model] event in
        guard let self else { return }

        let language = model.language
        let isEditable = model.isEditable
        let lineWrappingEnabled = model.lineWrappingEnabled
        let theme = model.theme
        let drawsBackground = model.drawsBackground
        let fontSizeDelta = model.fontSizeDelta

        self.applyObservedConfiguration(
          language: language,
          isEditable: isEditable,
          lineWrappingEnabled: lineWrappingEnabled,
          theme: theme,
          drawsBackground: drawsBackground,
          fontSizeDelta: fontSizeDelta,
          forceLanguageRefresh: event.kind == .initial,
          schedulesHighlight: event.kind != .initial || schedulesInitialHighlight
        )
      }

      modelObservation = withPortableContinuousObservation { [weak self, model] event in
        guard let self else { return }

        _ = model.text
        let revision = model.textRevision
        let selectedRange = model.selectedRange

        guard !(skipsInitialModelDelivery && event.kind == .initial) else { return }
        self.applyObservedModelChange(
          forceTextUpdate: event.kind == .initial,
          observedRevision: revision
        )
        self.applyObservedSelection(selectedRange)
      }
    }

    func cancelModelObservations() {
      modelConfigurationObservation?.cancel()
      modelConfigurationObservation = nil
      modelObservation?.cancel()
      modelObservation = nil
    }

    func synchronizeReboundModel() {
      applyObservedConfiguration(
        language: model.language,
        isEditable: model.isEditable,
        lineWrappingEnabled: model.lineWrappingEnabled,
        theme: model.theme,
        drawsBackground: model.drawsBackground,
        fontSizeDelta: model.fontSizeDelta,
        forceLanguageRefresh: true,
        schedulesHighlight: false
      )
      applyObservedModelChange(forceTextUpdate: true, observedRevision: model.textRevision)
      applyObservedSelection(model.selectedRange)
    }

    private func applyObservedModelChange(
      forceTextUpdate: Bool = false, observedRevision: Int? = nil
    ) {
      let revision = observedRevision ?? model.textRevision
      guard forceTextUpdate || revision != lastAppliedDocumentRevision else { return }

      isApplyingModel = true
      defer {
        isApplyingModel = false
      }

      let text = model.text
      let textNeedsUpdate = forceTextUpdate || textView.string != text
      var highlightMutation: SyntaxEditorTextChange.Replacement?
      if textNeedsUpdate {
        commandEngine.invalidateTransientState()
        let change = model.latestTextChange
        if change?.kind == .wholeDocumentReplacement {
          activeUndoManager?.removeAllActions()
        }
        let canApplyIncrementally =
          change.map {
            $0.textRevision == revision
              && $0.kind == .incremental
              && !forceTextUpdate
              && lastAppliedDocumentRevision == revision - 1
          } ?? false
        let didApplyIncrementally =
          if canApplyIncrementally, let change {
            applyStorageTextEdits(change.replacements)
          } else {
            false
          }
        if didApplyIncrementally {
          highlightMutation = change.flatMap(Self.highlightMutation)
        } else {
          replaceEntireStorageText(text)
        }
        if let change,
          !(change.kind == .wholeDocumentReplacement
            && change.selectedRange == NSRange(location: 0, length: 0))
        {
          textView.setSelectedRange(change.selectedRange)
        }
      }

      updateTypingAttributes()
      if textNeedsUpdate {
        prepareSyntaxHighlightRenderingForPendingTextChange(
          mutation: highlightMutation,
          source: text,
          refreshStartUTF16: 0
        )
        scheduleHighlight(
          source: text,
          language: model.language,
          revision: revision,
          mutation: highlightMutation,
          refreshStartUTF16: 0
        )
      }
      lastAppliedDocumentRevision = revision
    }

    private func applyObservedSelection(_ range: NSRange) {
      let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textStorage.length)
      guard textView.selectedRange() != clamped else { return }

      isApplyingModel = true
      defer {
        isApplyingModel = false
      }
      textView.setSelectedRange(clamped)
    }

    private func applyObservedConfiguration(
      language: SyntaxLanguage,
      isEditable: Bool,
      lineWrappingEnabled: Bool,
      theme: SyntaxEditorTheme,
      drawsBackground: Bool,
      fontSizeDelta: Int,
      forceLanguageRefresh: Bool = false,
      schedulesHighlight: Bool = true
    ) {
      let previousTheme = lastAppliedTheme
      let themeChanged = previousTheme.map { $0 != theme } ?? true
      let fontSizeDeltaChanged = lastAppliedFontSizeDelta != fontSizeDelta
      let appearance = currentThemeAppearance
      let previousEffectiveTheme = previousTheme ?? theme
      let previousBaseFont = resolvedBaseFont(
        for: previousEffectiveTheme.resolved(for: language, appearance: appearance),
        fontSizeDelta: lastAppliedFontSizeDelta
      )
      let nextBaseFont = resolvedBaseFont(
        for: theme.resolved(for: language, appearance: appearance),
        fontSizeDelta: fontSizeDelta
      )
      let baseFontChanged = !previousBaseFont.isEqual(nextBaseFont)
      let hasCachedSyntaxFontRunChanges: Bool
      if themeChanged || fontSizeDeltaChanged {
        hasCachedSyntaxFontRunChanges = cachedSyntaxFontRunsChanged(
          from: previousEffectiveTheme,
          previousAppearance: appearance,
          previousFontSizeDelta: lastAppliedFontSizeDelta,
          to: theme,
          nextAppearance: appearance,
          nextFontSizeDelta: fontSizeDelta,
          language: language,
          revision: lastAppliedDocumentRevision
        )
      } else {
        hasCachedSyntaxFontRunChanges = false
      }
      if themeChanged {
        applyBaseForegroundColorChange(from: previousTheme, to: theme, language: language)
      }
      lastAppliedTheme = theme
      lastAppliedThemeAppearance = appearance
      lastAppliedFontSizeDelta = fontSizeDelta
      updateTextViewFontAndTypingAttributes()
      if baseFontChanged || hasCachedSyntaxFontRunChanges {
        applyResolvedFontsToExistingText(
          source: textView.string,
          language: language,
          revision: lastAppliedDocumentRevision
        )
      }
      updateEditorBackgroundColor(drawsBackground: drawsBackground)

      if textView.isEditable != isEditable {
        textView.isEditable = isEditable
      }

      applyLineWrappingConfiguration(lineWrappingEnabled: lineWrappingEnabled)

      let languageChanged =
        forceLanguageRefresh || lastAppliedLanguageIdentifier != language.syntaxHighlightCacheKey
      lastAppliedLanguageIdentifier = language.syntaxHighlightCacheKey

      if languageChanged && schedulesHighlight {
        scheduleHighlight(
          source: textView.string,
          language: language,
          revision: lastAppliedDocumentRevision,
          refreshStartUTF16: 0
        )
      } else if (themeChanged || fontSizeDeltaChanged) && schedulesHighlight {
        reapplyCachedHighlight(
          source: textView.string,
          language: language,
          revision: lastAppliedDocumentRevision
        )
      }
    }

    func applyBaseForegroundColorChange(
      from _: SyntaxEditorTheme?,
      to theme: SyntaxEditorTheme,
      language: SyntaxLanguage? = nil
    ) {
      let language = language ?? model.language
      let nextBaseForeground =
        theme
        .resolved(for: language, appearance: currentThemeAppearance)
        .baseForeground
      textSystem.styleStore.updateBaseForeground(nextBaseForeground, textLength: textStorage.length)
      let fullRange = NSRange(location: 0, length: textStorage.length)
      if fullRange.length > 0 {
        TextEditingTransaction.perform(on: textSystem.textContentStorage) { textStorage in
          textStorage.addAttribute(.foregroundColor, value: nextBaseForeground, range: fullRange)
        }
      }
      invalidateVisibleTextDisplay()
    }

  }
#endif
