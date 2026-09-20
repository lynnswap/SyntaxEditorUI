import ObservationBridge

#if canImport(UIKit)
import UIKit

@MainActor
final class MiniPresetListViewController: UICollectionViewController {
    private let model: MiniEditorSession
    private var observation: PortableObservationTracking.Token?
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!

    init(model: MiniEditorSession) {
        self.model = model
        super.init(collectionViewLayout: Self.makeLayout())
    }

    isolated deinit {
        observation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Examples"
        collectionView.allowsMultipleSelection = false
        dataSource = makeDataSource()
        applySnapshot()
        bindModel()
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let rawPresetID = dataSource.itemIdentifier(for: indexPath),
              let presetID = MiniPreviewPreset.ID(rawValue: rawPresetID)
        else {
            return
        }
        model.selectPreset(presetID)
        if let splitViewController, splitViewController.isCollapsed {
            splitViewController.show(.secondary)
        }
    }

    private func bindModel() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }

            renderSelection(selectedPresetID: model.selectedPresetID)
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<String, String> {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            cell,
            _,
            rawPresetID in
            let presetID = MiniPreviewPreset.ID(rawValue: rawPresetID) ?? .javascript
            let preset = MiniPreviewPreset.preset(for: presetID) ?? .javascript
            var content = cell.defaultContentConfiguration()
            content.text = preset.title
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = preset.accessibilityIdentifier
        }

        return UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView,
            indexPath,
            presetID in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: presetID
            )
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections([Self.sectionIdentifier])
        snapshot.appendItems(
            MiniPreviewPreset.all.map { $0.id.rawValue },
            toSection: Self.sectionIdentifier
        )
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func renderSelection(selectedPresetID: MiniPreviewPreset.ID) {
        collectionView.indexPathsForSelectedItems?.forEach {
            collectionView.deselectItem(at: $0, animated: false)
        }

        guard let indexPath = dataSource.indexPath(for: selectedPresetID.rawValue) else {
            return
        }

        collectionView.selectItem(
            at: indexPath,
            animated: false,
            scrollPosition: []
        )
    }

    private static func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.showsSeparators = false
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private static let sectionIdentifier = "main"
}
#elseif canImport(AppKit)
import AppKit

@MainActor
final class MiniPresetListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: MiniEditorSession
    private var observation: PortableObservationTracking.Token?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(model: MiniEditorSession) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "Examples"
    }

    isolated deinit {
        observation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureHierarchy()
        configureTableView()
        tableView.reloadData()
        bindModel()
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureTableView() {
        let tableColumn = NSTableColumn(identifier: .presetColumn)
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowSizeStyle = .default
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        MiniPreviewPreset.all.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard MiniPreviewPreset.all.indices.contains(row) else { return nil }

        let preset = MiniPreviewPreset.all[row]
        let cell = tableView.makeView(withIdentifier: .presetCell, owner: self) as? NSTableCellView
            ?? makePresetCell()
        cell.textField?.stringValue = preset.title
        cell.setAccessibilityIdentifier(preset.accessibilityIdentifier)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        guard MiniPreviewPreset.all.indices.contains(selectedRow) else { return }
        model.selectPreset(MiniPreviewPreset.all[selectedRow].id)
    }

    private func bindModel() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }

            renderSelection(selectedPresetID: model.selectedPresetID)
        }
    }

    private func renderSelection(selectedPresetID: MiniPreviewPreset.ID) {
        guard let selectedIndex = MiniPreviewPreset.all.firstIndex(where: { $0.id == selectedPresetID }) else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    private func makePresetCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .presetCell

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .preferredFont(forTextStyle: .body)
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let presetColumn = NSUserInterfaceItemIdentifier("PresetColumn")
    static let presetCell = NSUserInterfaceItemIdentifier("PresetCell")
}
#endif
