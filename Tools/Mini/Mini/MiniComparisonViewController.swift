import ObservationBridge
import SyntaxEditorUI

#if canImport(UIKit)
import UIKit

@MainActor
final class MiniComparisonViewController: UIViewController {
    private let model: MiniEditorSession
    private let editorViewController: SyntaxEditorComparisonViewController
    private let presentationControl = UISegmentedControl(items: MiniEditorSession.presentationTitles)
    private let statusLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let referenceButton = UIButton(type: .system)
    private var observation: PortableObservationTracking.Token?

    init(model: MiniEditorSession, editorViewController: SyntaxEditorComparisonViewController) {
        self.model = model
        self.editorViewController = editorViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { observation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        presentationControl.accessibilityIdentifier = "mini.comparison.presentation"
        presentationControl.addTarget(self, action: #selector(selectPresentation), for: .valueChanged)
        previousButton.configuration = .plain()
        previousButton.setTitle("Previous", for: .normal)
        previousButton.accessibilityLabel = "Previous Change"
        previousButton.accessibilityIdentifier = "mini.comparison.previous"
        previousButton.addTarget(self, action: #selector(previousChange), for: .touchUpInside)
        nextButton.configuration = .plain()
        nextButton.setTitle("Next", for: .normal)
        nextButton.accessibilityLabel = "Next Change"
        nextButton.accessibilityIdentifier = "mini.comparison.next"
        nextButton.addTarget(self, action: #selector(nextChange), for: .touchUpInside)
        referenceButton.configuration = .plain()
        referenceButton.setTitle("Reference", for: .normal)
        referenceButton.accessibilityIdentifier = "mini.comparison.reference"
        referenceButton.showsMenuAsPrimaryAction = true
        referenceButton.menu = UIMenu(children: [
            UIAction(title: "Use Current as Reference", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.model.useCurrentAsReference()
            },
            UIAction(title: "Restore Sample Reference", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
                self?.model.restoreSampleReference()
            },
        ])
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "mini.comparison.status"
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let displayRow = UIStackView(arrangedSubviews: [presentationControl, referenceButton])
        displayRow.spacing = 8
        displayRow.alignment = .center
        let navigationRow = UIStackView(arrangedSubviews: [previousButton, statusLabel, nextButton])
        navigationRow.spacing = 8
        navigationRow.alignment = .center
        let controls = UIStackView(arrangedSubviews: [displayRow, navigationRow])
        controls.axis = .vertical
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        addChild(editorViewController)
        let editorView = editorViewController.view!
        editorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorView)
        editorViewController.editorView.accessibilityIdentifier = "mini.comparison"
        editorViewController.editorView.modifiedEditor.accessibilityIdentifier = "mini.currentEditor"
        editorViewController.editorView.modifiedEditor.accessibilityLabel = "Current document"

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previousButton.widthAnchor.constraint(equalTo: nextButton.widthAnchor),
            controls.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 8),
            editorView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            editorView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        editorViewController.didMove(toParent: self)

        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            presentationControl.selectedSegmentIndex = model.presentationIndex
            statusLabel.text = model.comparisonStatus
            previousButton.isEnabled = model.canSelectPreviousChange
            nextButton.isEnabled = model.canSelectNextChange
        }
    }

    @objc private func selectPresentation() {
        model.presentationIndex = presentationControl.selectedSegmentIndex
    }

    @objc private func previousChange() { model.comparisonModel.selectPreviousChange() }
    @objc private func nextChange() { model.comparisonModel.selectNextChange() }
}
#elseif canImport(AppKit)
import AppKit

@MainActor
final class MiniComparisonViewController: NSViewController {
    private let model: MiniEditorSession
    private let editorViewController: SyntaxEditorComparisonViewController
    private let presentationControl = NSSegmentedControl(
        labels: MiniEditorSession.presentationTitles, trackingMode: .selectOne, target: nil, action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let referenceButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var observation: PortableObservationTracking.Token?

    init(model: MiniEditorSession, editorViewController: SyntaxEditorComparisonViewController) {
        self.model = model
        self.editorViewController = editorViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { observation?.cancel() }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentationControl.target = self
        presentationControl.action = #selector(selectPresentation)
        presentationControl.cell?.refusesFirstResponder = true
        presentationControl.setAccessibilityIdentifier("mini.comparison.presentation")
        previousButton.target = self
        previousButton.action = #selector(previousChange)
        previousButton.bezelStyle = .rounded
        previousButton.refusesFirstResponder = true
        previousButton.setAccessibilityLabel("Previous Change")
        previousButton.setAccessibilityIdentifier("mini.comparison.previous")
        nextButton.target = self
        nextButton.action = #selector(nextChange)
        nextButton.bezelStyle = .rounded
        nextButton.refusesFirstResponder = true
        nextButton.setAccessibilityLabel("Next Change")
        nextButton.setAccessibilityIdentifier("mini.comparison.next")
        referenceButton.addItems(withTitles: ["Reference", "Use Current as Reference", "Restore Sample Reference"])
        referenceButton.target = self
        referenceButton.action = #selector(changeReference)
        referenceButton.setAccessibilityIdentifier("mini.comparison.reference")
        statusLabel.alignment = .center
        statusLabel.setAccessibilityIdentifier("mini.comparison.status")
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let displayRow = NSStackView(views: [presentationControl, referenceButton])
        displayRow.orientation = .horizontal
        displayRow.spacing = 8
        displayRow.alignment = .centerY
        let navigationRow = NSStackView(views: [previousButton, statusLabel, nextButton])
        navigationRow.orientation = .horizontal
        navigationRow.spacing = 8
        navigationRow.alignment = .centerY
        let controls = NSStackView(views: [displayRow, navigationRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        addChild(editorViewController)
        let editorView = editorViewController.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorView)
        editorViewController.editorView.setAccessibilityIdentifier("mini.comparison")
        editorViewController.editorView.modifiedEditor.setAccessibilityIdentifier("mini.currentEditor")

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previousButton.widthAnchor.constraint(equalTo: nextButton.widthAnchor),
            controls.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 8),
            displayRow.widthAnchor.constraint(equalTo: controls.widthAnchor),
            navigationRow.widthAnchor.constraint(equalTo: controls.widthAnchor),
            editorView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            editorView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ])

        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            presentationControl.selectedSegment = model.presentationIndex
            statusLabel.stringValue = model.comparisonStatus
            previousButton.isEnabled = model.canSelectPreviousChange
            nextButton.isEnabled = model.canSelectNextChange
        }
    }

    @objc private func selectPresentation() {
        model.presentationIndex = presentationControl.selectedSegment
    }

    @objc private func previousChange() { model.comparisonModel.selectPreviousChange() }
    @objc private func nextChange() { model.comparisonModel.selectNextChange() }

    @objc private func changeReference() {
        switch referenceButton.indexOfSelectedItem {
        case 1: model.useCurrentAsReference()
        case 2: model.restoreSampleReference()
        default: break
        }
    }
}
#endif
