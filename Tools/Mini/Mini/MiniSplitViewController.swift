import ObservationBridge
import SyntaxEditorUI

#if canImport(UIKit)
import UIKit

@MainActor
final class MiniSplitViewController: UISplitViewController {
    private let model: MiniEditorSession
    private let presetListViewController: MiniPresetListViewController
    private var modelObservation: PortableObservationTracking.Token?
    private var editorViewController: SyntaxEditorComparisonViewController?
    private var detailViewController: MiniComparisonViewController?

    init(model: MiniEditorSession) {
        self.model = model
        self.presetListViewController = MiniPresetListViewController(model: model)

        super.init(style: .doubleColumn)

        preferredSplitBehavior = .tile
        preferredDisplayMode = .oneBesideSecondary
        presentsWithGesture = true

        let sidebarNavigationController = UINavigationController(
            rootViewController: presetListViewController
        )
        setViewController(sidebarNavigationController, for: .primary)
        bindModel()
    }

    isolated deinit {
        modelObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func bindModel() {
        modelObservation?.cancel()
        modelObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }

            let comparisonModel = model.comparisonModel
            let title = model.currentPreset.title
            renderDetail(comparisonModel: comparisonModel, title: title)
        }
    }

    private func renderDetail(comparisonModel: SyntaxEditorComparisonModel, title: String) {
        if let editorViewController {
            editorViewController.update(model: comparisonModel)
            detailViewController?.title = title
            return
        }

        let editorViewController = SyntaxEditorComparisonViewController(
            model: comparisonModel
        )
        let detailViewController = MiniComparisonViewController(
            model: model,
            editorViewController: editorViewController
        )
        detailViewController.title = title
        detailViewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil,
            menu: UIMenu(children: [makeOverflowItems()])
        )
        detailViewController.navigationItem.rightBarButtonItem?.accessibilityLabel = "Editor Options"

        let navigationController = UINavigationController(rootViewController: detailViewController)
        self.editorViewController = editorViewController
        self.detailViewController = detailViewController
        setViewController(navigationController, for: .secondary)
        if isCollapsed {
            show(.secondary)
        }
    }

    private func makeOverflowItems() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion([])
                    return
                }

                let lineWrappingEnabled = self.model.editorModel.lineWrappingEnabled
                let selectedThemePreset = self.model.selectedThemePreset
                let lineWrappingAction = UIAction(
                    title: "Line Wrapping",
                    image: UIImage(systemName: "text.alignleft")
                ) { [weak self] _ in
                    self?.toggleLineWrapping()
                }
                lineWrappingAction.state = lineWrappingEnabled ? .on : .off

                let themeActions = SyntaxEditorTheme.Preset.allCases.map { preset in
                    let action = UIAction(title: preset.displayName) { [weak self] _ in
                        self?.model.selectedThemePreset = preset
                    }
                    action.state = selectedThemePreset == preset ? .on : .off
                    return action
                }
                let themeMenu = UIMenu(
                    title: "Theme",
                    image: UIImage(systemName: "paintpalette"),
                    children: themeActions
                )

                completion([themeMenu, lineWrappingAction])
            }
        }
    }

    private func toggleLineWrapping() {
        model.editorModel.lineWrappingEnabled.toggle()
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
final class MiniSplitViewController: NSSplitViewController {
    private let model: MiniEditorSession
    private let presetListViewController: MiniPresetListViewController
    private var modelObservation: PortableObservationTracking.Token?
    private var editorViewController: SyntaxEditorComparisonViewController?
    private var detailSplitViewItem: NSSplitViewItem?
    private var detailViewController: MiniComparisonViewController?

    init(model: MiniEditorSession) {
        self.model = model
        self.presetListViewController = MiniPresetListViewController(model: model)

        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit {
        modelObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureSplitItems()
        bindModel()
    }

    private func configureSplitItems() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: presetListViewController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
    }

    private func bindModel() {
        modelObservation?.cancel()
        modelObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }

            let comparisonModel = model.comparisonModel
            let title = model.currentPreset.title
            renderDetail(comparisonModel: comparisonModel, title: title)
        }
    }

    private func renderDetail(comparisonModel: SyntaxEditorComparisonModel, title: String) {
        if let editorViewController {
            editorViewController.update(model: comparisonModel)
            detailViewController?.title = title
            return
        }

        if let detailSplitViewItem {
            removeSplitViewItem(detailSplitViewItem)
        }

        let editorViewController = SyntaxEditorComparisonViewController(
            model: comparisonModel
        )
        editorViewController.title = title
        editorViewController.editorView.modifiedEditor.automaticallyAdjustsContentInsets = true

        let detailViewController = MiniComparisonViewController(model: model, editorViewController: editorViewController)
        detailViewController.title = title
        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 320
        if #available(macOS 26.0, *) {
            detailItem.automaticallyAdjustsSafeAreaInsets = true
        }
        addSplitViewItem(detailItem)

        self.editorViewController = editorViewController
        self.detailSplitViewItem = detailItem
        self.detailViewController = detailViewController
    }
}
#endif
