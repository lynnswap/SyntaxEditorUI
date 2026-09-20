#if canImport(UIKit)
import SyntaxEditorCore
import UIKit

/// A UIKit view controller whose root view displays a document comparison.
@MainActor
public final class SyntaxEditorComparisonViewController: UIViewController {
    /// The comparison currently displayed by the controller.
    public private(set) var model: SyntaxEditorComparisonModel

    /// The comparison view installed as the controller's root view.
    public let editorView: SyntaxEditorComparisonView

    /// Creates a controller and its comparison view for the supplied model.
    public init(model: SyntaxEditorComparisonModel) {
        self.model = model
        editorView = SyntaxEditorComparisonView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = editorView
    }

    /// Switches the controller and its comparison view to another model.
    ///
    /// Passing the current instance has no effect. Rebinding the modified editor
    /// to another document clears its undo history.
    public func update(model nextModel: SyntaxEditorComparisonModel) {
        guard model !== nextModel else { return }
        model = nextModel
        editorView.update(model: nextModel)
    }
}
#endif
