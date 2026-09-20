#if canImport(AppKit)
import AppKit
import ObservationBridge
import SyntaxEditorCore
import SyntaxEditorUICommon

/// An AppKit comparison of a modified document and its read-only reference.
///
/// The modified editor remains installed when the presentation changes, preserving
/// its text selection and undo history. The reference uses the modified model's
/// language, theme, font size, and line-wrapping settings. Invoking Find from
/// inline deleted text opens the reference pane to search the entire reference.
@MainActor
public final class SyntaxEditorComparisonView: NSView {
    /// The comparison displayed by this view.
    public private(set) var model: SyntaxEditorComparisonModel

    /// The editor for the modified document, available for native configuration.
    public let modifiedEditor: SyntaxEditorView

    let originalEditor: SyntaxEditorView
    let modifiedLayout: SyntaxEditorComparisonTextLayout
    let originalLayout: SyntaxEditorComparisonTextLayout
    private let splitView = NSSplitView()
    private var comparisonObservation: PortableObservationTracking.Token?
    private var configurationObservation: PortableObservationTracking.Token?
    private var refreshTask: Task<Void, Never>?
    private var needsTextSettingsRefresh = false
    private var displayedContent: ContentIdentity?
    private var displayedSelection: Int?
    private var isSynchronizingScroll = false
    // A deleted span collapses to one modified boundary, so reverse mapping
    // cannot recover a viewport inside that span.
    private var scrollSource: EditorComparisonGeometry.Side = .modified
    private var needsDividerPosition = false
    private var pendingReferenceHorizontalOffset: CGFloat?
    private var dividerFraction: CGFloat = 0.5

    var comparisonDeliveryForTesting: PortableObservationTracking.Token? { comparisonObservation }
    var comparisonConfigurationDeliveryForTesting: PortableObservationTracking.Token? { configurationObservation }

    func waitForPendingComparisonRefreshForTesting() async {
        while let task = refreshTask { await task.value }
    }

    private struct ContentIdentity: Equatable {
        let originalRevision: Int
        let modifiedRevision: Int
        let isReady: Bool
        let presentation: SyntaxEditorComparisonModel.Presentation
    }

    /// Creates a comparison view with an app-owned model.
    public init(model: SyntaxEditorComparisonModel) {
        self.model = model
        let modifiedEditor = SyntaxEditorView(model: model.modified)
        let originalEditor = SyntaxEditorView(model: model.original)
        self.modifiedEditor = modifiedEditor
        self.originalEditor = originalEditor
        modifiedLayout = SyntaxEditorComparisonTextLayout(editor: modifiedEditor, side: .modified)
        originalLayout = SyntaxEditorComparisonTextLayout(editor: originalEditor, side: .original)
        super.init(frame: .zero)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.arrangesAllSubviews = false
        splitView.autoresizingMask = [.width, .height]
        addSubview(splitView)
        splitView.addArrangedSubview(modifiedEditor)
        splitView.addSubview(originalEditor)
        originalEditor.isHidden = true
        modifiedLayout.comparison = self
        originalLayout.comparison = self
        originalEditor.didUpdateSyntaxRendering = { [weak self] in
            self?.scheduleRefresh(textSettingsChanged: true)
        }

        for editor in [modifiedEditor, originalEditor] {
            editor.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: editor.contentView
            )
        }
        refreshComparison()
        startObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTask?.cancel()
    }

    /// Switches the view and both editors to another comparison model.
    ///
    /// Passing the current instance has no effect. Rebinding an editor to a
    /// different document clears its undo history, as with `SyntaxEditorView`.
    public func update(model nextModel: SyntaxEditorComparisonModel) {
        guard model !== nextModel else { return }
        comparisonObservation?.cancel()
        configurationObservation?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        scrollSource = .modified
        moveDeletedTextFocus(to: modifiedEditor.textView)
        modifiedLayout.update(changes: [], presentation: .changeMarkers, selectedChangeIndex: nil)
        originalLayout.update(changes: [], presentation: .changeMarkers, selectedChangeIndex: nil)
        model = nextModel
        modifiedEditor.update(model: nextModel.modified)
        originalEditor.update(model: nextModel.original)
        displayedContent = nil
        displayedSelection = nil
        needsTextSettingsRefresh = true
        refreshComparison()
        startObservation()
    }

    public override func layout() {
        super.layout()
        let wasSynchronizing = isSynchronizingScroll
        isSynchronizingScroll = true
        defer { isSynchronizingScroll = wasSynchronizing }
        if needsDividerPosition, splitView.bounds.width > 0 {
            needsDividerPosition = false
            splitView.adjustSubviews()
            splitView.setPosition(
                max(0, splitView.bounds.width - splitView.dividerThickness) * dividerFraction,
                ofDividerAt: 0
            )
        }
        modifiedEditor.layoutSubtreeIfNeeded()
        originalEditor.layoutSubtreeIfNeeded()
        modifiedLayout.refreshTextSettings()
        originalLayout.refreshTextSettings()
        if let offset = pendingReferenceHorizontalOffset, originalEditor.contentView.bounds.width > 0 {
            pendingReferenceHorizontalOffset = nil
            let clip = originalEditor.contentView
            var bounds = clip.bounds
            bounds.origin.x = offset - clip.contentInsets.left
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            originalEditor.reflectScrolledClipView(clip)
        }
        if model.presentation == .sideBySide {
            synchronizeScroll(from: scrollSource)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleRefresh(textSettingsChanged: true)
    }

    func referenceAttributedString(in range: NSRange) -> NSAttributedString {
        let source = model.original.text as NSString
        let range = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: source.length)
        let result = NSMutableAttributedString(
            string: source.substring(with: range),
            attributes: originalEditor.baseAttributes()
        )
        let runs = originalEditor.textSystem.styleStore.resolveVisibleRuns(in: range)
        for run in runs.colorRuns {
            let clipped = NSIntersectionRange(run.range, range)
            guard clipped.length > 0 else { continue }
            result.addAttribute(
                .foregroundColor,
                value: run.color,
                range: NSRange(location: clipped.location - range.location, length: clipped.length)
            )
        }
        for run in runs.fontRuns {
            let clipped = NSIntersectionRange(run.range, range)
            guard clipped.length > 0 else { continue }
            result.addAttribute(
                .font,
                value: run.font,
                range: NSRange(location: clipped.location - range.location, length: clipped.length)
            )
        }
        return result
    }

    /// Find in a deleted block searches the entire reference document. This
    /// user-invoked action reveals the reference pane without rebinding either editor.
    func findInOriginal(_ sender: Any?) {
        model.presentation = .sideBySide
        refreshComparison()
        layoutSubtreeIfNeeded()
        unsafe window?.makeFirstResponder(originalEditor.textView)
        originalEditor.textView.performTextFinderAction(sender)
    }

    private func startObservation() {
        let model = model
        comparisonObservation = withPortableContinuousObservation { [weak self, model] _ in
            _ = model.original.textRevision
            _ = model.original.selectedRange
            _ = model.modified.textRevision
            _ = model.changes
            _ = model.presentation
            _ = model.selectedChangeIndex
            self?.scheduleRefresh()
        }
        configurationObservation = withPortableContinuousObservation { [weak self, model] _ in
            _ = model.modified.language
            _ = model.modified.theme
            _ = model.modified.fontSizeDelta
            _ = model.modified.lineWrappingEnabled
            _ = model.modified.drawsBackground
            self?.scheduleRefresh(textSettingsChanged: true)
        }
    }

    private func scheduleRefresh(textSettingsChanged: Bool = false) {
        needsTextSettingsRefresh = needsTextSettingsRefresh || textSettingsChanged
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.refreshComparison()
        }
    }

    private func refreshComparison() {
        let changes = model.changes
        let identity = ContentIdentity(
            originalRevision: model.original.textRevision,
            modifiedRevision: model.modified.textRevision,
            isReady: changes != nil,
            presentation: model.presentation
        )
        let selection = model.selectedChangeIndex
        let contentChanged = displayedContent != identity
        let selectionChanged = displayedSelection != selection
        let showsReference = identity.presentation == .sideBySide
        let referenceVisibilityChanged = originalEditor.isHidden == showsReference
        isSynchronizingScroll = true
        defer { isSynchronizingScroll = false }

        if referenceVisibilityChanged {
            setReferenceVisible(showsReference)
        }
        if contentChanged {
            moveDeletedTextFocus(to: showsReference ? originalEditor.textView : modifiedEditor.textView)
            modifiedLayout.update(
                changes: changes ?? [],
                presentation: identity.presentation,
                selectedChangeIndex: selection
            )
            originalLayout.update(
                changes: changes ?? [],
                presentation: identity.presentation,
                selectedChangeIndex: selection
            )
            displayedContent = identity
        } else if selectionChanged {
            modifiedLayout.updateSelectedChange(selection)
            originalLayout.updateSelectedChange(selection)
        }
        if needsTextSettingsRefresh {
            needsTextSettingsRefresh = false
            modifiedLayout.refreshTextSettings()
            originalLayout.refreshTextSettings()
        }
        displayedSelection = selection
        modifiedLayout.updateReferenceSelection()
        if selectionChanged, let selection {
            modifiedLayout.revealChange(at: selection)
            if showsReference {
                originalLayout.revealChange(at: selection)
            }
        } else if showsReference, referenceVisibilityChanged || contentChanged {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func moveDeletedTextFocus(to textView: SyntaxEditorTextInputView) {
        guard let active = unsafe window?.firstResponder as? SyntaxEditorComparisonDeletedTextView,
              active.isDescendant(of: modifiedEditor) else { return }
        unsafe window?.makeFirstResponder(textView)
    }

    private func setReferenceVisible(_ isVisible: Bool) {
        if isVisible {
            let clip = originalEditor.contentView
            pendingReferenceHorizontalOffset = clip.bounds.minX + clip.contentInsets.left
            originalEditor.isHidden = false
            splitView.addArrangedSubview(originalEditor)
            needsDividerPosition = true
            needsLayout = true
        } else {
            scrollSource = .modified
            if splitView.bounds.width > splitView.dividerThickness {
                dividerFraction = modifiedEditor.frame.width
                    / (splitView.bounds.width - splitView.dividerThickness)
            }
            if let firstResponder = unsafe window?.firstResponder as? NSView,
               firstResponder.isDescendant(of: originalEditor) {
                unsafe window?.makeFirstResponder(modifiedEditor.textView)
            }
            splitView.removeArrangedSubview(originalEditor)
            originalEditor.isHidden = true
            needsDividerPosition = false
            pendingReferenceHorizontalOffset = nil
        }
        splitView.adjustSubviews()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard model.presentation == .sideBySide,
              !isSynchronizingScroll,
              let clipView = notification.object as? NSClipView
        else { return }
        let side: EditorComparisonGeometry.Side
        if clipView === modifiedEditor.contentView {
            side = .modified
        } else if clipView === originalEditor.contentView {
            side = .original
        } else {
            return
        }
        scrollSource = side
        isSynchronizingScroll = true
        defer { isSynchronizingScroll = false }
        synchronizeScroll(from: side)
    }

    private func synchronizeScroll(from side: EditorComparisonGeometry.Side) {
        guard let changes = model.changes else { return }
        let source = side == .modified ? modifiedEditor : originalEditor
        let destination = side == .modified ? originalEditor : modifiedEditor
        let sourceLayout = side == .modified ? modifiedLayout : originalLayout
        let destinationLayout = side == .modified ? originalLayout : modifiedLayout
        let sourceY = source.textView.convert(source.contentView.bounds.origin, from: source.contentView).y
        guard let logicalLine = sourceLayout.logicalPosition(atY: sourceY) else { return }

        let destinationLine = EditorComparisonGeometry.counterpartLine(logicalLine, from: side, changes: changes)
        let destinationIndex = min(max(0, Int(floor(destinationLine))), destinationLayout.lineOffsets.lineCount - 1)
        if destinationLayout.lineFrame(destinationIndex) == nil {
            relocateViewport(to: destinationIndex, in: destination, layout: destinationLayout)
        }

        let destinationY: CGFloat
        if let change = changes.first(where: {
            let lines = side == .modified ? $0.modifiedLines : $0.originalLines
            return logicalLine >= CGFloat(lines.lowerBound) && logicalLine < CGFloat(lines.upperBound)
        }) {
            let sourceRange = side == .modified ? change.modifiedRange : change.originalRange
            let destinationRange = side == .modified ? change.originalRange : change.modifiedRange
            if let sourceSpan = verticalSpan(of: sourceRange, in: sourceLayout),
               let destinationSpan = verticalSpan(of: destinationRange, in: destinationLayout) {
                let progress = sourceSpan.upperBound > sourceSpan.lowerBound
                    ? min(max((sourceY - sourceSpan.lowerBound) / (sourceSpan.upperBound - sourceSpan.lowerBound), 0), 1)
                    : 0
                destinationY = destinationSpan.lowerBound
                    + progress * (destinationSpan.upperBound - destinationSpan.lowerBound)
            } else {
                guard let lineY = lineY(at: destinationLine, in: destinationLayout) else { return }
                destinationY = lineY
            }
        } else {
            guard let lineY = lineY(at: destinationLine, in: destinationLayout) else { return }
            destinationY = lineY
        }
        scroll(destination, toTextY: destinationY)
    }

    private func verticalSpan(
        of range: NSRange,
        in layout: SyntaxEditorComparisonTextLayout
    ) -> ClosedRange<CGFloat>? {
        // Endpoint fragments use TextKit's current document coordinates; the
        // offscreen interior can remain estimated without laying out a whole hunk.
        guard let frame = layout.frame(forUTF16Range: range) else { return nil }
        return frame.minY...(range.length == 0 ? frame.minY : frame.maxY)
    }

    private func lineY(at position: CGFloat, in layout: SyntaxEditorComparisonTextLayout) -> CGFloat? {
        let index = min(max(0, Int(floor(position))), layout.lineOffsets.lineCount - 1)
        guard let frame = layout.lineFrame(index) else { return nil }
        let fraction = min(max(position - CGFloat(index), 0), 1)
        return frame.minY + fraction * frame.height
    }

    private func relocateViewport(
        to line: Int,
        in editor: SyntaxEditorView,
        layout: SyntaxEditorComparisonTextLayout
    ) {
        let offset = layout.lineOffsets.lineStartOffset(at: line)
        guard let location = editor.textView.textLocation(forUTF16Offset: offset) else { return }
        let anchor = editor.layoutManager.textViewportLayoutController.relocateViewport(to: location)
        scroll(editor, toTextY: anchor)
        editor.textView.layoutVisibleViewport()
    }

    private func scroll(_ editor: SyntaxEditorView, toTextY y: CGFloat) {
        let clipView = editor.contentView
        var proposed = clipView.bounds
        proposed.origin.y = clipView.convert(NSPoint(x: 0, y: y), from: editor.textView).y
        let constrained = clipView.constrainBoundsRect(proposed)
        guard abs(constrained.minY - clipView.bounds.minY) > 0.25 else { return }
        clipView.scroll(to: constrained.origin)
        editor.reflectScrolledClipView(clipView)
    }
}
#endif
