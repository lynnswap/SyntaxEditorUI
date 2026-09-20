import Foundation

/// A committed text change and the selection that followed it.
///
/// Replacement ranges use UTF-16 offsets in the text before the change.
/// The selected range uses UTF-16 offsets in the resulting text. A value
/// describes one revision; it does not contain the document's full history.
public struct SyntaxEditorTextChange: Equatable, Sendable {
    /// Text to insert in place of a range in the source document.
    public struct Replacement: Equatable, Sendable {
        /// The range to replace, measured in UTF-16 code units before the change.
        ///
        /// A zero-length range inserts text at its location.
        public let range: NSRange
        /// The inserted text, or an empty string to delete the range.
        public let replacement: String

        /// The starting UTF-16 offset of ``range``.
        public var location: Int {
            range.location
        }

        /// The number of UTF-16 code units removed by ``range``.
        public var length: Int {
            range.length
        }

        /// Describes a replacement without applying it to a document.
        ///
        /// - Parameters:
        ///   - range: The range in the original text, in UTF-16 code units.
        ///   - replacement: The text to insert at that range.
        public init(range: NSRange, replacement: String) {
            self.range = range
            self.replacement = replacement
        }

        /// Describes a replacement using a UTF-16 location and length.
        ///
        /// - Parameters:
        ///   - location: The starting offset in the original text.
        ///   - length: The number of UTF-16 code units to remove.
        ///   - replacement: The text to insert at that location.
        public init(location: Int, length: Int, replacement: String) {
            self.init(
                range: NSRange(location: location, length: length),
                replacement: replacement
            )
        }

        package static func singleReplacement(from oldText: String, to newText: String) -> Replacement? {
            guard !oldText.utf16.elementsEqual(newText.utf16) else { return nil }

            let oldUTF16 = Array(oldText.utf16)
            let newUTF16 = Array(newText.utf16)
            let prefixLength = commonPrefixLength(oldUTF16, newUTF16)
            let suffixLength = commonSuffixLength(
                oldUTF16,
                newUTF16,
                prefixLength: prefixLength
            )

            let oldChangeEnd = oldUTF16.count - suffixLength
            let newChangeEnd = newUTF16.count - suffixLength
            let replacementUTF16 = Array(newUTF16[prefixLength..<newChangeEnd])

            return Replacement(
                range: NSRange(
                    location: prefixLength,
                    length: oldChangeEnd - prefixLength
                ),
                replacement: String(decoding: replacementUTF16, as: UTF16.self)
            )
        }
    }

    /// Whether the change edits existing contents or replaces the document.
    public enum Kind: Equatable, Sendable {
        /// One or more edits to ranges within the existing document.
        case incremental
        /// A replacement of all document text.
        case wholeDocumentReplacement
    }

    /// The model's text revision after this change was committed.
    public let textRevision: Int
    /// The replacements that produced this revision.
    ///
    /// All ranges refer to the same pre-change text. To apply multiple
    /// replacements to a mutable copy, process higher locations first.
    public let replacements: [Replacement]
    /// The selection after the change, measured in UTF-16 code units.
    public let selectedRange: NSRange
    /// The scope of the text replacement.
    public let kind: Kind

    /// Creates a change description without mutating an editor model.
    ///
    /// - Parameters:
    ///   - textRevision: The revision represented by the resulting text.
    ///   - replacements: Replacements expressed in the pre-change text's coordinates.
    ///   - selectedRange: The selection in the resulting text, in UTF-16 code units.
    ///   - kind: Whether the change is incremental or replaces the whole document.
    public init(
        textRevision: Int,
        replacements: [Replacement],
        selectedRange: NSRange,
        kind: Kind
    ) {
        self.textRevision = textRevision
        self.replacements = replacements
        self.selectedRange = selectedRange
        self.kind = kind
    }
}

extension SyntaxEditorTextChange {
    package static func applying(
        _ replacements: [SyntaxEditorTextChange.Replacement],
        to source: String
    ) -> String {
        let mutable = NSMutableString(string: source)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
        return mutable as String
    }

    package static func inverseReplacements(
        for replacements: [SyntaxEditorTextChange.Replacement],
        in source: String
    ) -> [SyntaxEditorTextChange.Replacement] {
        let nsSource = source as NSString
        var delta = 0
        return replacements
            .sorted { $0.range.location < $1.range.location }
            .map { replacement in
                let original = nsSource.substring(with: replacement.range)
                let inverse = SyntaxEditorTextChange.Replacement(
                    range: NSRange(
                        location: replacement.range.location + delta,
                        length: replacement.replacement.utf16.count
                    ),
                    replacement: original
                )
                delta += replacement.replacement.utf16.count - replacement.range.length
                return inverse
            }
    }
}

private extension SyntaxEditorTextChange.Replacement {
    static func commonPrefixLength(_ lhs: [UInt16], _ rhs: [UInt16]) -> Int {
        let count = min(lhs.count, rhs.count)
        var index = 0
        while index < count, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    static func commonSuffixLength(
        _ lhs: [UInt16],
        _ rhs: [UInt16],
        prefixLength: Int
    ) -> Int {
        var lhsIndex = lhs.count
        var rhsIndex = rhs.count
        var matched = 0

        while lhsIndex > prefixLength,
              rhsIndex > prefixLength,
              lhs[lhsIndex - 1] == rhs[rhsIndex - 1]
        {
            lhsIndex -= 1
            rhsIndex -= 1
            matched += 1
        }

        return matched
    }
}
