#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  /// An AppKit view controller whose root view is a ``SyntaxEditorView-77bw3``.
  ///
  /// Use this controller on the main actor when integrating the editor through
  /// view-controller containment. The supplied model remains the document and
  /// configuration owner.
  public final class SyntaxEditorViewController: NSViewController {
    /// The model currently displayed by the controller's editor.
    ///
    /// Use ``update(model:)`` to switch both the controller and its editor to
    /// another model.
    public private(set) var model: SyntaxEditorModel

    /// The editor installed as the controller's root view.
    public let editorView: SyntaxEditorView

    var textView: SyntaxEditorTextInputView {
      editorView.textView
    }

    /// The editor exposed as an `NSScrollView` for scroll-view configuration.
    ///
    /// This property returns the same instance as ``editorView``.
    public var scrollView: NSScrollView {
      editorView
    }

    /// Creates a controller and its editor for the supplied model.
    ///
    /// - Parameter model: The model to display and update through user editing.
    public init(model: SyntaxEditorModel) {
      self.model = model
      self.editorView = SyntaxEditorView(model: model)

      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
      view = editorView
    }

    /// Switches the controller and its editor to another model instance.
    ///
    /// Passing the current instance has no effect. Switching models clears the
    /// editor's undo history; see ``SyntaxEditorView-77bw3/update(model:)``.
    ///
    /// - Parameter nextModel: The model to display and observe.
    public func update(model nextModel: SyntaxEditorModel) {
      guard model !== nextModel else { return }

      model = nextModel
      editorView.update(model: nextModel)
    }

    /// Forwards a native text-change notification to the editor.
    ///
    /// Use the model for app-driven edits. See ``SyntaxEditorView-77bw3/textDidChange(_:)``.
    ///
    /// - Parameter notification: The notification to forward.
    public func textDidChange(_ notification: Notification) {
      editorView.textDidChange(notification)
    }

    /// Forwards a native selection-change notification to the editor.
    ///
    /// Use the model for app-driven selection changes. See
    /// ``SyntaxEditorView-77bw3/textViewDidChangeSelection(_:)``.
    ///
    /// - Parameter notification: The notification to forward.
    public func textViewDidChangeSelection(_ notification: Notification) {
      editorView.textViewDidChangeSelection(notification)
    }

    func textView(
      _ textView: SyntaxEditorTextInputView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      editorView.textView(
        textView,
        shouldChangeTextIn: affectedCharRange,
        replacementString: replacementString
      )
    }

    func textView(_ textView: SyntaxEditorTextInputView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      editorView.textView(textView, doCommandBy: commandSelector)
    }
  }
#endif
