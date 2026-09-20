#if canImport(AppKit)
import AppKit
import ObservationBridge
import SyntaxEditorCore

/// An AppKit comparison of a modified document and its read-only reference.
///
/// The modified editor remains installed across presentation changes, preserving
/// selection, marked text, and undo history. The reference follows its language,
/// theme, font size, and wrapping settings. Find from inline deleted text opens
/// the full reference pane.
@MainActor
public final class SyntaxEditorComparisonView: NSView {
    /// The comparison displayed by this view.
    public private(set) var model: SyntaxEditorComparisonModel
    /// The modified document's editor, available for native configuration.
    public let modifiedEditor: SyntaxEditorView
    let originalEditor: SyntaxEditorView
    let modifiedLayout: SyntaxEditorComparisonTextLayout
    let originalLayout: SyntaxEditorComparisonTextLayout
    let inlineLayout: SyntaxEditorInlineComparisonLayout
    private let splitView = NSSplitView()
    private var comparisonObservation: PortableObservationTracking.Token?
    private var configurationObservation: PortableObservationTracking.Token?
    private var refreshTask: Task<Void, Never>?
    private var needsAppearanceRefresh = false
    private var displayedContent: ContentIdentity?
    private var displayedSelection: Int?
    private var needsDividerPosition = false
    private var dividerFraction: CGFloat = 0.5
    private var refreshWaitersForTesting: [CheckedContinuation<Void, Never>] = []

    private struct ContentIdentity: Equatable {
        let originalRevision: Int
        let modifiedRevision: Int
        let isReady: Bool
        let presentation: SyntaxEditorComparisonModel.Presentation
    }

    private var currentContentIdentity: ContentIdentity {
        ContentIdentity(
            originalRevision: model.original.textRevision,
            modifiedRevision: model.modified.textRevision,
            isReady: model.changes != nil,
            presentation: model.presentation
        )
    }

    var comparisonDeliveryForTesting: PortableObservationTracking.Token? { comparisonObservation }
    var comparisonConfigurationDeliveryForTesting: PortableObservationTracking.Token? { configurationObservation }
    var displayedPresentationForTesting: SyntaxEditorComparisonModel.Presentation? { displayedContent?.presentation }

    func waitForPendingComparisonRefreshForTesting(until isReady: () -> Bool = { true }) async {
        while refreshTask != nil || displayedContent != currentContentIdentity
            || displayedSelection != model.selectedChangeIndex || !isReady() {
            if let task = refreshTask {
                await task.value
            } else {
                await withCheckedContinuation { refreshWaitersForTesting.append($0) }
            }
        }
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
        let inlineLayout = SyntaxEditorInlineComparisonLayout(editor: modifiedEditor, originalEditor: originalEditor)
        self.inlineLayout = inlineLayout
        super.init(frame: .zero)
        modifiedLayout.comparison = self
        originalLayout.comparison = self
        modifiedEditor.textView.inlineComparisonLayout = inlineLayout
        inlineLayout.onFind = { [weak self] sender in self?.findInOriginal(sender) }
        originalEditor.didUpdateSyntaxRendering = { [weak inlineLayout, weak modifiedEditor] ranges in
            if inlineLayout?.invalidateReferenceStyles(in: ranges) == true {
                modifiedEditor?.textView.needsLayout = true
            }
        }
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.arrangesAllSubviews = false
        splitView.autoresizingMask = [.width, .height]
        addSubview(splitView)
        splitView.addArrangedSubview(modifiedEditor)
        splitView.addSubview(originalEditor)
        originalEditor.isHidden = true
        refreshComparison()
        startObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { refreshTask?.cancel() }

    /// Switches the view and both editors to another comparison model.
    ///
    /// Passing the current instance has no effect. Rebinding the modified editor
    /// to another document clears its undo history.
    public func update(model nextModel: SyntaxEditorComparisonModel) {
        guard model !== nextModel else { return }
        comparisonObservation?.cancel()
        configurationObservation?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        // Detach ranges from the old texts before either editor changes documents.
        inlineLayout.update(changes: [])
        modifiedEditor.textView.invalidateInlineComparisonLayout()
        modifiedLayout.update(changes: [], presentation: .changeMarkers, selectedChangeIndex: nil)
        originalLayout.update(changes: [], presentation: .changeMarkers, selectedChangeIndex: nil)
        model = nextModel
        modifiedEditor.update(model: nextModel.modified)
        originalEditor.update(model: nextModel.original)
        displayedContent = nil
        displayedSelection = nil
        needsAppearanceRefresh = true
        refreshComparison()
        startObservation()
    }

    public override func layout() {
        super.layout()
        if needsDividerPosition, splitView.bounds.width > 0 {
            needsDividerPosition = false
            splitView.adjustSubviews()
            splitView.setPosition(
                max(0, splitView.bounds.width - splitView.dividerThickness) * dividerFraction,
                ofDividerAt: 0
            )
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleRefresh(appearanceChanged: true)
    }

    func findInOriginal(_ sender: Any?) {
        model.presentation = .sideBySide
        refreshComparison()
        layoutSubtreeIfNeeded()
        originalEditor.selectedRange = model.original.selectedRange
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
            self?.scheduleRefresh(appearanceChanged: true)
        }
    }

    private func scheduleRefresh(appearanceChanged: Bool = false) {
        needsAppearanceRefresh = needsAppearanceRefresh || appearanceChanged
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.refreshComparison()
        }
        let waiters = refreshWaitersForTesting
        refreshWaitersForTesting.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func refreshComparison() {
        let identity = currentContentIdentity
        let changes = model.changes ?? []
        let selection = model.selectedChangeIndex
        let showsReference = identity.presentation == .sideBySide
        if originalEditor.isHidden == showsReference {
            setReferenceVisible(showsReference)
        }
        if displayedContent != identity {
            inlineLayout.update(changes: identity.presentation == .inline ? changes : [])
            inlineLayout.updateSelectedChange(selection)
            modifiedEditor.textView.invalidateInlineComparisonLayout()
            modifiedLayout.update(changes: changes, presentation: identity.presentation, selectedChangeIndex: selection)
            originalLayout.update(changes: changes, presentation: identity.presentation, selectedChangeIndex: selection)
            displayedContent = identity
        } else if displayedSelection != selection || needsAppearanceRefresh {
            inlineLayout.updateSelectedChange(selection)
            modifiedLayout.updateSelectedChange(selection)
            originalLayout.updateSelectedChange(selection)
        }
        inlineLayout.updateReferenceSelection(model.original.selectedRange)
        displayedSelection = selection
        needsAppearanceRefresh = false
    }

    private func setReferenceVisible(_ isVisible: Bool) {
        if isVisible {
            originalEditor.isHidden = false
            splitView.addArrangedSubview(originalEditor)
            needsDividerPosition = true
            needsLayout = true
        } else {
            if splitView.bounds.width > splitView.dividerThickness {
                dividerFraction = modifiedEditor.frame.width
                    / (splitView.bounds.width - splitView.dividerThickness)
            }
            let active = unsafe window?.firstResponder as? NSView
            let hadFocus = originalEditor.isFindBarVisible || active?.isDescendant(of: originalEditor) == true
            originalEditor.textView.textFinder.performAction(.hideFindInterface)
            if hadFocus { unsafe window?.makeFirstResponder(modifiedEditor.textView) }
            splitView.removeArrangedSubview(originalEditor)
            originalEditor.isHidden = true
            needsDividerPosition = false
        }
        splitView.adjustSubviews()
    }
}
#endif
