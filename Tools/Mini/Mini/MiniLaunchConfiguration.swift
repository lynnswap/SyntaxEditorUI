import SyntaxEditorUI

struct MiniLaunchConfiguration {
    static var current: MiniLaunchConfiguration {
        MiniLaunchConfiguration(initialPreset: .comparison)
    }

    let initialPresetID: MiniPreviewPreset.ID
    let initialText: String

    init(initialPreset: MiniPreviewPreset) {
        initialPresetID = initialPreset.id
        initialText = initialPreset.sampleText
    }

    var initialPreset: MiniPreviewPreset {
        MiniPreviewPreset.preset(for: initialPresetID) ?? .javascript
    }
}
