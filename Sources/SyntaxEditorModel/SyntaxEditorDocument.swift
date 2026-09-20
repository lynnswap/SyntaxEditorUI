import Observation
import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorTheme

/// The observable text, selection, and configuration shared with an editor.
///
/// Create and retain a model in your app, then pass it to a SwiftUI, UIKit,
/// or AppKit editor. User edits update this same model. Read ``text`` when
/// saving a document; file loading and persistence remain the app's responsibility.
///
/// Access the model on the main actor. Text and selection ranges use UTF-16
/// coordinates, matching `NSRange` operations on `NSString`.
@MainActor
@Observable
public final class SyntaxEditorModel {
    private var textStorage: String
    private var selectedRangeStorage: NSRange

    /// The current document contents.
    ///
    /// Assigning a different string records a whole-document replacement.
    /// The existing selection is preserved where it fits in the new text.
    /// Use ``replaceText(_:selectedRange:)`` to choose a new selection at the
    /// same time.
    public var text: String {
        get {
            // Revisions also distinguish canonically equivalent source strings.
            _ = textRevision
            return textStorage
        }
        set {
            replaceText(newValue)
        }
    }

    /// The language used for highlighting and code-aware editing.
    ///
    /// Changing the language leaves ``text`` and ``textRevision`` unchanged.
    public var language: SyntaxLanguage
    /// The current selection, measured in UTF-16 code units.
    ///
    /// A zero-length range represents the insertion point. Assignments are
    /// clamped to the document's UTF-16 length and do not create a text change.
    public var selectedRange: NSRange {
        get {
            selectedRangeStorage
        }
        set {
            selectedRangeStorage = SyntaxEditorRangeUtilities.clampedRange(
                newValue,
                utf16Length: textStorage.utf16.count
            )
        }
    }

    /// Whether the editor accepts text changes from user interaction.
    ///
    /// Your app can still replace ``text`` programmatically when this is `false`.
    public var isEditable: Bool
    /// Whether lines wrap to the available editor width.
    public var lineWrappingEnabled: Bool
    /// The colors and base font used to render the editor.
    public var theme: SyntaxEditorTheme
    /// Whether the editor fills its background with the theme's background color.
    ///
    /// Set this to `false` when the surrounding view supplies the background.
    /// Syntax colors and editor decorations remain enabled.
    public var drawsBackground: Bool
    /// The point-size adjustment added to the theme's font sizes.
    ///
    /// Zero uses the theme's sizes. Rendering clamps the resulting sizes to
    /// 4 through 64 points; assigning this property does not clamp its stored value.
    public var fontSizeDelta: Int
    /// The revision number of the model's committed text changes.
    ///
    /// This starts at zero and advances once per committed change. Changing
    /// selection or editor configuration does not advance it.
    public private(set) var textRevision: Int
    /// The most recent committed text change, or `nil` before the first change.
    ///
    /// Selection-only and configuration changes leave this value unchanged.
    /// This property holds only the latest change; use ``text`` when you need
    /// the complete current contents.
    public private(set) var latestTextChange: SyntaxEditorTextChange?

    /// Creates a model with initial contents and editor configuration.
    ///
    /// Initial contents start at revision zero and do not produce a text-change
    /// record. The selection is clamped to the initial text.
    ///
    /// - Parameters:
    ///   - text: The initial document contents.
    ///   - language: The highlighting and editing mode. The default is JavaScript.
    ///   - selectedRange: The initial selection, in UTF-16 code units.
    ///   - isEditable: Whether user interaction may change the text.
    ///   - lineWrappingEnabled: Whether lines wrap to the available width.
    ///   - theme: The editor's colors and base font.
    ///   - drawsBackground: Whether the editor draws the theme background.
    ///   - fontSizeDelta: The point-size adjustment relative to the theme.
    public init(
        text: String = "",
        language: SyntaxLanguage = .javascript,
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        isEditable: Bool = true,
        lineWrappingEnabled: Bool = false,
        theme: SyntaxEditorTheme = .default,
        drawsBackground: Bool = true,
        fontSizeDelta: Int = 0
    ) {
        self.textStorage = text
        self.language = language
        self.selectedRangeStorage = SyntaxEditorRangeUtilities.clampedRange(
            selectedRange,
            utf16Length: text.utf16.count
        )
        self.isEditable = isEditable
        self.lineWrappingEnabled = lineWrappingEnabled
        self.theme = theme
        self.drawsBackground = drawsBackground
        self.fontSizeDelta = fontSizeDelta
        self.textRevision = 0
        self.latestTextChange = nil
    }

    /// Replaces the document text and optionally its selection.
    ///
    /// A different string advances ``textRevision`` and updates
    /// ``latestTextChange`` with a whole-document replacement. If the text is
    /// unchanged, only the selection is updated: the revision and latest change
    /// remain unchanged, and this method returns `nil`.
    ///
    /// - Parameters:
    ///   - text: The complete replacement contents.
    ///   - selectedRange: The selection in the new text, in UTF-16 code units.
    ///     Pass `nil` to preserve the current selection. Either selection is
    ///     clamped to the new text's length.
    /// - Returns: The committed text change, or `nil` when the text is unchanged.
    @discardableResult
    public func replaceText(
        _ text: String,
        selectedRange: NSRange? = nil
    ) -> SyntaxEditorTextChange? {
        let nextSelectedRange = SyntaxEditorRangeUtilities.clampedRange(
            selectedRange ?? selectedRangeStorage,
            utf16Length: text.utf16.count
        )

        guard !textStorage.utf16.elementsEqual(text.utf16) else {
            selectedRangeStorage = nextSelectedRange
            return nil
        }

        let replacement = SyntaxEditorTextChange.Replacement(
            range: NSRange(location: 0, length: textStorage.utf16.count),
            replacement: text
        )
        textStorage = text
        selectedRangeStorage = nextSelectedRange
        textRevision += 1
        let change = SyntaxEditorTextChange(
            textRevision: textRevision,
            replacements: [replacement],
            selectedRange: nextSelectedRange,
            kind: .wholeDocumentReplacement
        )
        latestTextChange = change
        return change
    }

    /// Sets the language and replaces the document contents.
    ///
    /// The language is updated even when the text is unchanged. Text revision,
    /// selection, and return-value behavior follow ``replaceText(_:selectedRange:)``.
    ///
    /// - Parameters:
    ///   - text: The complete replacement contents.
    ///   - language: The new highlighting and editing mode.
    ///   - selectedRange: The selection in the new text, in UTF-16 code units,
    ///     or `nil` to preserve the current selection within the new text's bounds.
    /// - Returns: The committed text change, or `nil` when only language or
    ///   selection changed, or all values were unchanged.
    @discardableResult
    public func replaceContents(
        text: String,
        language: SyntaxLanguage,
        selectedRange: NSRange? = nil
    ) -> SyntaxEditorTextChange? {
        self.language = language
        return replaceText(text, selectedRange: selectedRange)
    }

    /// Increases the font-size adjustment using a one-point step.
    ///
    /// The result is bounded by the current language's base font and the
    /// rendered size limits. A value below the allowed adjustment range is
    /// brought into range before stepping upward.
    public func increaseFontSize() {
        fontSizeDelta = SyntaxEditorTheme.FontSize.increasedDelta(
            fontSizeDelta,
            forBasePointSize: fontSizeCommandBasePointSize
        )
    }

    /// Decreases the font-size adjustment using a one-point step.
    ///
    /// The result is bounded by the current language's base font and the
    /// rendered size limits. A value above the allowed adjustment range is
    /// brought into range before stepping downward.
    public func decreaseFontSize() {
        fontSizeDelta = SyntaxEditorTheme.FontSize.decreasedDelta(
            fontSizeDelta,
            forBasePointSize: fontSizeCommandBasePointSize
        )
    }

    /// Restores the theme's font sizes by setting ``fontSizeDelta`` to zero.
    public func resetFontSize() {
        fontSizeDelta = 0
    }

    private var fontSizeCommandBasePointSize: CGFloat {
        theme.resolved(for: language).base.font.size
    }

    @discardableResult
    package func commitTextReplacements(
        _ replacements: [SyntaxEditorTextChange.Replacement],
        selectedRange: NSRange
    ) -> SyntaxEditorTextChange? {
        guard !replacements.isEmpty else {
            selectedRangeStorage = SyntaxEditorRangeUtilities.clampedRange(
                selectedRange,
                utf16Length: textStorage.utf16.count
            )
            return nil
        }

        textStorage = Self.applying(replacements, to: textStorage)
        let nextSelectedRange = SyntaxEditorRangeUtilities.clampedRange(
            selectedRange,
            utf16Length: textStorage.utf16.count
        )
        selectedRangeStorage = nextSelectedRange
        textRevision += 1
        let change = SyntaxEditorTextChange(
            textRevision: textRevision,
            replacements: replacements,
            selectedRange: nextSelectedRange,
            kind: .incremental
        )
        latestTextChange = change
        return change
    }

    nonisolated package static func applying(
        _ replacements: [SyntaxEditorTextChange.Replacement],
        to source: String
    ) -> String {
        SyntaxEditorTextChange.applying(replacements, to: source)
    }

    nonisolated package static func inverseReplacements(
        for replacements: [SyntaxEditorTextChange.Replacement],
        in source: String
    ) -> [SyntaxEditorTextChange.Replacement] {
        SyntaxEditorTextChange.inverseReplacements(for: replacements, in: source)
    }
}
