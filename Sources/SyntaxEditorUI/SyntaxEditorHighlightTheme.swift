import Foundation

struct SyntaxEditorHexColorPair: Sendable, Hashable {
    let light: UInt32
    let dark: UInt32
}

enum SyntaxEditorHighlightTheme {
    static let baseForeground = SyntaxEditorHexColorPair(light: 0x1F2328, dark: 0xE6E6E6)
    static let bracketBackground = SyntaxEditorHexColorPair(light: 0xF5E890, dark: 0x665C2B)

    static func colorPair(for captureName: String) -> SyntaxEditorHexColorPair? {
        switch tokenCategory(for: captureName.lowercased()) {
        case .comment:
            return SyntaxEditorHexColorPair(light: 0x6A737D, dark: 0x6C7986)
        case .string:
            return SyntaxEditorHexColorPair(light: 0xC41A16, dark: 0xFC6A5D)
        case .keyword:
            return SyntaxEditorHexColorPair(light: 0xAD3DA4, dark: 0xFC5FA3)
        case .number:
            return SyntaxEditorHexColorPair(light: 0x1C00CF, dark: 0xD0BF69)
        case .function:
            return SyntaxEditorHexColorPair(light: 0x326D74, dark: 0x67B7A4)
        case .type:
            return SyntaxEditorHexColorPair(light: 0x0B5CAD, dark: 0x5DD8FF)
        case .constant:
            return SyntaxEditorHexColorPair(light: 0x643820, dark: 0xD0BF69)
        case .variable:
            return SyntaxEditorHexColorPair(light: 0x0E4B9E, dark: 0x9CDCFE)
        case .punctuation:
            return SyntaxEditorHexColorPair(light: 0x6E7781, dark: 0xA7A7A7)
        case .none:
            return nil
        }
    }

    private static func tokenCategory(for name: String) -> TokenCategory? {
        if name.hasPrefix("comment") {
            return .comment
        }
        if name.hasPrefix("string") || name.contains("regex") {
            return .string
        }
        if name.hasPrefix("keyword") || name.hasPrefix("operator") {
            return .keyword
        }
        if name.hasPrefix("number") || name.contains("numeric") {
            return .number
        }
        if name.hasPrefix("function") || name.hasPrefix("method") {
            return .function
        }
        if name.hasPrefix("type") || name.hasPrefix("tag") {
            return .type
        }
        if name.hasPrefix("constant") || name.hasPrefix("boolean") || name.hasPrefix("literal") {
            return .constant
        }
        if name.hasPrefix("attribute")
            || name.hasPrefix("property")
            || name.hasPrefix("selector")
            || name.hasPrefix("variable")
            || name.hasPrefix("name")
        {
            return .variable
        }
        if name.hasPrefix("punctuation") {
            return .punctuation
        }

        return nil
    }

    private enum TokenCategory {
        case comment
        case string
        case keyword
        case number
        case function
        case type
        case constant
        case variable
        case punctuation
    }
}

enum SyntaxEditorRangeUtilities {
    static func clampedRange(_ range: NSRange, utf16Length: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Length)
        let available = max(0, utf16Length - location)
        let length = min(max(0, range.length), available)
        return NSRange(location: location, length: length)
    }

    static func intersection(of lhs: NSRange, and rhs: NSRange) -> NSRange {
        let start = max(lhs.location, rhs.location)
        let end = min(lhs.location + lhs.length, rhs.location + rhs.length)
        let length = max(0, end - start)
        return NSRange(location: start, length: length)
    }

    static func lineStartUTF16Offset(in source: String, around offset: Int) -> Int {
        let nsString = source as NSString
        let clampedOffset = min(max(0, offset), nsString.length)
        return nsString.lineRange(for: NSRange(location: clampedOffset, length: 0)).location
    }
}
