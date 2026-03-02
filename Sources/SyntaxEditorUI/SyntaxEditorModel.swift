import Observation

@MainActor
@Observable
public final class SyntaxEditorModel {
    public var text: String
    public var language: SyntaxLanguage
    public var isEditable: Bool
    public var lineWrappingEnabled: Bool

    public init(
        text: String = "",
        language: SyntaxLanguage,
        isEditable: Bool = true,
        lineWrappingEnabled: Bool = false
    ) {
        self.text = text
        self.language = language
        self.isEditable = isEditable
        self.lineWrappingEnabled = lineWrappingEnabled
    }
}
