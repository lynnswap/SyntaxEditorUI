#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorCore
import UIKit

@MainActor
final class SyntaxEditorComparisonView: UIView {
    private(set) var model: SyntaxEditorComparisonModel
    let modifiedEditor: SyntaxEditorView
    let originalEditor: SyntaxEditorView
    let modifiedLayout: SyntaxEditorComparisonTextLayout
    let originalLayout: SyntaxEditorComparisonTextLayout
    private let divider = UIView()
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

    init(model: SyntaxEditorComparisonModel) {
        self.model = model
        let modifiedEditor = SyntaxEditorView(model: model.modified)
        let originalEditor = SyntaxEditorView(model: model.original)
        self.modifiedEditor = modifiedEditor
        self.originalEditor = originalEditor
        modifiedLayout = SyntaxEditorComparisonTextLayout(editor: modifiedEditor, side: .modified)
        originalLayout = SyntaxEditorComparisonTextLayout(editor: originalEditor, side: .original)
        super.init(frame: .zero)

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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { refreshTask?.cancel() }

    func update(model nextModel: SyntaxEditorComparisonModel) {
        guard model !== nextModel else { return }
        comparisonObservation?.cancel()
        configurationObservation?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
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

    override func layoutSubviews() {
        super.layoutSubviews()
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
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        scheduleRefresh(appearanceChanged: true)
    }

    private func startObservation() {
        let model = model
        comparisonObservation = withPortableContinuousObservation { [weak self, model] _ in
            _ = model.original.textRevision
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
        if originalEditor.isHidden == showsReference { setReferenceVisible(showsReference) }
        if displayedContent != identity {
            modifiedLayout.update(changes: changes, presentation: identity.presentation, selectedChangeIndex: selection)
            originalLayout.update(changes: changes, presentation: identity.presentation, selectedChangeIndex: selection)
            displayedContent = identity
        } else if displayedSelection != selection || needsAppearanceRefresh {
            modifiedLayout.updateSelectedChange(selection)
            originalLayout.updateSelectedChange(selection)
        }
        displayedSelection = selection
        needsAppearanceRefresh = false
    }

    private func setReferenceVisible(_ isVisible: Bool) {
        if !isVisible, firstResponder(in: originalEditor) != nil {
            originalEditor.endEditing(true)
            modifiedEditor.becomeFirstResponder()
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
