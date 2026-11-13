import Foundation
import SyntaxEditorCore

/// Resolves the color and font of syntax tokens for one theme configuration,
/// caching each lookup for the duration of a render pass.
package struct HighlightStyleResolver {
    package struct Key: Hashable {
        package let syntaxID: EditorSourceSyntax.ID
        package let language: SyntaxLanguage
    }

    private let theme: SyntaxEditorTheme
    private let defaultLanguage: SyntaxLanguage
    private let appearance: SyntaxEditorTheme.Appearance
    private let fontSizeDelta: Int
    private let resolveColor: (SyntaxEditorTheme.Color) -> SyntaxEditorTheme.Color

    private var styleCache: [Key: HighlightRunStyle] = [:]
    private var keysWithoutStyle: Set<Key> = []
    private var fontCache: [SyntaxEditorTheme.FontDescriptor: SyntaxEditorTheme.Font] = [:]

    /// - Parameters:
    ///   - defaultLanguage: The language of tokens that do not name one.
    ///   - resolveColor: Maps a theme color to the color to render, for
    ///     platforms that resolve dynamic colors up front.
    package init(
        theme: SyntaxEditorTheme,
        defaultLanguage: SyntaxLanguage,
        appearance: SyntaxEditorTheme.Appearance,
        fontSizeDelta: Int,
        resolveColor: @escaping (SyntaxEditorTheme.Color) -> SyntaxEditorTheme.Color = { $0 }
    ) {
        self.theme = theme
        self.defaultLanguage = defaultLanguage
        self.appearance = appearance
        self.fontSizeDelta = fontSizeDelta
        self.resolveColor = resolveColor
    }

    /// The style for a token, or `nil` when the theme does not style it.
    package mutating func style(
        for syntaxID: EditorSourceSyntax.ID,
        language: SyntaxLanguage?
    ) -> (key: Key, style: HighlightRunStyle)? {
        let key = Key(syntaxID: syntaxID, language: language ?? defaultLanguage)

        if let cached = styleCache[key] {
            return (key, cached)
        }
        guard !keysWithoutStyle.contains(key) else {
            return nil
        }
        guard let style = SyntaxEditorHighlightTheme.style(
            for: syntaxID,
            in: theme,
            language: key.language,
            appearance: appearance
        ) else {
            keysWithoutStyle.insert(key)
            return nil
        }

        let resolvedStyle = HighlightRunStyle(
            foregroundColor: resolveColor(style.foreground),
            font: platformFont(for: style.font)
        )
        styleCache[key] = resolvedStyle
        return (key, resolvedStyle)
    }

    private mutating func platformFont(
        for descriptor: SyntaxEditorTheme.FontDescriptor
    ) -> SyntaxEditorTheme.Font {
        if let cached = fontCache[descriptor] {
            return cached
        }
        let font = descriptor.platformFont(fontSizeDelta: fontSizeDelta)
        fontCache[descriptor] = font
        return font
    }
}
