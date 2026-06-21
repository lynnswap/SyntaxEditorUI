#if canImport(UIKit) || canImport(AppKit)
import Foundation
import SyntaxEditorCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

package struct HighlightColorRun {
    package var range: NSRange
    package let color: SyntaxEditorTheme.Color

    package init(range: NSRange, color: SyntaxEditorTheme.Color) {
        self.range = range
        self.color = color
    }
}

package struct HighlightFontRun {
    package var range: NSRange
    package let font: SyntaxEditorTheme.Font

    package init(range: NSRange, font: SyntaxEditorTheme.Font) {
        self.range = range
        self.font = font
    }
}

package struct HighlightRunSet {
    package let colorRuns: [HighlightColorRun]
    package let fontRuns: [HighlightFontRun]

    package init(colorRuns: [HighlightColorRun], fontRuns: [HighlightFontRun]) {
        self.colorRuns = colorRuns
        self.fontRuns = fontRuns
    }
}

package struct HighlightRenderSnapshot {
    package let revision: Int?
    package let language: SyntaxLanguage?
    package let textLength: Int
    package let baseForeground: SyntaxEditorTheme.Color?
    package let baseFont: SyntaxEditorTheme.Font?
    package let colorRuns: [HighlightColorRun]
    package let fontRuns: [HighlightFontRun]
    package let suppressionRanges: [NSRange]

    package init(
        revision: Int?,
        language: SyntaxLanguage?,
        textLength: Int,
        baseForeground: SyntaxEditorTheme.Color?,
        baseFont: SyntaxEditorTheme.Font?,
        colorRuns: [HighlightColorRun],
        fontRuns: [HighlightFontRun],
        suppressionRanges: [NSRange]
    ) {
        let textLength = max(0, textLength)
        self.revision = revision
        self.language = language
        self.textLength = textLength
        self.baseForeground = baseForeground
        self.baseFont = baseFont
        self.colorRuns = HighlightRunUtilities.coalescedColorRuns(
            HighlightRunUtilities.normalizedColorRuns(colorRuns, textLength: textLength)
        )
        self.fontRuns = HighlightRunUtilities.coalescedFontRuns(
            HighlightRunUtilities.normalizedFontRuns(fontRuns, textLength: textLength)
        )
        self.suppressionRanges = HighlightRunUtilities.normalizedRanges(
            suppressionRanges,
            textLength: textLength
        )
    }

    package static var empty: HighlightRenderSnapshot {
        HighlightRenderSnapshot(
            revision: nil,
            language: nil,
            textLength: 0,
            baseForeground: nil,
            baseFont: nil,
            colorRuns: [],
            fontRuns: [],
            suppressionRanges: []
        )
    }
}

package struct PendingHighlightEditMap {
    private struct Edit {
        var location: Int
        var length: Int
        var replacementLength: Int
        var previousTextLength: Int
        var resultingTextLength: Int

        var delta: Int {
            replacementLength - length
        }
    }

    private var edits: [Edit] = []
    private var dirtyRanges: [NSRange] = []
    package private(set) var currentTextLength: Int?

    package init() {}

    package var isEmpty: Bool {
        edits.isEmpty
    }

    package var editCountForTesting: Int {
        edits.count
    }

    package var visibleDirtyRanges: [NSRange] {
        dirtyRanges
    }

    package mutating func recordPendingEdit(
        _ mutation: SyntaxEditorTextChange.Replacement,
        currentTextLength: Int
    ) {
        let currentTextLength = max(0, currentTextLength)
        let replacementLength = mutation.replacement.utf16.count
        let previousTextLength = max(0, currentTextLength - (replacementLength - mutation.length))
        let edit = Edit(
            location: min(max(0, mutation.location), previousTextLength),
            length: min(max(0, mutation.length), previousTextLength - min(max(0, mutation.location), previousTextLength)),
            replacementLength: replacementLength,
            previousTextLength: previousTextLength,
            resultingTextLength: currentTextLength
        )

        dirtyRanges = HighlightRunUtilities.normalizedRanges(
            dirtyRanges.flatMap {
                Self.currentRanges(forSnapshotRange: $0, applying: edit)
            },
            textLength: currentTextLength
        )
        if let dirtyRange = Self.dirtyRange(for: edit) {
            dirtyRanges.append(dirtyRange)
            dirtyRanges = HighlightRunUtilities.normalizedRanges(dirtyRanges, textLength: currentTextLength)
        }

        appendEdit(edit)
        self.currentTextLength = currentTextLength
    }

    package mutating func clear() {
        edits = []
        dirtyRanges = []
        currentTextLength = nil
    }

    package func currentRanges(forSnapshotRange range: NSRange) -> [NSRange] {
        edits.reduce([range]) { ranges, edit in
            ranges.flatMap {
                Self.currentRanges(forSnapshotRange: $0, applying: edit)
            }
        }
    }

    package func snapshotRanges(forCurrentRange range: NSRange) -> [NSRange] {
        edits.reversed().reduce([range]) { ranges, edit in
            ranges.flatMap {
                Self.snapshotRanges(forCurrentRange: $0, reverting: edit)
            }
        }
    }

    private static func dirtyRange(for edit: Edit) -> NSRange? {
        if edit.replacementLength > 0 {
            return NSRange(location: edit.location, length: edit.replacementLength)
        }
        guard edit.resultingTextLength > 0 else { return nil }
        return NSRange(location: min(edit.location, edit.resultingTextLength - 1), length: 1)
    }

    private mutating func appendEdit(_ edit: Edit) {
        guard var previous = edits.popLast() else {
            edits.append(edit)
            return
        }

        if previous.length == 0,
           edit.length == 0,
           edit.previousTextLength == previous.resultingTextLength,
           edit.location == previous.location + previous.replacementLength {
            previous.replacementLength += edit.replacementLength
            previous.resultingTextLength = edit.resultingTextLength
            edits.append(previous)
            return
        }

        edits.append(previous)
        edits.append(edit)
    }

    private static func currentRanges(forSnapshotRange range: NSRange, applying edit: Edit) -> [NSRange] {
        let editStart = edit.location
        let editEnd = edit.location + edit.length

        if range.upperBound <= editStart {
            return clampedNonEmpty(range, textLength: edit.resultingTextLength)
        }

        if range.location >= editEnd {
            let shifted = NSRange(location: range.location + edit.delta, length: range.length)
            return clampedNonEmpty(shifted, textLength: edit.resultingTextLength)
        }

        var ranges: [NSRange] = []
        if range.location < editStart {
            ranges.append(NSRange(location: range.location, length: editStart - range.location))
        }
        if range.upperBound > editEnd {
            ranges.append(
                NSRange(
                    location: editStart + edit.replacementLength,
                    length: range.upperBound - editEnd
                )
            )
        }
        return ranges.flatMap { clampedNonEmpty($0, textLength: edit.resultingTextLength) }
    }

    private static func snapshotRanges(forCurrentRange range: NSRange, reverting edit: Edit) -> [NSRange] {
        let editStart = edit.location
        let insertedEnd = edit.location + edit.replacementLength

        if range.upperBound <= editStart {
            return clampedNonEmpty(range, textLength: edit.previousTextLength)
        }

        if range.location >= insertedEnd {
            let shifted = NSRange(location: range.location - edit.delta, length: range.length)
            return clampedNonEmpty(shifted, textLength: edit.previousTextLength)
        }

        var ranges: [NSRange] = []
        if range.location < editStart {
            ranges.append(NSRange(location: range.location, length: editStart - range.location))
        }
        if range.upperBound > insertedEnd {
            ranges.append(
                NSRange(
                    location: insertedEnd - edit.delta,
                    length: range.upperBound - insertedEnd
                )
            )
        }
        return ranges.flatMap { clampedNonEmpty($0, textLength: edit.previousTextLength) }
    }

    private static func clampedNonEmpty(_ range: NSRange, textLength: Int) -> [NSRange] {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: textLength)
        return clamped.length > 0 ? [clamped] : []
    }
}

package struct HighlightVisibleRunResolver {
    private struct SnapshotVisibleMapping {
        let snapshotRange: NSRange
        let currentRange: NSRange
        let delta: Int
    }

    private let snapshot: HighlightRenderSnapshot
    private let pendingEditMap: PendingHighlightEditMap
    private let currentTextLength: Int
    private let currentSuppressionRanges: [NSRange]
    private let checkpointDirtyRanges: [NSRange]
    private let currentColorRuns: [HighlightColorRun]
    private let currentFontRuns: [HighlightFontRun]
    private let currentMaterializedRanges: [NSRange]

    package init(
        snapshot: HighlightRenderSnapshot,
        pendingEditMap: PendingHighlightEditMap,
        currentTextLength: Int,
        currentSuppressionRanges: [NSRange],
        checkpointDirtyRanges: [NSRange],
        currentColorRuns: [HighlightColorRun],
        currentFontRuns: [HighlightFontRun],
        currentMaterializedRanges: [NSRange]
    ) {
        self.snapshot = snapshot
        self.pendingEditMap = pendingEditMap
        self.currentTextLength = max(0, currentTextLength)
        self.currentSuppressionRanges = currentSuppressionRanges
        self.checkpointDirtyRanges = checkpointDirtyRanges
        self.currentColorRuns = currentColorRuns
        self.currentFontRuns = currentFontRuns
        self.currentMaterializedRanges = currentMaterializedRanges
    }

    package func forEachColorRun(
        in currentRange: NSRange,
        _ body: (HighlightColorRun) -> Void
    ) {
        forEachCurrentColorRun(in: currentRange) { run in
            body(HighlightColorRun(range: run.range, color: run.color))
        }

        forEachCurrentColorVisibleRange(in: currentRange) { visibleRange in
            if let mappings = snapshotVisibleMappings(forCurrentVisibleRange: visibleRange) {
                for mapping in mappings {
                    HighlightRunUtilities.forEachColorRun(snapshot.colorRuns, in: mapping.snapshotRange) { run in
                        let shiftedRange = NSRange(
                            location: run.range.location + mapping.delta,
                            length: run.range.length
                        )
                        let intersection = SyntaxEditorRangeUtilities.intersection(
                            of: shiftedRange,
                            and: mapping.currentRange
                        )
                        guard intersection.length > 0 else { return }
                        body(HighlightColorRun(range: intersection, color: run.color))
                    }
                }
            } else {
                for snapshotRange in snapshotRanges(forCurrentVisibleRange: visibleRange) {
                    HighlightRunUtilities.forEachColorRun(snapshot.colorRuns, in: snapshotRange) { run in
                        for currentRunRange in pendingEditMap.currentRanges(forSnapshotRange: run.range) {
                            let intersection = SyntaxEditorRangeUtilities.intersection(of: currentRunRange, and: visibleRange)
                            guard intersection.length > 0 else { continue }
                            body(HighlightColorRun(range: intersection, color: run.color))
                        }
                    }
                }
            }
        }
    }

    package func forEachFontRun(
        in currentRange: NSRange,
        _ body: (HighlightFontRun) -> Void
    ) {
        forEachCurrentFontRun(in: currentRange) { run in
            body(HighlightFontRun(range: run.range, font: run.font))
        }

        forEachCurrentFontVisibleRange(in: currentRange) { visibleRange in
            if let mappings = snapshotVisibleMappings(forCurrentVisibleRange: visibleRange) {
                for mapping in mappings {
                    HighlightRunUtilities.forEachFontRun(snapshot.fontRuns, in: mapping.snapshotRange) { run in
                        let shiftedRange = NSRange(
                            location: run.range.location + mapping.delta,
                            length: run.range.length
                        )
                        let intersection = SyntaxEditorRangeUtilities.intersection(
                            of: shiftedRange,
                            and: mapping.currentRange
                        )
                        guard intersection.length > 0 else { return }
                        body(HighlightFontRun(range: intersection, font: run.font))
                    }
                }
            } else {
                for snapshotRange in snapshotRanges(forCurrentVisibleRange: visibleRange) {
                    HighlightRunUtilities.forEachFontRun(snapshot.fontRuns, in: snapshotRange) { run in
                        for currentRunRange in pendingEditMap.currentRanges(forSnapshotRange: run.range) {
                            let intersection = SyntaxEditorRangeUtilities.intersection(of: currentRunRange, and: visibleRange)
                            guard intersection.length > 0 else { continue }
                            body(HighlightFontRun(range: intersection, font: run.font))
                        }
                    }
                }
            }
        }
    }

    private func forEachCurrentColorRun(
        in currentRange: NSRange,
        _ body: (HighlightColorRun) -> Void
    ) {
        let visibleRanges = currentColorVisibleRangesForMaterializedRuns(in: currentRange)
        for visibleRange in visibleRanges {
            HighlightRunUtilities.forEachColorRun(currentColorRuns, in: visibleRange, body)
        }
    }

    private func forEachCurrentFontRun(
        in currentRange: NSRange,
        _ body: (HighlightFontRun) -> Void
    ) {
        let visibleRanges = currentFontVisibleRangesForMaterializedRuns(in: currentRange)
        for visibleRange in visibleRanges {
            HighlightRunUtilities.forEachFontRun(currentFontRuns, in: visibleRange, body)
        }
    }

    private func currentColorVisibleRangesForMaterializedRuns(in currentRange: NSRange) -> [NSRange] {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(currentRange, utf16Length: currentTextLength)
        guard clamped.length > 0 else { return [] }
        return HighlightRunUtilities.rangesBySubtracting(currentSuppressionRanges, from: clamped)
    }

    private func currentFontVisibleRangesForMaterializedRuns(in currentRange: NSRange) -> [NSRange] {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(currentRange, utf16Length: currentTextLength)
        return clamped.length > 0 ? [clamped] : []
    }

    private func forEachCurrentColorVisibleRange(
        in currentRange: NSRange,
        _ body: (NSRange) -> Void
    ) {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(currentRange, utf16Length: currentTextLength)
        guard clamped.length > 0 else { return }

        let suppressedRanges = HighlightRunUtilities.normalizedRanges(
            pendingEditMap.visibleDirtyRanges + checkpointDirtyRanges + currentSuppressionRanges + currentMaterializedRanges,
            textLength: currentTextLength
        )
        for visibleRange in HighlightRunUtilities.rangesBySubtracting(suppressedRanges, from: clamped) {
            body(visibleRange)
        }
    }

    private func forEachCurrentFontVisibleRange(
        in currentRange: NSRange,
        _ body: (NSRange) -> Void
    ) {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(currentRange, utf16Length: currentTextLength)
        guard clamped.length > 0 else { return }

        let suppressedRanges = HighlightRunUtilities.normalizedRanges(
            pendingEditMap.visibleDirtyRanges + checkpointDirtyRanges + currentMaterializedRanges,
            textLength: currentTextLength
        )
        for visibleRange in HighlightRunUtilities.rangesBySubtracting(suppressedRanges, from: clamped) {
            body(visibleRange)
        }
    }

    private func snapshotRanges(forCurrentVisibleRange range: NSRange) -> [NSRange] {
        if pendingEditMap.isEmpty {
            return [SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: snapshot.textLength)]
                .filter { $0.length > 0 }
        }
        return pendingEditMap.snapshotRanges(forCurrentRange: range)
    }

    private func snapshotVisibleMappings(forCurrentVisibleRange range: NSRange) -> [SnapshotVisibleMapping]? {
        if pendingEditMap.isEmpty {
            let snapshotRange = SyntaxEditorRangeUtilities.clampedRange(range, utf16Length: snapshot.textLength)
            guard snapshotRange.length > 0 else { return [] }
            return [
                SnapshotVisibleMapping(
                    snapshotRange: snapshotRange,
                    currentRange: range,
                    delta: range.location - snapshotRange.location
                ),
            ]
        }

        let snapshotRanges = pendingEditMap.snapshotRanges(forCurrentRange: range)
        var mappings: [SnapshotVisibleMapping] = []
        mappings.reserveCapacity(snapshotRanges.count)

        for snapshotRange in snapshotRanges {
            let currentRanges = pendingEditMap.currentRanges(forSnapshotRange: snapshotRange)
                .map { SyntaxEditorRangeUtilities.intersection(of: $0, and: range) }
                .filter { $0.length > 0 }
            guard currentRanges.count == 1,
                  let currentRange = currentRanges.first,
                  currentRange.length == snapshotRange.length
            else {
                return nil
            }
            mappings.append(
                SnapshotVisibleMapping(
                    snapshotRange: snapshotRange,
                    currentRange: currentRange,
                    delta: currentRange.location - snapshotRange.location
                )
            )
        }

        return mappings
    }
}

package struct HighlightResolvedVisibleRuns {
    package let colorRuns: [HighlightColorRun]
    package let fontRuns: [HighlightFontRun]
}

private struct OptimisticHighlightRunSet {
    let range: NSRange
    let color: SyntaxEditorTheme.Color?
    let font: SyntaxEditorTheme.Font?
}

@MainActor
package final class HighlightRenderSnapshotStore {
    package private(set) var generation = 0
    package var epoch: Int { generation }
    package private(set) var snapshot: HighlightRenderSnapshot = .empty

    private var pendingEditMap = PendingHighlightEditMap()
    private var currentTextLength = 0
    private var currentSuppressionRanges: [NSRange] = []
    private var checkpointDirtyRanges: [NSRange] = []
    private var currentColorRuns: [HighlightColorRun] = []
    private var currentFontRuns: [HighlightFontRun] = []
    private var currentMaterializedRanges: [NSRange] = []

    package var baseForeground: SyntaxEditorTheme.Color? {
        snapshot.baseForeground
    }

    package var appliedColorRunsForTesting: [HighlightColorRun] {
        snapshot.colorRuns
    }

    package var appliedFontRunsForTesting: [HighlightFontRun] {
        snapshot.fontRuns
    }

    package var pendingDirtyRangesForTesting: [NSRange] {
        pendingEditMap.visibleDirtyRanges
    }

    package var checkpointDirtyRangesForTesting: [NSRange] {
        checkpointDirtyRanges
    }

    package var pendingEditCountForTesting: Int {
        pendingEditMap.editCountForTesting
    }

    package var hasPendingEditsForTesting: Bool {
        !pendingEditMap.isEmpty
    }

    package var hasMaterializedRuns: Bool {
        !snapshot.colorRuns.isEmpty || !snapshot.fontRuns.isEmpty || !currentColorRuns.isEmpty || !currentFontRuns.isEmpty
    }

    package var maintainsNormalizedRunInvariantForTesting: Bool {
        HighlightRunUtilities.colorRunsAreNormalized(currentColorRuns, textLength: currentTextLength)
            && HighlightRunUtilities.fontRunsAreNormalized(currentFontRuns, textLength: currentTextLength)
            && HighlightRunUtilities.rangesAreNormalized(currentSuppressionRanges, textLength: currentTextLength)
            && HighlightRunUtilities.rangesAreNormalized(checkpointDirtyRanges, textLength: currentTextLength)
            && HighlightRunUtilities.rangesAreNormalized(currentMaterializedRanges, textLength: currentTextLength)
    }

    package func colorRuns(in range: NSRange) -> [HighlightColorRun] {
        var runs: [HighlightColorRun] = []
        forEachColorRun(in: range) { runs.append($0) }
        return HighlightRunUtilities.coalescedColorRuns(runs)
    }

    package func foregroundColor(at location: Int) -> SyntaxEditorTheme.Color? {
        guard location >= 0, location < currentTextLength else { return nil }
        var color: SyntaxEditorTheme.Color?
        forEachColorRun(in: NSRange(location: location, length: 1)) { run in
            color = run.color
        }
        return color
    }

    package func font(at location: Int) -> SyntaxEditorTheme.Font? {
        guard location >= 0, location < currentTextLength else { return nil }
        var font: SyntaxEditorTheme.Font?
        forEachFontRun(in: NSRange(location: location, length: 1)) { run in
            font = run.font
        }
        return font
    }

    package func effectiveForegroundColor(at location: Int) -> SyntaxEditorTheme.Color? {
        foregroundColor(at: location) ?? baseForeground
    }

    package func updateBaseForeground(_ color: SyntaxEditorTheme.Color?, textLength nextTextLength: Int? = nil) {
        let nextTextLength = nextTextLength.map { max(0, $0) } ?? currentTextLength
        let baseChanged: Bool
        switch (snapshot.baseForeground, color) {
        case (.none, .none):
            baseChanged = false
        case let (.some(lhs), .some(rhs)):
            baseChanged = !lhs.isEqual(rhs)
        default:
            baseChanged = true
        }

        let textLengthChanged = currentTextLength != nextTextLength
        currentTextLength = nextTextLength
        if baseChanged || textLengthChanged {
            snapshot = HighlightRenderSnapshot(
                revision: snapshot.revision,
                language: snapshot.language,
                textLength: snapshot.textLength,
                baseForeground: color,
                baseFont: snapshot.baseFont,
                colorRuns: snapshot.colorRuns,
                fontRuns: snapshot.fontRuns,
                suppressionRanges: snapshot.suppressionRanges
            )
            generation += 1
        }
    }

    @discardableResult
    package func updateBaseFont(
        _ font: SyntaxEditorTheme.Font?,
        textLength nextTextLength: Int? = nil,
        clearsFontRuns: Bool = false
    ) -> [NSRange] {
        let nextTextLength = nextTextLength.map { max(0, $0) } ?? currentTextLength
        let baseChanged: Bool
        switch (snapshot.baseFont, font) {
        case (.none, .none):
            baseChanged = false
        case let (.some(lhs), .some(rhs)):
            baseChanged = !lhs.isEqual(rhs)
        default:
            baseChanged = true
        }

        let invalidatedFontRanges: [NSRange]
        if clearsFontRuns {
            let snapshotFontRanges = snapshot.fontRuns.flatMap { run in
                pendingEditMap.currentRanges(forSnapshotRange: run.range)
            }
            invalidatedFontRanges = HighlightRunUtilities.normalizedRanges(
                snapshotFontRanges + currentFontRuns.map(\.range),
                textLength: nextTextLength
            )
        } else {
            invalidatedFontRanges = []
        }
        let nextFontRuns = clearsFontRuns ? [] : snapshot.fontRuns
        let clearsCurrentFontRuns = clearsFontRuns && !currentFontRuns.isEmpty
        let textLengthChanged = currentTextLength != nextTextLength
        currentTextLength = nextTextLength
        guard baseChanged || textLengthChanged || nextFontRuns.count != snapshot.fontRuns.count || clearsCurrentFontRuns else {
            return invalidatedFontRanges
        }

        snapshot = HighlightRenderSnapshot(
            revision: snapshot.revision,
            language: snapshot.language,
            textLength: pendingEditMap.isEmpty ? nextTextLength : snapshot.textLength,
            baseForeground: snapshot.baseForeground,
            baseFont: font,
            colorRuns: snapshot.colorRuns,
            fontRuns: nextFontRuns,
            suppressionRanges: snapshot.suppressionRanges
        )
        if clearsFontRuns {
            currentFontRuns = []
        }
        generation += 1
        return invalidatedFontRanges
    }

    package func forEachColorRun(
        in range: NSRange,
        _ body: (HighlightColorRun) -> Void
    ) {
        resolver().forEachColorRun(in: range, body)
    }

    package func forEachFontRun(
        in range: NSRange,
        _ body: (HighlightFontRun) -> Void
    ) {
        resolver().forEachFontRun(in: range, body)
    }

    package func resolveVisibleRuns(in range: NSRange) -> HighlightResolvedVisibleRuns {
        let resolver = resolver()
        var colorRuns: [HighlightColorRun] = []
        var fontRuns: [HighlightFontRun] = []
        resolver.forEachColorRun(in: range) { colorRuns.append($0) }
        resolver.forEachFontRun(in: range) { fontRuns.append($0) }
        return HighlightResolvedVisibleRuns(colorRuns: colorRuns, fontRuns: fontRuns)
    }

    @discardableResult
    package func commitSnapshot(
        runSet: HighlightRunSet,
        range refreshedRange: NSRange,
        revision: Int?,
        language: SyntaxLanguage?,
        textLength nextTextLength: Int,
        baseForeground: SyntaxEditorTheme.Color,
        baseFont: SyntaxEditorTheme.Font?,
        suppressionRanges nextSuppressionRanges: [NSRange] = []
    ) -> [NSRange] {
        let nextTextLength = max(0, nextTextLength)
        let clearedDirtyRanges = HighlightRunUtilities.normalizedRanges(
            pendingEditMap.visibleDirtyRanges,
            textLength: nextTextLength
        )
        let clampedRefreshRange = SyntaxEditorRangeUtilities.clampedRange(
            refreshedRange,
            utf16Length: nextTextLength
        )
        let normalizedSuppressionRanges = HighlightRunUtilities.normalizedRanges(
            nextSuppressionRanges,
            textLength: nextTextLength
        )

        var nextColorRuns = snapshot.colorRuns
        var nextFontRuns = snapshot.fontRuns
        let normalizedColorRuns = HighlightRunUtilities.clippedColorRuns(
            HighlightRunUtilities.coalescedColorRuns(
                HighlightRunUtilities.normalizedColorRuns(runSet.colorRuns, textLength: nextTextLength)
            ),
            to: clampedRefreshRange
        )
        let normalizedFontRuns = HighlightRunUtilities.clippedFontRuns(
            HighlightRunUtilities.coalescedFontRuns(
                HighlightRunUtilities.normalizedFontRuns(runSet.fontRuns, textLength: nextTextLength)
            ),
            to: clampedRefreshRange
        )

        if !pendingEditMap.isEmpty, !clampedRefreshRange.coversFullText(length: nextTextLength) {
            HighlightRunUtilities.replaceColorRuns(&currentColorRuns, in: clampedRefreshRange, with: normalizedColorRuns)
            HighlightRunUtilities.replaceFontRuns(&currentFontRuns, in: clampedRefreshRange, with: normalizedFontRuns)
            removeCheckpointDirtyRanges(in: clampedRefreshRange, textLength: nextTextLength)
            currentMaterializedRanges = HighlightRunUtilities.normalizedRanges(
                currentMaterializedRanges + [clampedRefreshRange],
                textLength: nextTextLength
            )
            currentTextLength = nextTextLength
            currentSuppressionRanges = normalizedSuppressionRanges
            generation += 1
            return []
        }

        HighlightRunUtilities.replaceColorRuns(&nextColorRuns, in: clampedRefreshRange, with: normalizedColorRuns)
        HighlightRunUtilities.replaceFontRuns(&nextFontRuns, in: clampedRefreshRange, with: normalizedFontRuns)

        snapshot = HighlightRenderSnapshot(
            revision: revision,
            language: language,
            textLength: nextTextLength,
            baseForeground: baseForeground,
            baseFont: baseFont,
            colorRuns: nextColorRuns,
            fontRuns: nextFontRuns,
            suppressionRanges: normalizedSuppressionRanges
        )
        currentTextLength = nextTextLength
        currentSuppressionRanges = normalizedSuppressionRanges
        pendingEditMap.clear()
        if clampedRefreshRange.coversFullText(length: nextTextLength) {
            checkpointDirtyRanges = []
        } else {
            removeCheckpointDirtyRanges(in: clampedRefreshRange, textLength: nextTextLength)
        }
        currentColorRuns = []
        currentFontRuns = []
        currentMaterializedRanges = []
        generation += 1
        return clearedDirtyRanges
    }

    /// Pending-edit checkpoint threshold: scattered (non-coalescing) edits grow
    /// the map and every snapshot-range mapping costs O(#edits); the engine
    /// delivers narrow refreshes by design, so the map never clears on its own.
    package static let pendingEditCheckpointThreshold = 64
    /// Test-only override (serial test execution).
    nonisolated(unsafe) package static var pendingEditCheckpointThresholdOverrideForTesting: Int?

    package func recordPendingEdit(
        _ mutation: SyntaxEditorTextChange.Replacement,
        currentTextLength nextTextLength: Int
    ) {
        let nextTextLength = max(0, nextTextLength)
        let optimisticRunSet = optimisticHighlightRunSet(
            for: mutation,
            currentTextLength: nextTextLength
        )
        shiftCurrentRuns(for: mutation, currentTextLength: nextTextLength)
        currentTextLength = nextTextLength
        pendingEditMap.recordPendingEdit(mutation, currentTextLength: currentTextLength)
        applyOptimisticHighlightRunSet(optimisticRunSet)
        checkpointPendingEditsIfNeeded()
        generation += 1
    }

    private func optimisticHighlightRunSet(
        for mutation: SyntaxEditorTextChange.Replacement,
        currentTextLength nextTextLength: Int
    ) -> OptimisticHighlightRunSet? {
        let replacementLength = mutation.replacement.utf16.count
        guard mutation.length == 0,
              replacementLength > 0,
              Self.canOptimisticallyStyleInsertedText(mutation.replacement)
        else {
            return nil
        }

        let previousTextLength = max(0, nextTextLength - replacementLength)
        guard previousTextLength > 0 else { return nil }
        let location = min(max(0, mutation.location), previousTextLength)
        let color = inheritedForegroundColorForInsertion(
            at: location,
            previousTextLength: previousTextLength
        )
        let font = inheritedFontForInsertion(
            at: location,
            previousTextLength: previousTextLength
        )
        guard color != nil || font != nil else { return nil }

        return OptimisticHighlightRunSet(
            range: NSRange(location: location, length: replacementLength),
            color: color,
            font: font
        )
    }

    private static func canOptimisticallyStyleInsertedText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return false
            }
        }
        return !text.isEmpty
    }

    private func inheritedForegroundColorForInsertion(
        at location: Int,
        previousTextLength: Int
    ) -> SyntaxEditorTheme.Color? {
        if location > 0,
           let color = foregroundColor(at: location - 1) {
            return color
        }
        if location < previousTextLength {
            return foregroundColor(at: location)
        }
        return nil
    }

    private func inheritedFontForInsertion(
        at location: Int,
        previousTextLength: Int
    ) -> SyntaxEditorTheme.Font? {
        if location > 0,
           let font = font(at: location - 1) {
            return font
        }
        if location < previousTextLength {
            return font(at: location)
        }
        return nil
    }

    private func applyOptimisticHighlightRunSet(_ runSet: OptimisticHighlightRunSet?) {
        guard let runSet else { return }
        let range = SyntaxEditorRangeUtilities.clampedRange(
            runSet.range,
            utf16Length: currentTextLength
        )
        guard range.length > 0 else { return }

        if let color = runSet.color {
            HighlightRunUtilities.replaceColorRuns(
                &currentColorRuns,
                in: range,
                with: [HighlightColorRun(range: range, color: color)]
            )
        }
        if let font = runSet.font {
            HighlightRunUtilities.replaceFontRuns(
                &currentFontRuns,
                in: range,
                with: [HighlightFontRun(range: range, font: font)]
            )
        }
    }

    /// Folds the snapshot, the pending-edit map, and the partially materialized
    /// runs into a fresh snapshot in CURRENT coordinates. The resolver's output
    /// is identical before and after: dirty ranges keep only any current
    /// overlays, such as optimistic insert runs or completed partial refreshes,
    /// and repaint when the engine's refresh debt covers them. Deferred while
    /// suppression ranges exist — lifting a suppression (IME composition end)
    /// must re-expose the underlying colors, which a fold would have baked away.
    private func checkpointPendingEditsIfNeeded() {
        let threshold = unsafe Self.pendingEditCheckpointThresholdOverrideForTesting
            ?? Self.pendingEditCheckpointThreshold
        guard pendingEditMap.editCountForTesting > threshold,
              currentSuppressionRanges.isEmpty
        else {
            return
        }

        let fullRange = NSRange(location: 0, length: currentTextLength)
        let resolved = resolver()
        var colorRuns: [HighlightColorRun] = []
        var fontRuns: [HighlightFontRun] = []
        resolved.forEachColorRun(in: fullRange) { colorRuns.append($0) }
        resolved.forEachFontRun(in: fullRange) { fontRuns.append($0) }

        snapshot = HighlightRenderSnapshot(
            revision: snapshot.revision,
            language: snapshot.language,
            textLength: currentTextLength,
            baseForeground: snapshot.baseForeground,
            baseFont: snapshot.baseFont,
            colorRuns: colorRuns,
            fontRuns: fontRuns,
            suppressionRanges: []
        )
        checkpointDirtyRanges = unresolvedCheckpointDirtyRangesAfterCheckpoint(textLength: currentTextLength)
        pendingEditMap.clear()
        currentColorRuns = []
        currentFontRuns = []
        currentMaterializedRanges = []
    }

    /// Shifts current overlay runs through one edit in place. These runs can be
    /// completed progressive refreshes or short-lived optimistic insert runs.
    /// The splice touches only the runs intersecting the edit plus one tail
    /// offset pass; the mapping semantics mirror `PendingHighlightEditMap`'s
    /// single-edit rules exactly.
    private func shiftCurrentRuns(
        for mutation: SyntaxEditorTextChange.Replacement,
        currentTextLength nextTextLength: Int
    ) {
        guard !currentColorRuns.isEmpty
                || !currentFontRuns.isEmpty
                || !checkpointDirtyRanges.isEmpty
                || !currentMaterializedRanges.isEmpty
        else { return }

        // Same clamping as PendingHighlightEditMap.recordPendingEdit.
        let replacementLength = mutation.replacement.utf16.count
        let previousTextLength = max(0, nextTextLength - (replacementLength - mutation.length))
        let editStart = min(max(0, mutation.location), previousTextLength)
        let editLength = min(max(0, mutation.length), previousTextLength - editStart)
        let editEnd = editStart + editLength
        let delta = replacementLength - editLength
        HighlightRunUtilities.spliceEditIntoColorRuns(
            &currentColorRuns,
            editStart: editStart,
            editEnd: editEnd,
            delta: delta
        )
        HighlightRunUtilities.spliceEditIntoFontRuns(
            &currentFontRuns,
            editStart: editStart,
            editEnd: editEnd,
            delta: delta
        )
        HighlightRunUtilities.spliceEditIntoRanges(
            &checkpointDirtyRanges,
            editStart: editStart,
            editEnd: editEnd,
            delta: delta
        )
        HighlightRunUtilities.spliceEditIntoRanges(
            &currentMaterializedRanges,
            editStart: editStart,
            editEnd: editEnd,
            delta: delta
        )
    }

    private func unresolvedCheckpointDirtyRangesAfterCheckpoint(textLength: Int) -> [NSRange] {
        let resolvedRanges = HighlightRunUtilities.normalizedRanges(
            currentColorRuns.map(\.range) + currentFontRuns.map(\.range) + currentMaterializedRanges,
            textLength: textLength
        )
        let unresolved = pendingEditMap.visibleDirtyRanges.flatMap { dirtyRange in
            HighlightRunUtilities.rangesBySubtracting(resolvedRanges, from: dirtyRange)
        }
        return HighlightRunUtilities.normalizedRanges(
            checkpointDirtyRanges + unresolved,
            textLength: textLength
        )
    }

    private func removeCheckpointDirtyRanges(in refreshedRange: NSRange, textLength: Int) {
        let clampedRefreshRange = SyntaxEditorRangeUtilities.clampedRange(
            refreshedRange,
            utf16Length: textLength
        )
        guard clampedRefreshRange.length > 0,
              !checkpointDirtyRanges.isEmpty
        else {
            return
        }

        checkpointDirtyRanges = HighlightRunUtilities.normalizedRanges(
            checkpointDirtyRanges.flatMap {
                HighlightRunUtilities.rangesBySubtracting([clampedRefreshRange], from: $0)
            },
            textLength: textLength
        )
    }

    package func updateSuppressionRanges(_ suppressionRanges: [NSRange], textLength nextTextLength: Int? = nil) {
        if let nextTextLength {
            currentTextLength = max(0, nextTextLength)
        }
        let normalized = HighlightRunUtilities.normalizedRanges(
            suppressionRanges,
            textLength: currentTextLength
        )
        guard normalized != currentSuppressionRanges else { return }
        currentSuppressionRanges = normalized
        generation += 1
    }

    package func clear(
        textLength nextTextLength: Int,
        baseForeground: SyntaxEditorTheme.Color,
        baseFont: SyntaxEditorTheme.Font?
    ) {
        let nextTextLength = max(0, nextTextLength)
        snapshot = HighlightRenderSnapshot(
            revision: nil,
            language: nil,
            textLength: nextTextLength,
            baseForeground: baseForeground,
            baseFont: baseFont,
            colorRuns: [],
            fontRuns: [],
            suppressionRanges: []
        )
        currentTextLength = nextTextLength
        currentSuppressionRanges = []
        pendingEditMap.clear()
        checkpointDirtyRanges = []
        currentColorRuns = []
        currentFontRuns = []
        currentMaterializedRanges = []
        generation += 1
    }

    package func reset(textLength nextTextLength: Int) {
        let nextTextLength = max(0, nextTextLength)
        snapshot = HighlightRenderSnapshot(
            revision: nil,
            language: nil,
            textLength: nextTextLength,
            baseForeground: snapshot.baseForeground,
            baseFont: snapshot.baseFont,
            colorRuns: [],
            fontRuns: [],
            suppressionRanges: []
        )
        currentTextLength = nextTextLength
        currentSuppressionRanges = []
        pendingEditMap.clear()
        checkpointDirtyRanges = []
        currentColorRuns = []
        currentFontRuns = []
        currentMaterializedRanges = []
        generation += 1
    }

    private func resolver() -> HighlightVisibleRunResolver {
        HighlightVisibleRunResolver(
            snapshot: snapshot,
            pendingEditMap: pendingEditMap,
            currentTextLength: currentTextLength,
            currentSuppressionRanges: currentSuppressionRanges,
            checkpointDirtyRanges: checkpointDirtyRanges,
            currentColorRuns: currentColorRuns,
            currentFontRuns: currentFontRuns,
            currentMaterializedRanges: currentMaterializedRanges
        )
    }
}

private extension NSRange {
    func coversFullText(length textLength: Int) -> Bool {
        location == 0 && length == textLength
    }
}

fileprivate enum HighlightRunUtilities {
    static func normalizedColorRuns(
        _ runs: [HighlightColorRun],
        textLength: Int
    ) -> [HighlightColorRun] {
        runs
            .map { run in
                HighlightColorRun(
                    range: SyntaxEditorRangeUtilities.clampedRange(run.range, utf16Length: textLength),
                    color: run.color
                )
            }
            .filter { $0.range.length > 0 }
            .sorted(by: sortColorRun)
    }

    static func normalizedFontRuns(
        _ runs: [HighlightFontRun],
        textLength: Int
    ) -> [HighlightFontRun] {
        runs
            .map { run in
                HighlightFontRun(
                    range: SyntaxEditorRangeUtilities.clampedRange(run.range, utf16Length: textLength),
                    font: run.font
                )
            }
            .filter { $0.range.length > 0 }
            .sorted(by: sortFontRun)
    }

    static func normalizedRanges(_ ranges: [NSRange], textLength: Int) -> [NSRange] {
        coalescedRanges(
            ranges
                .map { SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: textLength) }
                .filter { $0.length > 0 }
                .sorted { lhs, rhs in
                    if lhs.location == rhs.location {
                        lhs.length < rhs.length
                    } else {
                        lhs.location < rhs.location
                    }
                }
        )
    }

    static func coalescedRanges(_ ranges: [NSRange]) -> [NSRange] {
        var coalescedRanges: [NSRange] = []
        coalescedRanges.reserveCapacity(ranges.count)

        for range in ranges {
            if let last = coalescedRanges.last,
               last.upperBound >= range.location {
                let lowerBound = min(last.location, range.location)
                let upperBound = max(last.upperBound, range.upperBound)
                coalescedRanges[coalescedRanges.count - 1] = NSRange(
                    location: lowerBound,
                    length: upperBound - lowerBound
                )
            } else {
                coalescedRanges.append(range)
            }
        }

        return coalescedRanges
    }

    static func clippedColorRuns(
        _ runs: [HighlightColorRun],
        to range: NSRange
    ) -> [HighlightColorRun] {
        guard range.length > 0 else { return [] }
        let startIndex = firstColorRunIndex(intersecting: range, in: runs)
        var clippedRuns: [HighlightColorRun] = []
        clippedRuns.reserveCapacity(min(runs.count - startIndex, 128))

        for run in runs[startIndex...] {
            guard run.range.location < range.upperBound else { break }
            let intersection = SyntaxEditorRangeUtilities.intersection(of: run.range, and: range)
            guard intersection.length > 0 else { continue }
            clippedRuns.append(HighlightColorRun(range: intersection, color: run.color))
        }

        return coalescedColorRuns(clippedRuns)
    }

    static func clippedFontRuns(
        _ runs: [HighlightFontRun],
        to range: NSRange
    ) -> [HighlightFontRun] {
        guard range.length > 0 else { return [] }
        let startIndex = firstFontRunIndex(intersecting: range, in: runs)
        var clippedRuns: [HighlightFontRun] = []
        clippedRuns.reserveCapacity(min(runs.count - startIndex, 128))

        for run in runs[startIndex...] {
            guard run.range.location < range.upperBound else { break }
            let intersection = SyntaxEditorRangeUtilities.intersection(of: run.range, and: range)
            guard intersection.length > 0 else { continue }
            clippedRuns.append(HighlightFontRun(range: intersection, font: run.font))
        }

        return coalescedFontRuns(clippedRuns)
    }

    static func replaceColorRuns(
        _ runs: inout [HighlightColorRun],
        in range: NSRange,
        with replacementRuns: [HighlightColorRun]
    ) {
        guard range.length > 0 else { return }
        let startIndex = firstColorRunIndex(intersecting: range, in: runs)
        var endIndex = startIndex
        while endIndex < runs.count, runs[endIndex].range.location < range.upperBound {
            endIndex += 1
        }

        var insertedRuns: [HighlightColorRun] = []
        insertedRuns.reserveCapacity(replacementRuns.count + 2)
        if startIndex < endIndex {
            let firstRun = runs[startIndex]
            if firstRun.range.location < range.location {
                insertedRuns.append(
                    HighlightColorRun(
                        range: NSRange(
                            location: firstRun.range.location,
                            length: range.location - firstRun.range.location
                        ),
                        color: firstRun.color
                    )
                )
            }
            let lastRun = runs[endIndex - 1]
            if lastRun.range.upperBound > range.upperBound {
                insertedRuns.append(
                    HighlightColorRun(
                        range: NSRange(
                            location: range.upperBound,
                            length: lastRun.range.upperBound - range.upperBound
                        ),
                        color: lastRun.color
                    )
                )
            }
        }

        insertedRuns.append(contentsOf: replacementRuns)
        let replacementCount = insertedRuns.count
        runs.replaceSubrange(startIndex..<endIndex, with: insertedRuns.sorted(by: sortColorRun))
        coalesceColorRunsAround(&runs, startIndex: startIndex, replacementCount: replacementCount)
    }

    static func replaceFontRuns(
        _ runs: inout [HighlightFontRun],
        in range: NSRange,
        with replacementRuns: [HighlightFontRun]
    ) {
        guard range.length > 0 else { return }
        let startIndex = firstFontRunIndex(intersecting: range, in: runs)
        var endIndex = startIndex
        while endIndex < runs.count, runs[endIndex].range.location < range.upperBound {
            endIndex += 1
        }

        var insertedRuns: [HighlightFontRun] = []
        insertedRuns.reserveCapacity(replacementRuns.count + 2)
        if startIndex < endIndex {
            let firstRun = runs[startIndex]
            if firstRun.range.location < range.location {
                insertedRuns.append(
                    HighlightFontRun(
                        range: NSRange(
                            location: firstRun.range.location,
                            length: range.location - firstRun.range.location
                        ),
                        font: firstRun.font
                    )
                )
            }
            let lastRun = runs[endIndex - 1]
            if lastRun.range.upperBound > range.upperBound {
                insertedRuns.append(
                    HighlightFontRun(
                        range: NSRange(
                            location: range.upperBound,
                            length: lastRun.range.upperBound - range.upperBound
                        ),
                        font: lastRun.font
                    )
                )
            }
        }

        insertedRuns.append(contentsOf: replacementRuns)
        let replacementCount = insertedRuns.count
        runs.replaceSubrange(startIndex..<endIndex, with: insertedRuns.sorted(by: sortFontRun))
        coalesceFontRunsAround(&runs, startIndex: startIndex, replacementCount: replacementCount)
    }

    static func forEachColorRun(
        _ runs: [HighlightColorRun],
        in range: NSRange,
        _ body: (HighlightColorRun) -> Void
    ) {
        guard range.length > 0 else { return }
        let startIndex = firstColorRunIndex(intersecting: range, in: runs)
        for run in runs[startIndex...] {
            guard run.range.location < range.upperBound else { break }
            let intersection = SyntaxEditorRangeUtilities.intersection(of: run.range, and: range)
            guard intersection.length > 0 else { continue }
            body(HighlightColorRun(range: intersection, color: run.color))
        }
    }

    static func forEachFontRun(
        _ runs: [HighlightFontRun],
        in range: NSRange,
        _ body: (HighlightFontRun) -> Void
    ) {
        guard range.length > 0 else { return }
        let startIndex = firstFontRunIndex(intersecting: range, in: runs)
        for run in runs[startIndex...] {
            guard run.range.location < range.upperBound else { break }
            let intersection = SyntaxEditorRangeUtilities.intersection(of: run.range, and: range)
            guard intersection.length > 0 else { continue }
            body(HighlightFontRun(range: intersection, font: run.font))
        }
    }

    /// In-place single-edit splice over sorted, non-overlapping, coalesced
    /// runs: the prefix is untouched, runs intersecting the replaced region
    /// split into their kept outsides (the replaced region itself is dropped),
    /// and the suffix shifts by `delta` with one tight pass. Equal-value runs
    /// made adjacent at the junction re-coalesce locally, preserving the
    /// `colorRunsAreNormalized` invariant without rebuilding the array.
    static func spliceEditIntoColorRuns(
        _ runs: inout [HighlightColorRun],
        editStart: Int,
        editEnd: Int,
        delta: Int
    ) {
        guard !runs.isEmpty else { return }
        let firstAffected = firstIndex(in: runs, whereUpperBoundExceeds: editStart) { $0.range }
        var firstSuffix = firstAffected
        while firstSuffix < runs.count, runs[firstSuffix].range.location < editEnd {
            firstSuffix += 1
        }

        if delta != 0, firstSuffix < runs.count {
            unsafe runs.withUnsafeMutableBufferPointer { buffer in
                var index = firstSuffix
                while index < buffer.count {
                    unsafe buffer[index].range.location += delta
                    index += 1
                }
            }
        }

        var pieces: [HighlightColorRun] = []
        pieces.reserveCapacity((firstSuffix - firstAffected) * 2)
        var index = firstAffected
        while index < firstSuffix {
            let run = runs[index]
            if run.range.location < editStart {
                pieces.append(HighlightColorRun(
                    range: NSRange(location: run.range.location, length: editStart - run.range.location),
                    color: run.color
                ))
            }
            if run.range.upperBound > editEnd {
                pieces.append(HighlightColorRun(
                    range: NSRange(location: editEnd + delta, length: run.range.upperBound - editEnd),
                    color: run.color
                ))
            }
            index += 1
        }
        if firstAffected < firstSuffix || !pieces.isEmpty {
            runs.replaceSubrange(firstAffected..<firstSuffix, with: pieces)
        }

        // Junction coalesce: only the window around the splice can have gained
        // equal-color adjacency.
        var cursor = max(0, firstAffected - 1)
        var windowEnd = min(runs.count, firstAffected + pieces.count + 1)
        while cursor + 1 < windowEnd {
            let previous = runs[cursor]
            let next = runs[cursor + 1]
            if previous.color.isEqual(next.color), previous.range.upperBound >= next.range.location {
                let lowerBound = min(previous.range.location, next.range.location)
                let upperBound = max(previous.range.upperBound, next.range.upperBound)
                runs[cursor].range = NSRange(location: lowerBound, length: upperBound - lowerBound)
                runs.remove(at: cursor + 1)
                windowEnd -= 1
            } else {
                cursor += 1
            }
        }
    }

    static func spliceEditIntoFontRuns(
        _ runs: inout [HighlightFontRun],
        editStart: Int,
        editEnd: Int,
        delta: Int
    ) {
        guard !runs.isEmpty else { return }
        let firstAffected = firstIndex(in: runs, whereUpperBoundExceeds: editStart) { $0.range }
        var firstSuffix = firstAffected
        while firstSuffix < runs.count, runs[firstSuffix].range.location < editEnd {
            firstSuffix += 1
        }

        if delta != 0, firstSuffix < runs.count {
            unsafe runs.withUnsafeMutableBufferPointer { buffer in
                var index = firstSuffix
                while index < buffer.count {
                    unsafe buffer[index].range.location += delta
                    index += 1
                }
            }
        }

        var pieces: [HighlightFontRun] = []
        pieces.reserveCapacity((firstSuffix - firstAffected) * 2)
        var index = firstAffected
        while index < firstSuffix {
            let run = runs[index]
            if run.range.location < editStart {
                pieces.append(HighlightFontRun(
                    range: NSRange(location: run.range.location, length: editStart - run.range.location),
                    font: run.font
                ))
            }
            if run.range.upperBound > editEnd {
                pieces.append(HighlightFontRun(
                    range: NSRange(location: editEnd + delta, length: run.range.upperBound - editEnd),
                    font: run.font
                ))
            }
            index += 1
        }
        if firstAffected < firstSuffix || !pieces.isEmpty {
            runs.replaceSubrange(firstAffected..<firstSuffix, with: pieces)
        }

        var cursor = max(0, firstAffected - 1)
        var windowEnd = min(runs.count, firstAffected + pieces.count + 1)
        while cursor + 1 < windowEnd {
            let previous = runs[cursor]
            let next = runs[cursor + 1]
            if previous.font == next.font, previous.range.upperBound >= next.range.location {
                let lowerBound = min(previous.range.location, next.range.location)
                let upperBound = max(previous.range.upperBound, next.range.upperBound)
                runs[cursor].range = NSRange(location: lowerBound, length: upperBound - lowerBound)
                runs.remove(at: cursor + 1)
                windowEnd -= 1
            } else {
                cursor += 1
            }
        }
    }

    /// Same splice for plain coalesced ranges (`rangesAreNormalized`: strictly
    /// ascending, non-touching — touching neighbors merge unconditionally).
    static func spliceEditIntoRanges(
        _ ranges: inout [NSRange],
        editStart: Int,
        editEnd: Int,
        delta: Int
    ) {
        guard !ranges.isEmpty else { return }
        let firstAffected = firstIndex(in: ranges, whereUpperBoundExceeds: editStart) { $0 }
        var firstSuffix = firstAffected
        while firstSuffix < ranges.count, ranges[firstSuffix].location < editEnd {
            firstSuffix += 1
        }

        if delta != 0, firstSuffix < ranges.count {
            unsafe ranges.withUnsafeMutableBufferPointer { buffer in
                var index = firstSuffix
                while index < buffer.count {
                    unsafe buffer[index].location += delta
                    index += 1
                }
            }
        }

        var pieces: [NSRange] = []
        pieces.reserveCapacity((firstSuffix - firstAffected) * 2)
        var index = firstAffected
        while index < firstSuffix {
            let range = ranges[index]
            if range.location < editStart {
                pieces.append(NSRange(location: range.location, length: editStart - range.location))
            }
            if range.upperBound > editEnd {
                pieces.append(NSRange(location: editEnd + delta, length: range.upperBound - editEnd))
            }
            index += 1
        }
        if firstAffected < firstSuffix || !pieces.isEmpty {
            ranges.replaceSubrange(firstAffected..<firstSuffix, with: pieces)
        }

        var cursor = max(0, firstAffected - 1)
        var windowEnd = min(ranges.count, firstAffected + pieces.count + 1)
        while cursor + 1 < windowEnd {
            if ranges[cursor].upperBound >= ranges[cursor + 1].location {
                let lowerBound = min(ranges[cursor].location, ranges[cursor + 1].location)
                let upperBound = max(ranges[cursor].upperBound, ranges[cursor + 1].upperBound)
                ranges[cursor] = NSRange(location: lowerBound, length: upperBound - lowerBound)
                ranges.remove(at: cursor + 1)
                windowEnd -= 1
            } else {
                cursor += 1
            }
        }
    }

    /// Binary search: first element whose range's upperBound exceeds `offset`
    /// (sorted + non-overlapping ⇒ upperBound is monotonic).
    private static func firstIndex<T>(
        in items: [T],
        whereUpperBoundExceeds offset: Int,
        _ range: (T) -> NSRange
    ) -> Int {
        var lower = 0
        var upper = items.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if range(items[middle]).upperBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    static func coalescedColorRuns(
        _ runs: [HighlightColorRun]
    ) -> [HighlightColorRun] {
        var coalescedRuns: [HighlightColorRun] = []
        coalescedRuns.reserveCapacity(runs.count)

        for run in runs.sorted(by: sortColorRun) {
            if var last = coalescedRuns.last,
               last.color.isEqual(run.color),
               last.range.upperBound >= run.range.location,
               run.range.upperBound >= last.range.location {
                let lowerBound = min(last.range.location, run.range.location)
                let upperBound = max(last.range.upperBound, run.range.upperBound)
                last.range = NSRange(location: lowerBound, length: upperBound - lowerBound)
                coalescedRuns[coalescedRuns.count - 1] = last
            } else {
                coalescedRuns.append(run)
            }
        }

        return coalescedRuns
    }

    static func colorRunsAreNormalized(
        _ runs: [HighlightColorRun],
        textLength: Int
    ) -> Bool {
        guard runs.allSatisfy({ $0.range.location >= 0 && $0.range.length > 0 && $0.range.upperBound <= textLength }) else {
            return false
        }
        for index in runs.indices.dropFirst() {
            let previous = runs[runs.index(before: index)]
            let current = runs[index]
            guard sortColorRun(lhs: previous, rhs: current) else {
                return false
            }
            if previous.color.isEqual(current.color),
               previous.range.upperBound >= current.range.location {
                return false
            }
        }
        return true
    }

    static func coalescedFontRuns(
        _ runs: [HighlightFontRun]
    ) -> [HighlightFontRun] {
        var coalescedRuns: [HighlightFontRun] = []
        coalescedRuns.reserveCapacity(runs.count)

        for run in runs.sorted(by: sortFontRun) {
            if var last = coalescedRuns.last,
               last.font == run.font,
               last.range.upperBound >= run.range.location,
               run.range.upperBound >= last.range.location {
                let lowerBound = min(last.range.location, run.range.location)
                let upperBound = max(last.range.upperBound, run.range.upperBound)
                last.range = NSRange(location: lowerBound, length: upperBound - lowerBound)
                coalescedRuns[coalescedRuns.count - 1] = last
            } else {
                coalescedRuns.append(run)
            }
        }

        return coalescedRuns
    }

    static func fontRunsAreNormalized(
        _ runs: [HighlightFontRun],
        textLength: Int
    ) -> Bool {
        guard runs.allSatisfy({ $0.range.location >= 0 && $0.range.length > 0 && $0.range.upperBound <= textLength }) else {
            return false
        }
        for index in runs.indices.dropFirst() {
            let previous = runs[runs.index(before: index)]
            let current = runs[index]
            guard sortFontRun(lhs: previous, rhs: current) else {
                return false
            }
            if previous.font == current.font,
               previous.range.upperBound >= current.range.location {
                return false
            }
        }
        return true
    }

    static func rangesAreNormalized(
        _ ranges: [NSRange],
        textLength: Int
    ) -> Bool {
        guard ranges.allSatisfy({ $0.location >= 0 && $0.length > 0 && $0.upperBound <= textLength }) else {
            return false
        }
        for index in ranges.indices.dropFirst() {
            let previous = ranges[ranges.index(before: index)]
            let current = ranges[index]
            guard previous.location < current.location,
                  previous.upperBound < current.location else {
                return false
            }
        }
        return true
    }

    static func rangesBySubtracting(_ removals: [NSRange], from range: NSRange) -> [NSRange] {
        removals.reduce([range]) { remainingRanges, removal in
            remainingRanges.flatMap { rangesBySubtracting(removal, from: $0) }
        }
    }

    private static func rangesBySubtracting(_ removal: NSRange, from range: NSRange) -> [NSRange] {
        let intersection = SyntaxEditorRangeUtilities.intersection(of: range, and: removal)
        guard intersection.length > 0 else { return [range] }

        var ranges: [NSRange] = []
        if intersection.location > range.location {
            ranges.append(NSRange(location: range.location, length: intersection.location - range.location))
        }
        if intersection.upperBound < range.upperBound {
            ranges.append(NSRange(location: intersection.upperBound, length: range.upperBound - intersection.upperBound))
        }
        return ranges
    }

    private static func coalesceColorRunsAround(
        _ runs: inout [HighlightColorRun],
        startIndex: Int,
        replacementCount: Int
    ) {
        guard !runs.isEmpty else { return }
        var currentIndex = max(0, min(startIndex, runs.count - 1) - 1)
        var upperIndex = min(runs.count - 1, startIndex + replacementCount + 1)

        while currentIndex < upperIndex, currentIndex + 1 < runs.count {
            let current = runs[currentIndex]
            let next = runs[currentIndex + 1]
            if current.color.isEqual(next.color),
               current.range.upperBound >= next.range.location {
                let upperBound = max(current.range.upperBound, next.range.upperBound)
                runs[currentIndex].range = NSRange(
                    location: current.range.location,
                    length: upperBound - current.range.location
                )
                runs.remove(at: currentIndex + 1)
                upperIndex = max(currentIndex, upperIndex - 1)
            } else {
                currentIndex += 1
            }
        }
    }

    private static func coalesceFontRunsAround(
        _ runs: inout [HighlightFontRun],
        startIndex: Int,
        replacementCount: Int
    ) {
        guard !runs.isEmpty else { return }
        var currentIndex = max(0, min(startIndex, runs.count - 1) - 1)
        var upperIndex = min(runs.count - 1, startIndex + replacementCount + 1)

        while currentIndex < upperIndex, currentIndex + 1 < runs.count {
            let current = runs[currentIndex]
            let next = runs[currentIndex + 1]
            if current.font == next.font,
               current.range.upperBound >= next.range.location {
                let upperBound = max(current.range.upperBound, next.range.upperBound)
                runs[currentIndex].range = NSRange(
                    location: current.range.location,
                    length: upperBound - current.range.location
                )
                runs.remove(at: currentIndex + 1)
                upperIndex = max(currentIndex, upperIndex - 1)
            } else {
                currentIndex += 1
            }
        }
    }

    private static func firstColorRunIndex(
        intersecting range: NSRange,
        in runs: [HighlightColorRun]
    ) -> Int {
        var lowerBound = 0
        var upperBound = runs.count
        while lowerBound < upperBound {
            let midIndex = (lowerBound + upperBound) / 2
            if runs[midIndex].range.upperBound <= range.location {
                lowerBound = midIndex + 1
            } else {
                upperBound = midIndex
            }
        }
        return lowerBound
    }

    private static func firstFontRunIndex(
        intersecting range: NSRange,
        in runs: [HighlightFontRun]
    ) -> Int {
        var lowerBound = 0
        var upperBound = runs.count
        while lowerBound < upperBound {
            let midIndex = (lowerBound + upperBound) / 2
            if runs[midIndex].range.upperBound <= range.location {
                lowerBound = midIndex + 1
            } else {
                upperBound = midIndex
            }
        }
        return lowerBound
    }

    private static func sortColorRun(
        lhs: HighlightColorRun,
        rhs: HighlightColorRun
    ) -> Bool {
        if lhs.range.location == rhs.range.location {
            lhs.range.length < rhs.range.length
        } else {
            lhs.range.location < rhs.range.location
        }
    }

    private static func sortFontRun(
        lhs: HighlightFontRun,
        rhs: HighlightFontRun
    ) -> Bool {
        if lhs.range.location == rhs.range.location {
            lhs.range.length < rhs.range.length
        } else {
            lhs.range.location < rhs.range.location
        }
    }
}

#endif
