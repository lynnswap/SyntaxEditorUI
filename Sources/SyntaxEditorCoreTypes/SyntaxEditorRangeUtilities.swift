import Foundation

package enum SyntaxEditorRangeUtilities {
    package static func clampedRange(_ range: NSRange, utf16Length: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Length)
        let available = max(0, utf16Length - location)
        let length = min(max(0, range.length), available)
        return NSRange(location: location, length: length)
    }

    package static func intersection(of lhs: NSRange, and rhs: NSRange) -> NSRange {
        let start = max(lhs.location, rhs.location)
        let end = min(lhs.location + lhs.length, rhs.location + rhs.length)
        let length = max(0, end - start)
        return NSRange(location: start, length: length)
    }

    /// Sorts `ranges` and merges those that overlap or touch.
    ///
    /// Empty ranges and ranges located at `NSNotFound` are dropped.
    package static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { $0.location < $1.location }
        guard var current = sorted.first else { return [] }

        var merged: [NSRange] = []
        merged.reserveCapacity(sorted.count)
        for range in sorted.dropFirst() {
            let currentEnd = current.location + current.length
            if range.location <= currentEnd {
                current.length = max(currentEnd, range.location + range.length) - current.location
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }
}
