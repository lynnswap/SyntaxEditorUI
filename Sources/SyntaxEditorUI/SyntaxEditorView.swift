import SwiftUI

#if canImport(UIKit)
private struct SyntaxEditorViewContainer: UIViewControllerRepresentable {
    let model: SyntaxEditorModel

    func makeUIViewController(context: Context) -> SyntaxEditorViewController {
        SyntaxEditorViewController(model: model)
    }

    func updateUIViewController(_ uiViewController: SyntaxEditorViewController, context: Context) {
        // Model observation keeps the controller synchronized.
    }
}
#elseif canImport(AppKit)
private struct SyntaxEditorViewContainer: NSViewControllerRepresentable {
    let model: SyntaxEditorModel

    func makeNSViewController(context: Context) -> SyntaxEditorViewController {
        SyntaxEditorViewController(model: model)
    }

    func updateNSViewController(_ nsViewController: SyntaxEditorViewController, context: Context) {
        // Model observation keeps the controller synchronized.
    }
}
#endif

@MainActor
public struct SyntaxEditorView: View {
    let model: SyntaxEditorModel

    public init(model: SyntaxEditorModel) {
        self.model = model
    }

    public var body: some View {
        SyntaxEditorViewContainer(model: model)
            .id(ObjectIdentifier(model))
    }
}
