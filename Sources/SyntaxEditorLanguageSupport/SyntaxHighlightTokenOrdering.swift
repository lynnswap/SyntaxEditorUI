import Foundation

package enum SyntaxHighlightTokenOrdering {
    package static func displayOrder(
        _ lhs: SyntaxEditorHighlighting.Token,
        _ rhs: SyntaxEditorHighlighting.Token
    ) -> Bool {
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }

        if lhs.range.length != rhs.range.length {
            return lhs.range.length > rhs.range.length
        }

        let lhsPriority = renderPriority(lhs)
        let rhsPriority = renderPriority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsSpecificity = lhs.syntaxID.rawValue.split(separator: ".").count
        let rhsSpecificity = rhs.syntaxID.rawValue.split(separator: ".").count
        if lhsSpecificity != rhsSpecificity {
            return lhsSpecificity < rhsSpecificity
        }

        return lhs.rawCaptureName < rhs.rawCaptureName
    }

    /// Merges base tokens with overlay tokens into one `precedes`-ordered
    /// array. Base tokens arrive display-ordered from the token planes (a
    /// linear check guards that, with a sort fallback); overlays are a
    /// concatenation of independently ordered generator streams and are the
    /// small side, so only they pay a sort. Ties keep base before overlay.
    package static func mergedSorted(
        base: [SyntaxEditorHighlighting.Token],
        overlays: [SyntaxEditorHighlighting.Token],
        precedes: (
            _ lhs: SyntaxEditorHighlighting.Token,
            _ lhsIsOverlay: Bool,
            _ rhs: SyntaxEditorHighlighting.Token,
            _ rhsIsOverlay: Bool
        ) -> Bool
    ) -> [SyntaxEditorHighlighting.Token] {
        var sortedBase = base
        for index in 1..<max(1, base.count) where precedes(base[index], false, base[index - 1], false) {
            sortedBase = base.sorted { precedes($0, false, $1, false) }
            break
        }
        let sortedOverlays = overlays.sorted { precedes($0, true, $1, true) }

        var merged: [SyntaxEditorHighlighting.Token] = []
        merged.reserveCapacity(sortedBase.count + sortedOverlays.count)
        var baseIndex = 0
        var overlayIndex = 0
        while baseIndex < sortedBase.count, overlayIndex < sortedOverlays.count {
            if precedes(sortedOverlays[overlayIndex], true, sortedBase[baseIndex], false) {
                merged.append(sortedOverlays[overlayIndex])
                overlayIndex += 1
            } else {
                merged.append(sortedBase[baseIndex])
                baseIndex += 1
            }
        }
        if baseIndex < sortedBase.count {
            merged.append(contentsOf: sortedBase[baseIndex...])
        }
        if overlayIndex < sortedOverlays.count {
            merged.append(contentsOf: sortedOverlays[overlayIndex...])
        }
        return merged
    }

    package static func renderPriority(_ token: SyntaxEditorHighlighting.Token) -> Int {
        let value = token.syntaxID.rawValue
        if value == "plain" {
            return 0
        }
        if value == "comment" || value == "string" {
            return 1
        }
        if value.hasPrefix("comment.doc") || value == "mark" || value == "url" {
            return 7
        }
        if value.hasPrefix("declaration.") || value == "identifier.macro" {
            return 6
        }
        if value == "keyword" || value == "preprocessor" {
            return 5
        }
        if value.contains(".type") || value.contains(".class") {
            return 4
        }
        if value.contains(".function") || value.contains(".macro") {
            return 3
        }
        if value == "attribute" || value.contains(".variable") || value.contains(".constant") {
            return 2
        }
        return 2
    }
}
