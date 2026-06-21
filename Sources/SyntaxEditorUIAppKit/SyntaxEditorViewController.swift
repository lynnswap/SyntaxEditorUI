#if canImport(AppKit)
  import AppKit
  import ObservationBridge
  import SyntaxEditorCore
  import SyntaxEditorUICommon

  public final class SyntaxEditorViewController: NSViewController {
    public private(set) var model: SyntaxEditorModel
    public let editorView: SyntaxEditorView

    var textView: SyntaxEditorTextInputView {
      editorView.textView
    }

    public var scrollView: NSScrollView {
      editorView
    }

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

    public func update(model nextModel: SyntaxEditorModel) {
      guard model !== nextModel else { return }

      model = nextModel
      editorView.update(model: nextModel)
    }

    internal func synchronizeDocumentForTesting() {
      editorView.synchronizeDocumentForTesting()
    }

    public func textDidChange(_ notification: Notification) {
      editorView.textDidChange(notification)
    }

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
