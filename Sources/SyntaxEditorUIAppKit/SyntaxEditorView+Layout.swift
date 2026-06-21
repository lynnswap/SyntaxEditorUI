#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  extension SyntaxEditorView {

    func contentInsetsDidChange(from oldValue: NSEdgeInsets, to newValue: NSEdgeInsets) -> Bool {
      oldValue.top != newValue.top
        || oldValue.left != newValue.left
        || oldValue.bottom != newValue.bottom
        || oldValue.right != newValue.right
    }

    func configureScrollView() {
      scrollView.drawsBackground = model.drawsBackground
      scrollView.borderType = .noBorder
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = !model.lineWrappingEnabled
      scrollView.autohidesScrollers = true
      scrollView.documentView = textView
      isScrollViewConfigured = true
    }

    func configureTextView() {
      textView.drawsBackground = false
      updateEditorBackgroundColor()
      textView.isEditable = model.isEditable
      textView.guardedUndoManager = guardedUndoManager
      textView.didChangeText = { [weak self] in
        self?.textDidChange()
      }
      textView.didChangeSelection = { [weak self] in
        self?.textSelectionDidChange()
      }
      textView.shouldChangeText = { [weak self] ranges, replacements in
        self?.textShouldChange(inRanges: ranges, replacementStrings: replacements) ?? true
      }
      applyFindInteractionConfiguration()
      configureBaseTextViewAppearance()

      applyLineWrappingConfiguration(lineWrappingEnabled: model.lineWrappingEnabled)
    }

    func applyFindInteractionConfiguration() {
      if isFindInteractionEnabled {
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFindPanel = false
      } else {
        isFindBarVisible = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.usesFindPanel = false
      }
    }

    private func configureBaseTextViewAppearance() {
      let base = baseAttributes()
      updateRenderingBaseForeground(from: base)
      textView.font = base[.font] as? NSFont ?? textView.font
      textView.textColor = base[.foregroundColor] as? NSColor ?? textView.textColor
      textView.typingAttributes = base
    }

    func updateTextViewFontAndTypingAttributes() {
      let base = baseAttributes()
      updateRenderingBaseForeground(from: base)
      textView.font = base[.font] as? NSFont ?? textView.font
      textView.typingAttributes = base
    }

    func updateTypingAttributes() {
      let base = baseAttributes()
      updateRenderingBaseForeground(from: base)
      textView.typingAttributes = base
    }

    func updateRenderingBaseForeground(from base: [NSAttributedString.Key: Any]) {
      textSystem.styleStore.updateBaseForeground(
        base[.foregroundColor] as? NSColor,
        textLength: textStorage.length
      )
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
      let theme = resolvedTheme()
      return [
        .font: resolvedBaseFont(for: theme),
        .foregroundColor: theme.baseForeground,
      ]
    }

    func storageBaseAttributes() -> [NSAttributedString.Key: Any] {
      baseAttributes()
    }

    func resolvedBaseFont(for theme: SyntaxEditorTheme.Resolved? = nil) -> NSFont {
      resolvedBaseFont(for: theme, fontSizeDelta: model.fontSizeDelta)
    }

    func resolvedBaseFont(
      for theme: SyntaxEditorTheme.Resolved? = nil,
      fontSizeDelta: Int
    ) -> NSFont {
      let theme = theme ?? resolvedTheme()
      return theme.base.font.platformFont(fontSizeDelta: fontSizeDelta)
    }

    var currentThemeAppearance: SyntaxEditorTheme.Appearance {
      effectiveAppearance.syntaxEditorThemeAppearance
    }

    func resolvedTheme() -> SyntaxEditorTheme.Resolved {
      (lastAppliedTheme ?? model.theme).resolved(
        for: model.language,
        appearance: currentThemeAppearance
      )
    }

    func updateEditorBackgroundColor() {
      updateEditorBackgroundColor(drawsBackground: model.drawsBackground)
    }

    func updateEditorBackgroundColor(drawsBackground: Bool) {
      let color = resolvedTheme().background
      scrollView.drawsBackground = drawsBackground
      scrollView.backgroundColor = color
      textView.backgroundColor = color
    }

    func applyLineWrappingConfiguration(lineWrappingEnabled: Bool) {
      guard !isApplyingLineWrappingConfiguration else { return }

      isApplyingLineWrappingConfiguration = true
      defer { isApplyingLineWrappingConfiguration = false }

      var layoutGeometryChanged = false

      if scrollView.hasHorizontalScroller == lineWrappingEnabled {
        scrollView.hasHorizontalScroller = !lineWrappingEnabled
        scrollView.tile()
        layoutGeometryChanged = true
      }

      var contentSize = effectiveScrollContentSize
      var estimatedDocumentSize = estimatedTextViewDocumentSize(
        minimumContentSize: contentSize,
        lineWrappingEnabled: lineWrappingEnabled
      )

      if textView.minSize.height != contentSize.height {
        textView.minSize = NSSize(width: 0, height: contentSize.height)
      }

      let maxTextViewSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      if textView.maxSize != maxTextViewSize {
        textView.maxSize = maxTextViewSize
      }

      if lineWrappingEnabled {
        if textView.isHorizontallyResizable {
          textView.isHorizontallyResizable = false
          layoutGeometryChanged = true
        }
        if textView.autoresizingMask != [.width] {
          textView.autoresizingMask = [.width]
          layoutGeometryChanged = true
        }

        layoutGeometryChanged =
          applyWrappedTextGeometry(
            contentSize: contentSize,
            estimatedDocumentSize: estimatedDocumentSize
          ) || layoutGeometryChanged
        if !textContainer.widthTracksTextView {
          textContainer.widthTracksTextView = true
          layoutGeometryChanged = true
        }
        if textContainer.lineBreakMode != .byWordWrapping {
          textContainer.lineBreakMode = .byWordWrapping
          layoutGeometryChanged = true
        }

        if resetHorizontalClipOriginForWrapping() {
          layoutGeometryChanged = true
        }

        scrollView.tile()
        let settledContentSize = effectiveScrollContentSize
        if !settledContentSize.isNearlyEqual(to: contentSize) {
          contentSize = settledContentSize
          estimatedDocumentSize = estimatedTextViewDocumentSize(
            minimumContentSize: contentSize,
            lineWrappingEnabled: true
          )
          layoutGeometryChanged =
            applyWrappedTextGeometry(
              contentSize: contentSize,
              estimatedDocumentSize: estimatedDocumentSize
            ) || layoutGeometryChanged
        }
      } else {
        if !textView.isHorizontallyResizable {
          textView.isHorizontallyResizable = true
          layoutGeometryChanged = true
        }
        if !textView.autoresizingMask.isEmpty {
          textView.autoresizingMask = []
          layoutGeometryChanged = true
        }

        let containerSize = NSSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude
        )
        if !textContainer.containerSize.isNearlyEqual(to: containerSize) {
          textContainer.containerSize = containerSize
          layoutGeometryChanged = true
        }
        if textContainer.widthTracksTextView {
          textContainer.widthTracksTextView = false
          layoutGeometryChanged = true
        }
        if textContainer.lineBreakMode != .byClipping {
          textContainer.lineBreakMode = .byClipping
          layoutGeometryChanged = true
        }

        var frame = textView.frame
        if !frame.width.isNearlyEqual(to: estimatedDocumentSize.width)
          || !frame.height.isNearlyEqual(to: estimatedDocumentSize.height)
        {
          frame.size = estimatedDocumentSize
          textView.frame = frame
          layoutGeometryChanged = true
        }
      }

      if layoutGeometryChanged {
        invalidateTextLayoutAfterGeometryChange()
      }
    }

    private func applyWrappedTextGeometry(
      contentSize: NSSize,
      estimatedDocumentSize: NSSize
    ) -> Bool {
      var didChange = false
      let wrappingWidth = max(0, contentSize.width)
      var frame = textView.frame
      let frameHeight = estimatedDocumentSize.height
      if !frame.width.isNearlyEqual(to: wrappingWidth)
        || !frame.height.isNearlyEqual(to: frameHeight)
      {
        frame.size = NSSize(width: wrappingWidth, height: frameHeight)
        textView.frame = frame
        didChange = true
      }

      let containerSize = NSSize(width: wrappingWidth, height: CGFloat.greatestFiniteMagnitude)
      if !textContainer.containerSize.isNearlyEqual(to: containerSize) {
        textContainer.containerSize = containerSize
        didChange = true
      }
      return didChange
    }

    private var effectiveScrollContentSize: NSSize {
      let contentSize = scrollView.contentSize
      let contentInsets = scrollView.contentView.contentInsets
      let width = contentSize.width > 0 ? contentSize.width : bounds.width
      let height = contentSize.height > 0 ? contentSize.height : bounds.height
      return NSSize(
        width: max(0, width - max(0, contentInsets.left) - max(0, contentInsets.right)),
        height: max(0, height - max(0, contentInsets.top) - max(0, contentInsets.bottom))
      )
    }

    private func estimatedTextViewDocumentSize(
      minimumContentSize: NSSize,
      lineWrappingEnabled: Bool
    ) -> NSSize {
      let baseFont = textView.font ?? resolvedBaseFont()
      let lineHeight = max(1, ceil(baseFont.ascender - baseFont.descender + baseFont.leading))
      let estimatedColumnWidth = max(1, baseFont.pointSize * 0.65)
      return textView.lineMetrics.estimatedDocumentSize(
        minimumSize: minimumContentSize,
        lineWrappingEnabled: lineWrappingEnabled,
        lineHeight: lineHeight,
        columnWidth: estimatedColumnWidth,
        lineFragmentPadding: textContainer.lineFragmentPadding
      )
    }

    private func resetHorizontalClipOriginForWrapping() -> Bool {
      let clipView = scrollView.contentView
      let targetOriginX = -max(0, clipView.contentInsets.left)
      guard !clipView.bounds.origin.x.isNearlyEqual(to: targetOriginX) else { return false }

      clipView.scroll(to: NSPoint(x: targetOriginX, y: clipView.bounds.origin.y))
      scrollView.reflectScrolledClipView(clipView)
      return true
    }

    private func invalidateTextLayoutAfterGeometryChange() {
      layoutManager.invalidateLayout(for: textSystem.textContentStorage.documentRange)
      textView.layoutVisibleViewport()
      textView.setNeedsDisplayForVisibleTextFragments()
    }

  }

  extension NSAppearance {
    fileprivate var syntaxEditorThemeAppearance: SyntaxEditorTheme.Appearance {
      let match = bestMatch(from: [
        .darkAqua,
        .accessibilityHighContrastDarkAqua,
        .vibrantDark,
        .accessibilityHighContrastVibrantDark,
        .aqua,
        .accessibilityHighContrastAqua,
        .vibrantLight,
        .accessibilityHighContrastVibrantLight,
      ])
      return match == .darkAqua
        || match == .accessibilityHighContrastDarkAqua
        || match == .vibrantDark
        || match == .accessibilityHighContrastVibrantDark
        ? .dark
        : .light
    }
  }

  extension NSFont {
    fileprivate func syntaxEditorFontSizeAdjusted(by delta: Int) -> NSFont {
      withSize(SyntaxEditorTheme.FontSize.pointSize(pointSize, applying: delta))
    }
  }

  extension CGFloat {
    fileprivate func isNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
      abs(self - other) <= tolerance
    }
  }

  extension NSSize {
    fileprivate func isNearlyEqual(to other: NSSize, tolerance: CGFloat = 0.5) -> Bool {
      width.isNearlyEqual(to: other.width, tolerance: tolerance)
        && height.isNearlyEqual(to: other.height, tolerance: tolerance)
    }
  }
#endif
