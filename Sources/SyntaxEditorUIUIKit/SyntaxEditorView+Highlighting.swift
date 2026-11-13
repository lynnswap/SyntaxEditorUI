#if canImport(UIKit)
import SyntaxEditorCore
import SyntaxEditorUICommon
import UIKit

@MainActor
extension SyntaxEditorView: HighlightRequestCoordinatorClient {
    package var highlightTextRevision: Int {
        model.textRevision
    }

    package var hasRenderedHighlightRuns: Bool {
        highlightStyleStore.hasMaterializedRuns
    }

    package func scheduleFullHighlight(source: String, language: SyntaxLanguage, revision: Int) {
        scheduleHighlight(source: source, language: language, revision: revision)
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
        applyBaseForegroundColorChange(to: theme)
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
        typingAttributes = baseAttributes()
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
        if let tokens = highlightCoordinator.replayableTokens(
            source: source,
            language: language,
            revision: revision
        ),
           let baseForeground = baseAttributes()[.foregroundColor] as? UIColor {
            var resolver = makeHighlightStyleResolver(baseAttributes: baseAttributes())
            let runSet = syntaxHighlightRunSet(
                for: tokens,
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

    func scheduleHighlight(
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        mutation: SyntaxEditorTextChange.Replacement? = nil
    ) {
        prepareSyntaxHighlightRenderingForPendingHighlight(
            mutation: mutation,
            source: source
        )
        highlightCoordinator.schedule(
            source: source,
            language: language,
            revision: revision,
            mutation: mutation,
            visibleRange: visibleCharacterRangeForHighlightHint()
        )
    }

    func reapplyCachedHighlight(
        source: String? = nil,
        language: SyntaxLanguage? = nil,
        revision: Int? = nil
    ) {
        let source = source ?? text
        let language = language ?? model.language
        let revision = revision ?? model.textRevision

        if highlightCoordinator.hasScheduledFullHighlight(language: language, revision: revision) {
            return
        }
        guard let tokens = highlightCoordinator.replayableTokens(
            source: source,
            language: language,
            revision: revision
        ) else {
            scheduleHighlight(source: source, language: language, revision: revision)
            return
        }

        applyHighlight(
            tokens,
            expectedRevision: revision,
            source: source,
            refreshRange: NSRange(location: 0, length: source.utf16.count)
        )
    }

    func clearHighlightCache() {
        highlightCoordinator.clear()
        resetSyntaxHighlightRenderingState(textLength: storage.length)
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
        highlightCoordinator.recordMaterialized(
            phase: .complete,
            revision: expectedRevision,
            language: model.language
        )
    }

    package func applyHighlightResult(_ result: SyntaxEditorHighlighting.Result) async -> Bool {
        guard model.textRevision == result.revision else { return false }
        guard model.language == result.language,
              text == result.source
        else {
            return false
        }

        let textLength = result.source.utf16.count
        let targetRanges = result.refreshRanges(clampedToTextLength: textLength)
        guard !targetRanges.isEmpty else {
            applyMatchingBracketHighlight(force: true)
            return true
        }
        let base = baseAttributes()

        for targetRange in targetRanges {
            guard await commitSyntaxHighlightSnapshotFromScheduledTask(
                for: result.tokens,
                targetRange: targetRange,
                baseAttributes: base,
                textLength: textLength,
                revision: result.revision,
                language: result.language
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

    private func makeHighlightStyleResolver(
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> HighlightStyleResolver {
        HighlightStyleResolver(
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
        resolver: inout HighlightStyleResolver
    ) -> HighlightRunSet {
        HighlightRunAssembler.assembleRunSet(
            for: tokens,
            targetRange: renderRange,
            textLength: textLength
        ) { token in
            resolver.style(for: token.syntaxID, language: token.language)?.style
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
        var resolver = makeHighlightStyleResolver(baseAttributes: baseAttributes)
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
        source: String
    ) {
        let textLength = source.utf16.count
        guard let mutation else {
            clearSyntaxHighlightRendering()
            return
        }

        let invalidatedRange = mutation.repaintRange(inTextOfLength: textLength)
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
        highlightCoordinator.clearMaterialized()
        setNeedsDisplayForVisibleTextFragments()
    }

    func resetSyntaxHighlightRenderingState(textLength: Int) {
        highlightStyleStore.reset(textLength: textLength)
        highlightCoordinator.clearMaterialized()
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

        if let tokens = highlightCoordinator.replayableTokens(
            source: text,
            language: model.language,
            revision: model.textRevision
        ) {
            applyHighlight(
                tokens,
                expectedRevision: model.textRevision,
                source: text,
                refreshRange: targetRange
            )
        } else {
            TextEditingTransaction.perform(on: textContentStorage) { storage in
                storage.addAttributes(baseAttributes(), range: targetRange)
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
        didUpdateSyntaxRendering?([textRange])
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
#endif
