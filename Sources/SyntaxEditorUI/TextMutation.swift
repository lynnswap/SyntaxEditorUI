import Foundation

struct TextMutation: Equatable {
    let range: NSRange
    let replacement: String

    static func diff(from oldText: String, to newText: String) -> TextMutation? {
        guard oldText != newText else { return nil }

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

        return TextMutation(
            range: NSRange(
                location: prefixLength,
                length: oldChangeEnd - prefixLength
            ),
            replacement: String(decoding: replacementUTF16, as: UTF16.self)
        )
    }
}

private extension TextMutation {
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
