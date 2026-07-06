import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguages

package struct BracketMatcher {
    /// Upper bound on how far a match scan walks from the caret, in UTF-16
    /// units. Runs synchronously on every selection change; without a cap an
    /// unmatched bracket costs a whole-document scan per caret move. Pairs
    /// farther apart than this are not highlighted.
    package static let maxScanDistance = 50_000

    package static func matchedRanges(in source: String, caretUTF16Offset: Int) -> [NSRange] {
        let nsSource = source as NSString
        guard nsSource.length > 0 else { return [] }

        let clampedOffset = min(max(0, caretUTF16Offset), nsSource.length)
        let candidateOffsets = [clampedOffset - 1, clampedOffset]

        for candidate in candidateOffsets where candidate >= 0 && candidate < nsSource.length {
            let symbol = nsSource.character(at: candidate)

            if let closing = closingCodeUnit(forOpening: symbol),
               let match = findMatchingClosing(in: nsSource, from: candidate, open: symbol, close: closing)
            {
                return [
                    NSRange(location: candidate, length: 1),
                    NSRange(location: match, length: 1),
                ]
            }

            if let opening = openingCodeUnit(forClosing: symbol),
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
    /// Chunked `getCharacters` keeps the scan on a contiguous buffer instead
    /// of paying one `character(at:)` message send per code unit.
    static let scanChunkLength = 512

    static func closingCodeUnit(forOpening unit: unichar) -> unichar? {
        switch unit {
        case UInt16(("(" as UnicodeScalar).value): UInt16((")" as UnicodeScalar).value)
        case UInt16(("[" as UnicodeScalar).value): UInt16(("]" as UnicodeScalar).value)
        case UInt16(("{" as UnicodeScalar).value): UInt16(("}" as UnicodeScalar).value)
        default: nil
        }
    }

    static func openingCodeUnit(forClosing unit: unichar) -> unichar? {
        switch unit {
        case UInt16((")" as UnicodeScalar).value): UInt16(("(" as UnicodeScalar).value)
        case UInt16(("]" as UnicodeScalar).value): UInt16(("[" as UnicodeScalar).value)
        case UInt16(("}" as UnicodeScalar).value): UInt16(("{" as UnicodeScalar).value)
        default: nil
        }
    }

    static func findMatchingClosing(
        in source: NSString,
        from offset: Int,
        open: unichar,
        close: unichar
    ) -> Int? {
        let limit = min(source.length, offset + maxScanDistance)
        guard offset < limit else { return nil }
        var depth = 0
        var buffer = [unichar](repeating: 0, count: min(scanChunkLength, limit - offset))
        var chunkStart = offset
        while chunkStart < limit {
            let chunkLength = min(scanChunkLength, limit - chunkStart)
            unsafe buffer.withUnsafeMutableBufferPointer { pointer in
                unsafe source.getCharacters(
                    pointer.baseAddress!,
                    range: NSRange(location: chunkStart, length: chunkLength)
                )
            }
            for index in 0..<chunkLength {
                let symbol = buffer[index]
                if symbol == open {
                    depth += 1
                } else if symbol == close {
                    depth -= 1
                    if depth == 0 {
                        return chunkStart + index
                    }
                }
            }
            chunkStart += chunkLength
        }
        return nil
    }

    static func findMatchingOpening(
        in source: NSString,
        from offset: Int,
        open: unichar,
        close: unichar
    ) -> Int? {
        let limit = max(0, offset - maxScanDistance)
        guard offset >= limit else { return nil }
        var depth = 0
        var buffer = [unichar](repeating: 0, count: min(scanChunkLength, offset - limit + 1))
        var chunkEnd = offset + 1
        while chunkEnd > limit {
            let chunkLength = min(scanChunkLength, chunkEnd - limit)
            let chunkStart = chunkEnd - chunkLength
            unsafe buffer.withUnsafeMutableBufferPointer { pointer in
                unsafe source.getCharacters(
                    pointer.baseAddress!,
                    range: NSRange(location: chunkStart, length: chunkLength)
                )
            }
            for index in stride(from: chunkLength - 1, through: 0, by: -1) {
                let symbol = buffer[index]
                if symbol == close {
                    depth += 1
                } else if symbol == open {
                    depth -= 1
                    if depth == 0 {
                        return chunkStart + index
                    }
                }
            }
            chunkEnd = chunkStart
        }
        return nil
    }
}
