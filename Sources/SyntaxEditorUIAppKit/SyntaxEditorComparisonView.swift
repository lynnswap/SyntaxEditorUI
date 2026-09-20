#if canImport(AppKit)
import AppKit
import ObservationBridge
import SyntaxEditorCore

@MainActor
final class SyntaxEditorComparisonView: NSView {
    private(set) var model: SyntaxEditorComparisonModel
    let modifiedEditor: SyntaxEditorView
    let originalEditor: SyntaxEditorView
    let modifiedLayout: SyntaxEditorComparisonTextLayout
    let originalLayout: SyntaxEditorComparisonTextLayout
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

    init(model: SyntaxEditorComparisonModel) {
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

    override func layout() {
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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
        if originalEditor.isHidden == showsReference {
            setReferenceVisible(showsReference)
        }
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
            if let active = unsafe window?.firstResponder as? NSView,
               active.isDescendant(of: originalEditor) {
                unsafe window?.makeFirstResponder(modifiedEditor.textView)
            }
            splitView.removeArrangedSubview(originalEditor)
            originalEditor.isHidden = true
            needsDividerPosition = false
        }
        splitView.adjustSubviews()
    }
}
#endif
