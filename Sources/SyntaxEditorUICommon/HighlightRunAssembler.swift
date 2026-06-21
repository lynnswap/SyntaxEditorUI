#if canImport(UIKit) || canImport(AppKit)
import Foundation
import SyntaxEditorCore

package struct HighlightAssembledRun<Style> {
    package var range: NSRange
    package let style: Style

    package init(range: NSRange, style: Style) {
        self.range = range
        self.style = style
    }
}

package struct HighlightRunStyle {
    package let foregroundColor: SyntaxEditorTheme.Color
    package let font: SyntaxEditorTheme.Font

    package init(
        foregroundColor: SyntaxEditorTheme.Color,
        font: SyntaxEditorTheme.Font
    ) {
        self.foregroundColor = foregroundColor
        self.font = font
    }
}

package enum HighlightRunAssembler {
    package static func assembleRunSet(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        textLength: Int,
        resolveStyle: (SyntaxEditorHighlighting.Token) -> HighlightRunStyle?
    ) -> HighlightRunSet {
        let styleRuns = assembleRuns(
            for: tokens,
            targetRange: targetRange,
            textLength: textLength,
            resolveStyle: resolveStyle,
            stylesCanCoalesce: { lhs, rhs in
                lhs.foregroundColor.isEqual(rhs.foregroundColor)
                    && lhs.font.isEqual(rhs.font)
            }
        )
        var colorRuns: [HighlightColorRun] = []
        var fontRuns: [HighlightFontRun] = []
        colorRuns.reserveCapacity(styleRuns.count)
        fontRuns.reserveCapacity(styleRuns.count)

        for run in styleRuns {
            appendColorRun(
                HighlightColorRun(range: run.range, color: run.style.foregroundColor),
                to: &colorRuns
            )
            appendFontRun(
                HighlightFontRun(range: run.range, font: run.style.font),
                to: &fontRuns
            )
        }

        return HighlightRunSet(colorRuns: colorRuns, fontRuns: fontRuns)
    }

    package static func assembleRuns<Style>(
        for tokens: [SyntaxEditorHighlighting.Token],
        targetRange: NSRange,
        textLength: Int,
        resolveStyle: (SyntaxEditorHighlighting.Token) -> Style?,
        stylesCanCoalesce: (Style, Style) -> Bool
    ) -> [HighlightAssembledRun<Style>] {
        var runs: [HighlightAssembledRun<Style>] = []
        runs.reserveCapacity(min(tokens.count, 1024))

        let tokenRangeIndex = HighlightTokenRangeIndex(tokens: tokens)
        let tokenStartIndex = tokenRangeIndex.firstTokenIndex(intersecting: targetRange)
        for token in tokens[tokenStartIndex...] {
            guard token.range.location < targetRange.upperBound else { break }
            let clamped = SyntaxEditorRangeUtilities.clampedRange(
                token.range,
                utf16Length: textLength
            )
            let intersection = SyntaxEditorRangeUtilities.intersection(
                of: clamped,
                and: targetRange
            )
            guard intersection.length > 0 else {
                continue
            }

            let resolvedStyle = resolveStyle(token)
            subtract(intersection, from: &runs)
            guard let resolvedStyle else {
                continue
            }
            insert(
                HighlightAssembledRun(range: intersection, style: resolvedStyle),
                into: &runs,
                stylesCanCoalesce: stylesCanCoalesce
            )
        }

        return runs
    }

    private static func insert<Style>(
        _ run: HighlightAssembledRun<Style>,
        into runs: inout [HighlightAssembledRun<Style>],
        stylesCanCoalesce: (Style, Style) -> Bool
    ) {
        let insertionIndex = firstRunIndex(
            startingAtOrAfter: run.range.location,
            in: runs
        )
        runs.insert(run, at: insertionIndex)
        coalesce(
            around: insertionIndex,
            in: &runs,
            stylesCanCoalesce: stylesCanCoalesce
        )
    }

    private static func coalesce<Style>(
        around insertionIndex: Int,
        in runs: inout [HighlightAssembledRun<Style>],
        stylesCanCoalesce: (Style, Style) -> Bool
    ) {
        var index = insertionIndex
        if index > 0, runsCanCoalesce(runs[index - 1], runs[index], stylesCanCoalesce: stylesCanCoalesce) {
            runs[index - 1].range = unionRange(runs[index - 1].range, runs[index].range)
            runs.remove(at: index)
            index -= 1
        }
        if index + 1 < runs.count, runsCanCoalesce(runs[index], runs[index + 1], stylesCanCoalesce: stylesCanCoalesce) {
            runs[index].range = unionRange(runs[index].range, runs[index + 1].range)
            runs.remove(at: index + 1)
        }
    }

    private static func runsCanCoalesce<Style>(
        _ lhs: HighlightAssembledRun<Style>,
        _ rhs: HighlightAssembledRun<Style>,
        stylesCanCoalesce: (Style, Style) -> Bool
    ) -> Bool {
        stylesCanCoalesce(lhs.style, rhs.style)
            && lhs.range.upperBound >= rhs.range.location
            && rhs.range.upperBound >= lhs.range.location
    }

    private static func subtract<Style>(
        _ range: NSRange,
        from runs: inout [HighlightAssembledRun<Style>]
    ) {
        var index = firstRunIndex(intersecting: range, in: runs)
        while index < runs.count {
            let run = runs[index]
            guard run.range.location < range.upperBound else { break }
            let intersection = SyntaxEditorRangeUtilities.intersection(of: run.range, and: range)
            guard intersection.length > 0 else {
                index += 1
                continue
            }

            let runStart = run.range.location
            let runEnd = run.range.upperBound
            let resetStart = intersection.location
            let resetEnd = intersection.upperBound

            if resetStart <= runStart, resetEnd >= runEnd {
                runs.remove(at: index)
            } else if resetStart <= runStart {
                runs[index].range = NSRange(location: resetEnd, length: runEnd - resetEnd)
                break
            } else if resetEnd >= runEnd {
                runs[index].range = NSRange(location: runStart, length: resetStart - runStart)
                index += 1
            } else {
                let trailingRun = HighlightAssembledRun(
                    range: NSRange(location: resetEnd, length: runEnd - resetEnd),
                    style: run.style
                )
                runs[index].range = NSRange(location: runStart, length: resetStart - runStart)
                runs.insert(trailingRun, at: index + 1)
                break
            }
        }
    }

    private static func appendColorRun(
        _ run: HighlightColorRun,
        to runs: inout [HighlightColorRun]
    ) {
        if var last = runs.last,
           last.color.isEqual(run.color),
           last.range.upperBound >= run.range.location,
           run.range.upperBound >= last.range.location {
            last.range = unionRange(last.range, run.range)
            runs[runs.count - 1] = last
        } else {
            runs.append(run)
        }
    }

    private static func appendFontRun(
        _ run: HighlightFontRun,
        to runs: inout [HighlightFontRun]
    ) {
        if var last = runs.last,
           last.font.isEqual(run.font),
           last.range.upperBound >= run.range.location,
           run.range.upperBound >= last.range.location {
            last.range = unionRange(last.range, run.range)
            runs[runs.count - 1] = last
        } else {
            runs.append(run)
        }
    }

    private static func firstRunIndex<Style>(
        intersecting range: NSRange,
        in runs: [HighlightAssembledRun<Style>]
    ) -> Int {
        var lowerBound = 0
        var upperBound = runs.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if runs[middle].range.upperBound <= range.location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func firstRunIndex<Style>(
        startingAtOrAfter location: Int,
        in runs: [HighlightAssembledRun<Style>]
    ) -> Int {
        var lowerBound = 0
        var upperBound = runs.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if runs[middle].range.location < location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func unionRange(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        let lowerBound = min(lhs.location, rhs.location)
        let upperBound = max(lhs.upperBound, rhs.upperBound)
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }
}
#endif
