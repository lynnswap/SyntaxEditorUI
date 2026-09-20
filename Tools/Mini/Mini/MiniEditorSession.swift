import Observation
import SyntaxEditorUI

@MainActor
@Observable
final class MiniEditorSession {
    let editorModel: SyntaxEditorModel
    let comparisonModel: SyntaxEditorComparisonModel
    static let presentationTitles = ["Markers", "Inline", "Side by Side"]
    static let presentations: [SyntaxEditorComparisonModel.Presentation] = [.changeMarkers, .inline, .sideBySide]
    private(set) var selectedPresetID: MiniPreviewPreset.ID

    private let initialPresetID: MiniPreviewPreset.ID
    private let initialPresetText: String

    init(configuration: MiniLaunchConfiguration) {
        self.initialPresetID = configuration.initialPresetID
        self.initialPresetText = configuration.initialText
        self.selectedPresetID = configuration.initialPresetID
        let editorModel = SyntaxEditorModel(
            text: configuration.initialText,
            language: configuration.initialPreset.language,
            lineWrappingEnabled: false
        )
        self.editorModel = editorModel
        self.comparisonModel = SyntaxEditorComparisonModel(
            originalText: configuration.initialPreset.comparisonReference ?? configuration.initialText,
            modified: editorModel
        )
    }

    var currentPreset: MiniPreviewPreset {
        MiniPreviewPreset.preset(for: selectedPresetID) ?? .javascript
    }

    var presentationIndex: Int {
        get { Self.presentations.firstIndex(of: comparisonModel.presentation) ?? 1 }
        set {
            guard Self.presentations.indices.contains(newValue) else { return }
            comparisonModel.presentation = Self.presentations[newValue]
        }
    }

    var comparisonStatus: String {
        guard let count = comparisonModel.changeCount else { return "Comparing…" }
        if count == 0 { return "No changes" }
        if let selected = comparisonModel.selectedChangeIndex { return "Change \(selected + 1) of \(count)" }
        return count == 1 ? "1 change" : "\(count) changes"
    }

    var canSelectPreviousChange: Bool {
        (comparisonModel.changeCount ?? 0) > 0 && comparisonModel.selectedChangeIndex != 0
    }

    var canSelectNextChange: Bool {
        guard let count = comparisonModel.changeCount, count > 0 else { return false }
        return comparisonModel.selectedChangeIndex != count - 1
    }

    func useCurrentAsReference() {
        comparisonModel.originalText = editorModel.text
    }

    func restoreSampleReference() {
        comparisonModel.originalText = currentPreset.comparisonReference ?? text(for: currentPreset)
    }

    var selectedThemePreset: SyntaxEditorTheme.Preset {
        get { editorModel.theme.preset ?? .default }
        set { editorModel.theme = .preset(newValue) }
    }

    func selectPreset(_ presetID: MiniPreviewPreset.ID) {
        guard selectedPresetID != presetID,
              let preset = MiniPreviewPreset.preset(for: presetID)
        else {
            return
        }

        selectedPresetID = presetID
        editorModel.replaceContents(
            text: text(for: preset),
            language: preset.language
        )
        comparisonModel.originalText = preset.comparisonReference ?? text(for: preset)
    }

    private func text(for preset: MiniPreviewPreset) -> String {
        if preset.id == initialPresetID {
            return initialPresetText
        }

        return preset.sampleText
    }
}
