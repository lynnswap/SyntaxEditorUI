#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorCore
import UIKit

/// A UIKit comparison of a modified document and its read-only reference.
///
/// The modified editor remains installed across presentation changes, preserving
/// selection, marked text, and undo history. The reference follows its language,
/// theme, font size, and wrapping settings. Find from inline deleted text opens
/// the full reference pane.
@MainActor
public final class SyntaxEditorComparisonView: UIView {
    /// The comparison displayed by this view.
    public private(set) var model: SyntaxEditorComparisonModel
    /// The modified document's editor, available for native configuration.
    public let modifiedEditor: SyntaxEditorView
    let originalEditor: SyntaxEditorView
    let modifiedLayout: SyntaxEditorComparisonTextLayout
    let originalLayout: SyntaxEditorComparisonTextLayout
    let inlineLayout: SyntaxEditorInlineComparisonLayout
    private let divider = UIView()
    lazy var viewport = SyntaxEditorComparisonViewport(comparison: self)
    private var comparisonObservation: PortableObservationTracking.Token?
    private var configurationObservation: PortableObservationTracking.Token?
    private var refreshTask: Task<Void, Never>?
    private var needsAppearanceRefresh = false
    private var displayedContent: ContentIdentity?
    private var displayedSelection: Int?
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

    var hasUnappliedComparisonContent: Bool { displayedContent != currentContentIdentity }

    var comparisonDeliveryForTesting: PortableObservationTracking.Token? { comparisonObservation }
    var comparisonConfigurationDeliveryForTesting: PortableObservationTracking.Token? { configurationObservation }
    var displayedPresentation: SyntaxEditorComparisonModel.Presentation { displayedContent?.presentation ?? model.presentation }
    var displayedPresentationForTesting: SyntaxEditorComparisonModel.Presentation { displayedPresentation }

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
        modifiedEditor.inlineComparisonLayout = inlineLayout
        modifiedLayout.comparison = self
        originalLayout.comparison = self
        inlineLayout.onFind = { [weak self] action, sender in self?.findInOriginal(action, sender: sender) }
        originalEditor.didUpdateSyntaxRendering = { [weak inlineLayout, weak modifiedEditor] ranges in
            if inlineLayout?.invalidateReferenceStyles(in: ranges) == true { modifiedEditor?.setNeedsTextLayout() }
        }

        addSubview(modifiedLayout.rulerView)
        addSubview(modifiedEditor)
        addSubview(divider)
        addSubview(originalLayout.rulerView)
        addSubview(originalEditor)
        divider.backgroundColor = .separator
        divider.isUserInteractionEnabled = false
        divider.isHidden = true
        originalEditor.isHidden = true
        originalLayout.rulerView.isHidden = true
        modifiedEditor.didChangeComparisonViewport = { [weak layout = modifiedLayout] in layout?.layoutDidComplete() }
        originalEditor.didChangeComparisonViewport = { [weak layout = originalLayout] in layout?.layoutDidComplete() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: SyntaxEditorComparisonView, _: UITraitCollection) in
            view.scheduleRefresh(appearanceChanged: true)
        }
        refreshComparison()
        startObservation()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { refreshTask?.cancel() }

    /// Switches the view and both editors to another comparison model.
    ///
    /// Passing the current instance has no effect. Rebinding the modified editor
    /// to another document clears its undo history.
    public func update(model nextModel: SyntaxEditorComparisonModel) {
        guard model !== nextModel else { return }
        viewport.performUpdate {
            viewport.reset()
            comparisonObservation?.cancel()
            configurationObservation?.cancel()
            refreshTask?.cancel()
            refreshTask = nil
            inlineLayout.update(changes: [])
            modifiedEditor.invalidateInlineComparisonLayout()
            // Detach ranges from the old texts before either editor changes documents.
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
        viewport.layoutDidComplete()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        viewport.performUpdate {
            let showsReference = !originalEditor.isHidden
            let dividerWidth = showsReference ? 1 / max(1, traitCollection.displayScale) : 0
            let paneWidth = showsReference ? max(0, bounds.width - dividerWidth) / 2 : bounds.width
            modifiedLayout.rulerView.frame = CGRect(
                x: bounds.minX, y: bounds.minY,
                width: min(modifiedLayout.rulerWidth, paneWidth), height: bounds.height
            )
            modifiedEditor.frame = CGRect(
                x: modifiedLayout.rulerView.frame.maxX, y: bounds.minY,
                width: max(0, paneWidth - modifiedLayout.rulerWidth), height: bounds.height
            )
            if showsReference {
                divider.frame = CGRect(x: bounds.minX + paneWidth, y: bounds.minY, width: dividerWidth, height: bounds.height)
                originalLayout.rulerView.frame = CGRect(
                    x: divider.frame.maxX, y: bounds.minY,
                    width: min(originalLayout.rulerWidth, paneWidth), height: bounds.height
                )
                originalEditor.frame = CGRect(
                    x: originalLayout.rulerView.frame.maxX, y: bounds.minY,
                    width: max(0, paneWidth - originalLayout.rulerWidth), height: bounds.height
                )
            }
            modifiedEditor.layoutIfNeeded()
            if !originalEditor.isHidden { originalEditor.layoutIfNeeded() }
        }
        viewport.layoutDidComplete()
    }

    /// Orders the editors and visible reference deletions for accessibility.
    /// Set a custom list to override this order, or `nil` to restore it.
    public override var accessibilityElements: [Any]? {
        get {
            if let custom = super.accessibilityElements { return custom }
            var elements: [Any] = [modifiedLayout.rulerView, modifiedEditor]
            if originalEditor.isHidden {
                elements.append(contentsOf: inlineLayout.deletedViews.sorted { $0.key < $1.key }.map(\.value))
            } else {
                elements.append(contentsOf: [originalLayout.rulerView, originalEditor])
            }
            return elements
        }
        set { super.accessibilityElements = newValue }
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
        scheduleRefresh(appearanceChanged: true)
    }

    func findInOriginal(_ action: Selector, sender: Any?) {
        model.presentation = .sideBySide
        refreshComparison()
        layoutIfNeeded()
        originalEditor.selectedRange = model.original.selectedRange
        originalEditor.becomeFirstResponder()
        _ = unsafe originalEditor.perform(action, with: sender)
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
        let selectionChanged = selection != displayedSelection
        viewport.performUpdate(appliesComparison: true) {
            let showsReference = identity.presentation == .sideBySide
            if originalEditor.isHidden == showsReference { setReferenceVisible(showsReference) }
            if displayedContent != identity {
                inlineLayout.update(changes: identity.presentation == .inline ? changes : [])
                inlineLayout.updateSelectedChange(selection)
                modifiedEditor.invalidateInlineComparisonLayout()
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
            setNeedsLayout()
            layoutIfNeeded()
        }
        if selectionChanged { viewport.selectionDidChange(selection) }
        else { viewport.layoutDidComplete() }
    }

    private func setReferenceVisible(_ isVisible: Bool) {
        if !isVisible {
            let hadFocus = firstResponder(in: originalEditor) != nil || originalEditor.findInteraction?.isFindNavigatorVisible == true
            originalEditor.findInteraction?.dismissFindNavigator()
            if hadFocus {
                originalEditor.endEditing(true)
                modifiedEditor.becomeFirstResponder()
            }
        }
        originalEditor.isHidden = !isVisible
        originalLayout.rulerView.isHidden = !isVisible
        divider.isHidden = !isVisible
        setNeedsLayout()
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let active = firstResponder(in: child) { return active }
        }
        return nil
    }
}
#endif
