import SwiftUI
import SyntaxEditorCore

#if canImport(UIKit)
import SyntaxEditorUIUIKit
#elseif canImport(AppKit)
import SyntaxEditorUIAppKit
#endif

#if canImport(UIKit)
private struct SyntaxEditorContainer: UIViewRepresentable {
    let model: SyntaxEditorModel

    func makeUIView(context: Context) -> SyntaxEditorView {
        SyntaxEditorView(model: model)
    }

    func updateUIView(_ uiView: SyntaxEditorView, context: Context) {
        uiView.update(model: model)
    }
}
#elseif canImport(AppKit)
private struct SyntaxEditorContainer: NSViewRepresentable {
    let model: SyntaxEditorModel

    func makeNSView(context: Context) -> SyntaxEditorView {
        SyntaxEditorView(model: model)
    }

    func updateNSView(_ nsView: SyntaxEditorView, context: Context) {
        nsView.update(model: model)
    }
}
#endif

/// A SwiftUI code editor backed by an app-owned model.
///
/// Await ``SyntaxEditorModel/prepare()`` during app setup before creating the view.
///
/// Keep the `SyntaxEditorModel` in persistent view state, such as `@State`, so
/// SwiftUI updates reuse the same document and editor settings. User edits and
/// selection changes update that model, and the editor observes model changes.
///
/// The view uses the UIKit editor on iOS, Mac Catalyst, and visionOS, and the
/// AppKit editor on macOS. Passing a different model instance switches the
/// document and clears the native editor's undo history.
@MainActor
public struct SyntaxEditor: View {
    private let model: SyntaxEditorModel

    /// Creates an editor that displays and edits the supplied model.
    ///
    /// - Parameter model: The model that owns the text, selection, and editor
    ///   settings. The app is responsible for loading and saving its text.
    public init(_ model: SyntaxEditorModel) {
        self.model = model
    }

    public var body: some View {
        SyntaxEditorContainer(model: model)
    }
}
