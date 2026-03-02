import Foundation

struct BracketMatcher {
    private static let openToClose: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}",
    ]

    private static let closeToOpen: [Character: Character] = [
        ")": "(",
        "]": "[",
        "}": "{",
    ]

    static func matchedRanges(in source: String, caretUTF16Offset: Int) -> [NSRange] {
        let nsSource = source as NSString
        guard nsSource.length > 0 else { return [] }

        let clampedOffset = min(max(0, caretUTF16Offset), nsSource.length)
        let candidateOffsets = [clampedOffset - 1, clampedOffset]

        for candidate in candidateOffsets where candidate >= 0 && candidate < nsSource.length {
            guard let symbol = character(in: nsSource, at: candidate) else { continue }

            if let closing = openToClose[symbol],
               let match = findMatchingClosing(in: nsSource, from: candidate, open: symbol, close: closing)
            {
                return [
                    NSRange(location: candidate, length: 1),
                    NSRange(location: match, length: 1),
                ]
            }

            if let opening = closeToOpen[symbol],
               let match = findMatchingOpening(in: nsSource, from: candidate, open: opening, close: symbol)
            {
                return [
                    NSRange(location: match, length: 1),
                    NSRange(location: candidate, length: 1),
                ]
            }
        }

        return []
    }
}

private extension BracketMatcher {
    static func findMatchingClosing(
        in source: NSString,
        from offset: Int,
        open: Character,
        close: Character
    ) -> Int? {
        var depth = 0
        var cursor = offset
        while cursor < source.length {
            guard let symbol = character(in: source, at: cursor) else {
                cursor += 1
                continue
            }
            if symbol == open {
                depth += 1
            } else if symbol == close {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor += 1
        }
        return nil
    }

    static func findMatchingOpening(
        in source: NSString,
        from offset: Int,
        open: Character,
        close: Character
    ) -> Int? {
        var depth = 0
        var cursor = offset
        while cursor >= 0 {
            guard let symbol = character(in: source, at: cursor) else {
                cursor -= 1
                continue
            }
            if symbol == close {
                depth += 1
            } else if symbol == open {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor -= 1
        }
        return nil
    }

    static func character(in source: NSString, at offset: Int) -> Character? {
        guard offset >= 0, offset < source.length else { return nil }
        let value = source.character(at: offset)
        guard let scalar = UnicodeScalar(value) else { return nil }
        return Character(scalar)
    }
}
