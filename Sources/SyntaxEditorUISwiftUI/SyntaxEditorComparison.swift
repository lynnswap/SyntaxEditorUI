import SwiftUI
import SyntaxEditorCore

#if canImport(UIKit)
import SyntaxEditorUIUIKit
#elseif canImport(AppKit)
import SyntaxEditorUIAppKit
#endif

#if canImport(UIKit)
private struct SyntaxEditorComparisonContainer: UIViewRepresentable {
    let model: SyntaxEditorComparisonModel

    func makeUIView(context: Context) -> SyntaxEditorComparisonView {
        SyntaxEditorComparisonView(model: model)
    }

    func updateUIView(_ uiView: SyntaxEditorComparisonView, context: Context) {
        uiView.update(model: model)
    }
}
#elseif canImport(AppKit)
private struct SyntaxEditorComparisonContainer: NSViewRepresentable {
    let model: SyntaxEditorComparisonModel

    func makeNSView(context: Context) -> SyntaxEditorComparisonView {
        SyntaxEditorComparisonView(model: model)
    }

    func updateNSView(_ nsView: SyntaxEditorComparisonView, context: Context) {
        nsView.update(model: model)
    }
}
#endif

/// A SwiftUI comparison of an editable document and its read-only reference.
///
/// Keep the comparison model in persistent view state. Its modified model remains
/// the source of the text to edit and save. Changing the comparison presentation
/// preserves the modified editor's selection and undo history. Passing a different
/// comparison model rebinds the native view to that model's documents.
@MainActor
public struct SyntaxEditorComparison: View {
    private let model: SyntaxEditorComparisonModel

    /// Creates a comparison view for the supplied model.
    public init(_ model: SyntaxEditorComparisonModel) {
        self.model = model
    }

    public var body: some View {
        SyntaxEditorComparisonContainer(model: model)
    }
}
