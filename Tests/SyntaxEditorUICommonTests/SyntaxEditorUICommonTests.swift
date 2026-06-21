import Foundation
import Testing
import SyntaxEditorCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@testable import SyntaxEditorUICommon

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SyntaxEditorUICommonTests {
    @Test("SyntaxEditorUICommon exposes highlight style storage")
    func exposesHighlightStyleStorage() {
        let system = EditorTextSystem()
        #expect(system.styleStore.appliedColorRunsForTesting.isEmpty)
        #expect(system.styleStore.appliedFontRunsForTesting.isEmpty)
        #expect(system.layoutManager.textContainer === system.container)
        #expect(system.container.textLayoutManager === system.layoutManager)
        #expect(system.layoutManager.renderingAttributesValidator == nil)
    }

    @Test("Editor text system centralizes UTF-16 range conversion")
    func centralizesUTF16RangeConversion() throws {
        let system = EditorTextSystem()
        TextEditingTransaction.perform(on: system.textContentStorage) { storage in
            storage.setAttributedString(NSAttributedString(string: "abcdef"))
        }

        let range = NSRange(location: 1, length: 3)
        let textRange = try #require(system.textRange(forUTF16Range: range))

        #expect(system.utf16Range(for: textRange) == range)
        #expect(system.utf16Range(for: system.textContentStorage.documentRange) == NSRange(location: 0, length: 6))
    }

    @Test("Text layout geometry centralizes range intersection")
    func centralizesRangeIntersection() {
        let ranges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 5, length: 4),
            NSRange(location: 12, length: 2),
        ]

        #expect(TextLayoutGeometry.ranges(ranges, intersecting: NSRange(location: 2, length: 5)) == [
            NSRange(location: 2, length: 1),
            NSRange(location: 5, length: 2),
        ])
        #expect(TextLayoutGeometry.ranges(ranges, intersecting: NSRange(location: 20, length: 2)).isEmpty)
    }

    @Test("Text range intersection index clips sorted ranges without scanning by fragment")
    func textRangeIntersectionIndexClipsSortedRanges() {
        let index = TextRangeIntersectionIndex(
            ranges: [
                NSRange(location: 8, length: 4),
                NSRange(location: 0, length: 5),
                NSRange(location: 20, length: 10),
                NSRange(location: 4, length: 0),
                NSRange(location: 3, length: 6),
                NSRange(location: 12, length: 2),
            ],
            utf16Length: 24
        )

        #expect(index.ranges(intersecting: NSRange(location: 4, length: 16)) == [
            NSRange(location: 4, length: 1),
            NSRange(location: 4, length: 5),
            NSRange(location: 8, length: 4),
            NSRange(location: 12, length: 2),
        ])
        #expect(index.sourceRanges(intersecting: NSRange(location: 21, length: 10)) == [
            NSRange(location: 20, length: 4),
        ])
        #expect(index.ranges(intersecting: NSRange(location: 24, length: 4)).isEmpty)
    }

    @Test("Highlight token range index includes long tokens that start before the refresh range")
    func highlightTokenRangeIndexIncludesLongTokensBeforeRefreshRange() {
        let tokens = [
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 0, length: 80),
                rawCaptureName: "editor.syntax.swift.comment"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 10, length: 2),
                rawCaptureName: "editor.syntax.swift.keyword"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 20, length: 2),
                rawCaptureName: "editor.syntax.swift.string"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 30, length: 2),
                rawCaptureName: "editor.syntax.swift.keyword"
            ),
        ]
        let index = HighlightTokenRangeIndex(tokens: tokens)

        #expect(index.firstTokenIndex(intersecting: NSRange(location: 60, length: 1)) == 0)
        #expect(index.firstTokenIndex(intersecting: NSRange(location: 81, length: 1)) == tokens.count)
    }

    @Test("Highlight run assembler clips tokens, removes nil styles, and coalesces")
    func highlightRunAssemblerClipsRemovesNilStylesAndCoalesces() {
        let tokens = [
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 0, length: 10),
                rawCaptureName: "editor.syntax.swift.comment"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 3, length: 2),
                rawCaptureName: "editor.syntax.swift.keyword"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 5, length: 1),
                rawCaptureName: "editor.syntax.swift.plain"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 8, length: 5),
                rawCaptureName: "editor.syntax.swift.comment"
            ),
        ]

        let runs = HighlightRunAssembler.assembleRuns(
            for: tokens,
            targetRange: NSRange(location: 1, length: 8),
            textLength: 10
        ) { token -> TestHighlightStyle? in
            switch token.rawCaptureName {
            case "editor.syntax.swift.comment":
                return .red
            case "editor.syntax.swift.keyword":
                return .blue
            default:
                return nil
            }
        } stylesCanCoalesce: { lhs, rhs in
            lhs == rhs
        }

        #expect(runs.map(\.range) == [
            NSRange(location: 1, length: 2),
            NSRange(location: 3, length: 2),
            NSRange(location: 6, length: 3),
        ])
        #expect(runs.map(\.style) == [.red, .blue, .red])
    }

    @Test("Highlight run assembler coalesces color and font runs independently")
    func highlightRunAssemblerCoalescesColorAndFontRunsIndependently() {
        #if canImport(UIKit)
        let regularFont = UIFont.systemFont(ofSize: 13)
        let boldFont = UIFont.boldSystemFont(ofSize: 13)
        #elseif canImport(AppKit)
        let regularFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        #endif
        let tokens = [
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 0, length: 2),
                rawCaptureName: "editor.syntax.swift.comment"
            ),
            SyntaxEditorHighlighting.Token(
                range: NSRange(location: 2, length: 2),
                rawCaptureName: "editor.syntax.swift.keyword"
            ),
        ]

        let runSet = HighlightRunAssembler.assembleRunSet(
            for: tokens,
            targetRange: NSRange(location: 0, length: 4),
            textLength: 4
        ) { token in
            switch token.rawCaptureName {
            case "editor.syntax.swift.comment":
                return HighlightRunStyle(foregroundColor: redColor, font: regularFont)
            case "editor.syntax.swift.keyword":
                return HighlightRunStyle(foregroundColor: redColor, font: boldFont)
            default:
                return nil
            }
        }

        #expect(runSet.colorRuns.map(\.range) == [NSRange(location: 0, length: 4)])
        #expect(runSet.colorRuns.first?.color.isEqual(redColor) == true)
        #expect(runSet.fontRuns.map(\.range) == [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2),
        ])
        #expect(runSet.fontRuns.first?.font.isEqual(regularFont) == true)
        #expect(runSet.fontRuns.last?.font.isEqual(boldFont) == true)
    }

    @Test("Document line metrics centralizes resize estimates without rebuilds")
    func documentLineMetricsCachesResizeEstimates() {
        let metrics = DocumentLineMetrics(
            source: "let extremelyLongIdentifierName = value\nlet short = true",
            tabWidth: 4
        )
        let rebuildCount = metrics.fullRebuildCount

        let wide = metrics.estimatedDocumentSize(
            minimumSize: CGSize(width: 360, height: 40),
            lineWrappingEnabled: true,
            lineHeight: 10,
            columnWidth: 10,
            lineFragmentPadding: 0
        )
        let narrow = metrics.estimatedDocumentSize(
            minimumSize: CGSize(width: 80, height: 40),
            lineWrappingEnabled: true,
            lineHeight: 10,
            columnWidth: 10,
            lineFragmentPadding: 0
        )

        #expect(metrics.fullRebuildCount == rebuildCount)
        #expect(narrow.height > wide.height)
    }

    @Test("Highlight render snapshot leaves TextKit storage unchanged")
    func highlightRenderSnapshotLeavesTextKitStorageUnchanged() {
        let system = EditorTextSystem()
        TextEditingTransaction.perform(on: system.textContentStorage) { storage in
            let attributedString = NSMutableAttributedString(string: "ab")
            attributedString.addAttribute(.foregroundColor, value: baseForeground, range: NSRange(location: 0, length: 2))
            storage.setAttributedString(attributedString)
        }

        system.styleStore.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 2), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 2),
            revision: 1,
            language: .swift,
            textLength: 2,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect((system.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? SyntaxEditorTheme.Color)?.isEqual(baseForeground) == true)
        #expect(system.styleStore.foregroundColor(at: 0)?.isEqual(redColor) == true)
    }

    @Test("Highlight render snapshot coalesces adjacent same-color runs")
    func highlightRenderSnapshotCoalescesAdjacentSameColorRuns() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [
                    HighlightColorRun(range: NSRange(location: 0, length: 2), color: redColor),
                    HighlightColorRun(range: NSRange(location: 2, length: 3), color: redColor),
                ],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 5),
            revision: 1,
            language: .swift,
            textLength: 5,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(store.appliedColorRunsForTesting.map(\.range) == [
            NSRange(location: 0, length: 5),
        ])
        #expect(store.epoch == 1)
    }

    @Test("Highlight render snapshot replaces only committed range")
    func highlightRenderSnapshotReplacesOnlyCommittedRange() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [
                    HighlightColorRun(range: NSRange(location: 0, length: 3), color: redColor),
                    HighlightColorRun(range: NSRange(location: 10, length: 3), color: redColor),
                ],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 20),
            revision: 1,
            language: .swift,
            textLength: 20,
            baseForeground: baseForeground,
            baseFont: nil
        )
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 3), color: blueColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 3),
            revision: 2,
            language: .swift,
            textLength: 20,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(store.appliedColorRunsForTesting.map(\.range) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 10, length: 3),
        ])
        #expect(store.appliedColorRunsForTesting.first?.color.isEqual(blueColor) == true)
        #expect(store.appliedColorRunsForTesting.last?.color.isEqual(redColor) == true)
    }

    @Test("Pending highlight edit keeps snapshot unshifted and resolves visible insertion optimistically")
    func pendingHighlightEditKeepsSnapshotUnshiftedAndResolvesVisibleInsertionOptimistically() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )

        #expect(store.appliedColorRunsForTesting.map(\.range) == [
            NSRange(location: 0, length: 10),
        ])
        #expect(store.colorRuns(in: NSRange(location: 0, length: 12)).map(\.range) == [
            NSRange(location: 0, length: 12),
        ])
        #expect(store.pendingDirtyRangesForTesting == [NSRange(location: 5, length: 2)])
    }

    @Test("Pending highlight edit resolves deletion and replacement lazily")
    func pendingHighlightEditResolvesDeletionAndReplacementLazily() {
        let deletionStore = HighlightRenderSnapshotStore()
        deletionStore.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        deletionStore.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 3, length: 2, replacement: ""),
            currentTextLength: 8
        )
        #expect(deletionStore.colorRuns(in: NSRange(location: 0, length: 8)).map(\.range) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 4),
        ])

        let replacementStore = HighlightRenderSnapshotStore()
        replacementStore.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        replacementStore.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 2, length: 3, replacement: "XY"),
            currentTextLength: 9
        )
        #expect(replacementStore.colorRuns(in: NSRange(location: 0, length: 9)).map(\.range) == [
            NSRange(location: 0, length: 2),
            NSRange(location: 4, length: 5),
        ])
    }

    @Test("Pending highlight edit keeps snapshot coordinates after base font updates")
    func pendingHighlightEditKeepsSnapshotCoordinatesAfterBaseFontUpdates() {
        #if canImport(UIKit)
        let baseFont = UIFont.systemFont(ofSize: 13)
        let nextBaseFont = UIFont.systemFont(ofSize: 17)
        #elseif canImport(AppKit)
        let baseFont = NSFont.systemFont(ofSize: 13)
        let nextBaseFont = NSFont.systemFont(ofSize: 17)
        #endif
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: baseFont
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 0, length: 1, replacement: ""),
            currentTextLength: 9
        )

        store.updateBaseFont(nextBaseFont, textLength: 9)

        #expect(store.appliedColorRunsForTesting.map(\.range) == [
            NSRange(location: 0, length: 10),
        ])
        #expect(store.colorRuns(in: NSRange(location: 0, length: 9)).map(\.range) == [
            NSRange(location: 1, length: 8),
        ])
        #expect(store.foregroundColor(at: 8)?.isEqual(redColor) == true)
    }

    @Test("Pending highlight edit composes multiple edits")
    func pendingHighlightEditComposesMultipleEdits() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: "y"),
            currentTextLength: 13
        )

        #expect(store.colorRuns(in: NSRange(location: 0, length: 13)).map(\.range) == [
            NSRange(location: 0, length: 13),
        ])
        #expect(store.pendingDirtyRangesForTesting == [
            NSRange(location: 0, length: 1),
            NSRange(location: 6, length: 2),
        ])
    }

    @Test("Pending highlight edit coalesces continuous typing")
    func pendingHighlightEditCoalescesContinuousTyping() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "x"),
            currentTextLength: 11
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 6, length: 0, replacement: "y"),
            currentTextLength: 12
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 7, length: 0, replacement: "z"),
            currentTextLength: 13
        )

        #expect(store.pendingEditCountForTesting == 1)
        #expect(store.pendingDirtyRangesForTesting == [NSRange(location: 5, length: 3)])
        #expect(store.colorRuns(in: NSRange(location: 0, length: 13)).map(\.range) == [
            NSRange(location: 0, length: 13),
        ])
    }

    @Test("Pending highlight edit leaves whitespace insertions unstyled")
    func pendingHighlightEditLeavesWhitespaceInsertionsUnstyled() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: " "),
            currentTextLength: 11
        )

        #expect(store.pendingDirtyRangesForTesting == [NSRange(location: 5, length: 1)])
        #expect(store.colorRuns(in: NSRange(location: 0, length: 11)).map(\.range) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 6, length: 5),
        ])
    }

    @Test("Pending highlight edit inherits font runs for visible insertions")
    func pendingHighlightEditInheritsFontRunsForVisibleInsertions() throws {
        #if canImport(UIKit)
        let syntaxFont = UIFont.boldSystemFont(ofSize: 13)
        #elseif canImport(AppKit)
        let syntaxFont = NSFont.boldSystemFont(ofSize: 13)
        #endif
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet:
            HighlightRunSet(
                colorRuns: [],
                fontRuns: [HighlightFontRun(range: NSRange(location: 0, length: 10), font: syntaxFont)]
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )

        let inheritedFont = try #require(store.font(at: 5))
        #expect(inheritedFont.isEqual(syntaxFont))
        #expect(store.resolveVisibleRuns(in: NSRange(location: 0, length: 12)).fontRuns.map(\.range) == [
            NSRange(location: 5, length: 2),
            NSRange(location: 0, length: 5),
            NSRange(location: 7, length: 5),
        ])
    }

    @Test("Materialized current runs splice through edits in place")
    func materializedCurrentRunsSpliceThroughEditsInPlace() {
        // Build a store in the partially-materialized state (snapshot + pending
        // edit + partial refresh commit), then verify the per-keystroke splice:
        // suffix shift, split-at-insertion, deletion shrink, and junction merge.
        func makeStore() -> HighlightRenderSnapshotStore {
            let store = HighlightRenderSnapshotStore()
            store.commitSnapshot(
                runSet: HighlightRunSet(colorRuns: [], fontRuns: []),
                range: NSRange(location: 0, length: 100),
                revision: 1,
                language: .swift,
                textLength: 100,
                baseForeground: baseForeground,
                baseFont: nil
            )
            // Pending edit so the next partial commit lands in current runs.
            store.recordPendingEdit(
                SyntaxEditorTextChange.Replacement(location: 90, length: 0, replacement: "x"),
                currentTextLength: 101
            )
            store.commitSnapshot(
                runSet: HighlightRunSet(
                    colorRuns: [
                        HighlightColorRun(range: NSRange(location: 10, length: 10), color: redColor),
                        HighlightColorRun(range: NSRange(location: 30, length: 10), color: blueColor),
                    ],
                    fontRuns: []
                ),
                range: NSRange(location: 0, length: 60),
                revision: 1,
                language: .swift,
                textLength: 101,
                baseForeground: baseForeground,
                baseFont: nil
            )
            return store
        }

        // Insert before both runs: both shift right.
        let shifted = makeStore()
        shifted.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: "ab"),
            currentTextLength: 103
        )
        #expect(shifted.maintainsNormalizedRunInvariantForTesting)
        #expect(shifted.colorRuns(in: NSRange(location: 0, length: 103)).map(\.range) == [
            NSRange(location: 12, length: 10),
            NSRange(location: 32, length: 10),
        ])

        // Insert inside the first run: the inserted text inherits that run
        // until the next highlighter result replaces it.
        let split = makeStore()
        split.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 15, length: 0, replacement: "ab"),
            currentTextLength: 103
        )
        #expect(split.maintainsNormalizedRunInvariantForTesting)
        #expect(split.colorRuns(in: NSRange(location: 0, length: 103)).map(\.range) == [
            NSRange(location: 10, length: 12),
            NSRange(location: 32, length: 10),
        ])

        // Delete across the gap between the runs: different colors stay
        // separate runs, now adjacent; the second run loses its head.
        let bridged = makeStore()
        bridged.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 18, length: 14, replacement: ""),
            currentTextLength: 87
        )
        #expect(bridged.maintainsNormalizedRunInvariantForTesting)
        #expect(bridged.colorRuns(in: NSRange(location: 0, length: 87)).map(\.range) == [
            NSRange(location: 10, length: 8),
            NSRange(location: 18, length: 8),
        ])

        // Delete inside one run: the two kept sides re-merge into one run.
        let merged = makeStore()
        merged.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 12, length: 4, replacement: ""),
            currentTextLength: 97
        )
        #expect(merged.maintainsNormalizedRunInvariantForTesting)
        #expect(merged.colorRuns(in: NSRange(location: 0, length: 97)).map(\.range) == [
            NSRange(location: 10, length: 6),
            NSRange(location: 26, length: 10),
        ])
    }

    @Test("Pending highlight edits self-checkpoint without changing resolution")
    func pendingHighlightEditsSelfCheckpointWithoutChangingResolution() {
        // Two identical edit sequences: the reference store never checkpoints
        // (high threshold), the checkpointing store folds every few edits.
        // Resolution must match throughout, and the map must stay bounded.
        func makeStore() -> HighlightRenderSnapshotStore {
            let store = HighlightRenderSnapshotStore()
            store.commitSnapshot(
                runSet: HighlightRunSet(
                    colorRuns: [
                        HighlightColorRun(range: NSRange(location: 0, length: 40), color: redColor),
                        HighlightColorRun(range: NSRange(location: 60, length: 40), color: blueColor),
                    ],
                    fontRuns: []
                ),
                range: NSRange(location: 0, length: 100),
                revision: 1,
                language: .swift,
                textLength: 100,
                baseForeground: baseForeground,
                baseFont: nil
            )
            return store
        }

        // Scattered single-character inserts that defeat the map's coalescing.
        var edits: [(SyntaxEditorTextChange.Replacement, Int)] = []
        var length = 100
        for step in 0..<12 {
            let location = (step * 17 + (step.isMultiple(of: 2) ? 2 : 55)) % max(1, length - 1)
            length += 1
            edits.append((SyntaxEditorTextChange.Replacement(location: location, length: 0, replacement: "x"), length))
        }

        HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = 1_000_000
        let reference = makeStore()
        for (mutation, textLength) in edits {
            reference.recordPendingEdit(mutation, currentTextLength: textLength)
        }
        let referenceRuns = reference.colorRuns(in: NSRange(location: 0, length: length))
        let referenceEditCount = reference.pendingEditCountForTesting

        HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = 3
        defer { HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = nil }
        let checkpointing = makeStore()
        for (mutation, textLength) in edits {
            checkpointing.recordPendingEdit(mutation, currentTextLength: textLength)
        }
        let checkpointedRuns = checkpointing.colorRuns(in: NSRange(location: 0, length: length))

        #expect(referenceEditCount > 3)
        #expect(checkpointing.pendingEditCountForTesting <= 3)
        #expect(checkpointing.maintainsNormalizedRunInvariantForTesting)
        #expect(checkpointedRuns.count == referenceRuns.count)
        for (lhs, rhs) in zip(checkpointedRuns, referenceRuns) {
            #expect(lhs.range == rhs.range)
            #expect(lhs.color.isEqual(rhs.color))
        }
    }

    @Test("Pending highlight checkpoint carries unresolved dirty ranges until refreshed")
    func pendingHighlightCheckpointCarriesUnresolvedDirtyRangesUntilRefreshed() {
        HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = 3
        defer { HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = nil }

        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(colorRuns: [], fontRuns: []),
            range: NSRange(location: 0, length: 0),
            revision: 1,
            language: .swift,
            textLength: 0,
            baseForeground: baseForeground,
            baseFont: nil
        )

        let paste = "let value = 1\n"
        let pasteLength = paste.utf16.count
        var textLength = 0
        for _ in 0..<4 {
            textLength += pasteLength
            store.recordPendingEdit(
                SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: paste),
                currentTextLength: textLength
            )
        }

        #expect(!store.hasPendingEditsForTesting)
        #expect(store.checkpointDirtyRangesForTesting == [
            NSRange(location: 0, length: textLength),
        ])
        #expect(store.foregroundColor(at: 0) == nil)

        textLength += pasteLength
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: paste),
            currentTextLength: textLength
        )

        #expect(store.pendingDirtyRangesForTesting == [
            NSRange(location: 0, length: pasteLength),
        ])
        #expect(store.checkpointDirtyRangesForTesting == [
            NSRange(location: pasteLength, length: pasteLength * 4),
        ])

        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 3), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: pasteLength),
            revision: 2,
            language: .swift,
            textLength: textLength,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(store.foregroundColor(at: 0)?.isEqual(redColor) == true)
        #expect(store.foregroundColor(at: pasteLength) == nil)
        #expect(store.checkpointDirtyRangesForTesting == [
            NSRange(location: pasteLength, length: pasteLength * 4),
        ])

        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: pasteLength, length: 3), color: blueColor)],
                fontRuns: []
            ),
            range: NSRange(location: pasteLength, length: pasteLength),
            revision: 2,
            language: .swift,
            textLength: textLength,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(store.foregroundColor(at: pasteLength)?.isEqual(blueColor) == true)
        #expect(store.foregroundColor(at: pasteLength * 2) == nil)
        #expect(store.checkpointDirtyRangesForTesting == [
            NSRange(location: pasteLength * 2, length: pasteLength * 3),
        ])
        #expect(store.maintainsNormalizedRunInvariantForTesting)

        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: textLength), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: textLength),
            revision: 3,
            language: .swift,
            textLength: textLength,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(store.checkpointDirtyRangesForTesting.isEmpty)
        #expect(store.foregroundColor(at: pasteLength * 2)?.isEqual(redColor) == true)
    }

    @Test("Pending highlight checkpoint preserves font-only optimistic overlays")
    func pendingHighlightCheckpointPreservesFontOnlyOptimisticOverlays() {
        #if canImport(UIKit)
        let syntaxFont = UIFont.boldSystemFont(ofSize: 13)
        #elseif canImport(AppKit)
        let syntaxFont = NSFont.boldSystemFont(ofSize: 13)
        #endif

        HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = 1
        defer { HighlightRenderSnapshotStore.pendingEditCheckpointThresholdOverrideForTesting = nil }

        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [],
                fontRuns: [HighlightFontRun(range: NSRange(location: 0, length: 6), font: syntaxFont)]
            ),
            range: NSRange(location: 0, length: 6),
            revision: 1,
            language: .swift,
            textLength: 6,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 2, length: 0, replacement: "x"),
            currentTextLength: 7
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 6, length: 0, replacement: "y"),
            currentTextLength: 8
        )

        #expect(!store.hasPendingEditsForTesting)
        #expect(store.checkpointDirtyRangesForTesting.isEmpty)
        #expect(store.foregroundColor(at: 2) == nil)
        #expect(store.font(at: 2)?.isEqual(syntaxFont) == true)
        #expect(store.font(at: 6)?.isEqual(syntaxFont) == true)
        #expect(store.maintainsNormalizedRunInvariantForTesting)
    }

    @Test("Highlight visible resolver suppresses marked text ranges")
    func highlightVisibleResolverSuppressesMarkedTextRanges() {
        #if canImport(UIKit)
        let syntaxFont = UIFont.boldSystemFont(ofSize: 13)
        #elseif canImport(AppKit)
        let syntaxFont = NSFont.boldSystemFont(ofSize: 13)
        #endif
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: [HighlightFontRun(range: NSRange(location: 0, length: 10), font: syntaxFont)]
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil,
            suppressionRanges: [NSRange(location: 3, length: 3)]
        )

        #expect(store.colorRuns(in: NSRange(location: 0, length: 10)).map(\.range) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 6, length: 4),
        ])
        #expect(store.appliedColorRunsForTesting.map(\.range) == [
            NSRange(location: 0, length: 10),
        ])
        #expect(store.resolveVisibleRuns(in: NSRange(location: 0, length: 10)).fontRuns.map(\.range) == [
            NSRange(location: 0, length: 10),
        ])
        #expect(store.font(at: 4)?.isEqual(syntaxFont) == true)

        store.updateSuppressionRanges([], textLength: 10)

        #expect(store.colorRuns(in: NSRange(location: 0, length: 10)).map(\.range) == [
            NSRange(location: 0, length: 10),
        ])
    }

    @Test("Snapshot commit clears pending highlight edits")
    func snapshotCommitClearsPendingHighlightEdits() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )
        #expect(store.hasPendingEditsForTesting)

        let invalidatedDirtyRanges = store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 12), color: blueColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 12),
            revision: 2,
            language: .swift,
            textLength: 12,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(invalidatedDirtyRanges == [NSRange(location: 5, length: 2)])
        #expect(!store.hasPendingEditsForTesting)
        #expect(store.checkpointDirtyRangesForTesting.isEmpty)
        #expect(store.foregroundColor(at: 5)?.isEqual(blueColor) == true)
    }

    @Test("Partial snapshot commit preserves pending edit mapping")
    func partialSnapshotCommitPreservesPendingEditMapping() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )

        let partialInvalidatedRanges = store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 5, length: 2), color: blueColor)],
                fontRuns: []
            ),
            range: NSRange(location: 5, length: 2),
            revision: 2,
            language: .swift,
            textLength: 12,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(partialInvalidatedRanges.isEmpty)
        #expect(store.hasPendingEditsForTesting)
        #expect(store.checkpointDirtyRangesForTesting.isEmpty)
        let visibleRuns = store.colorRuns(in: NSRange(location: 0, length: 12))
        #expect(visibleRuns.map(\.range) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 5, length: 2),
            NSRange(location: 7, length: 5),
        ])
        #expect(visibleRuns[0].color.isEqual(redColor))
        #expect(visibleRuns[1].color.isEqual(blueColor))
        #expect(visibleRuns[2].color.isEqual(redColor))
    }

    @Test("Highlight render snapshot keeps current materialized runs normalized")
    func highlightRenderSnapshotKeepsCurrentMaterializedRunsNormalized() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [
                    HighlightColorRun(range: NSRange(location: 6, length: 4), color: redColor),
                    HighlightColorRun(range: NSRange(location: 0, length: 6), color: redColor),
                ],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [
                    HighlightColorRun(range: NSRange(location: 5, length: 1), color: blueColor),
                    HighlightColorRun(range: NSRange(location: 6, length: 1), color: blueColor),
                ],
                fontRuns: []
            ),
            range: NSRange(location: 5, length: 2),
            revision: 2,
            language: .swift,
            textLength: 12,
            baseForeground: baseForeground,
            baseFont: nil
        )

        #expect(store.maintainsNormalizedRunInvariantForTesting)
        #expect(store.colorRuns(in: NSRange(location: 0, length: 12)).map(\.range) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 5, length: 2),
            NSRange(location: 7, length: 5),
        ])
    }

    @Test("Highlight render snapshot resolves visible color and font runs together")
    func highlightRenderSnapshotResolvesVisibleColorAndFontRunsTogether() {
        #if canImport(UIKit)
        let syntaxFont = UIFont.boldSystemFont(ofSize: 13)
        #elseif canImport(AppKit)
        let syntaxFont = NSFont.boldSystemFont(ofSize: 13)
        #endif
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [
                    HighlightColorRun(range: NSRange(location: 0, length: 5), color: redColor),
                    HighlightColorRun(range: NSRange(location: 12, length: 4), color: blueColor),
                ],
                fontRuns: [
                    HighlightFontRun(range: NSRange(location: 2, length: 4), font: syntaxFont),
                    HighlightFontRun(range: NSRange(location: 14, length: 2), font: syntaxFont),
                ]
            ),
            range: NSRange(location: 0, length: 20),
            revision: 1,
            language: .swift,
            textLength: 20,
            baseForeground: baseForeground,
            baseFont: nil
        )

        let resolvedRuns = store.resolveVisibleRuns(in: NSRange(location: 3, length: 11))

        #expect(resolvedRuns.colorRuns.map(\.range) == [
            NSRange(location: 3, length: 2),
            NSRange(location: 12, length: 2),
        ])
        #expect(resolvedRuns.fontRuns.map(\.range) == [
            NSRange(location: 3, length: 3),
        ])
    }

    @Test("Partial snapshot commit shifts materialized ranges after later edits")
    func partialSnapshotCommitShiftsMaterializedRangesAfterLaterEdits() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )
        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 5, length: 0, replacement: "xx"),
            currentTextLength: 12
        )
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 5, length: 2), color: blueColor)],
                fontRuns: []
            ),
            range: NSRange(location: 5, length: 2),
            revision: 2,
            language: .swift,
            textLength: 12,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.recordPendingEdit(
            SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: "y"),
            currentTextLength: 13
        )

        let visibleRuns = store.colorRuns(in: NSRange(location: 0, length: 13))
        #expect(visibleRuns.map(\.range) == [
            NSRange(location: 0, length: 6),
            NSRange(location: 6, length: 2),
            NSRange(location: 8, length: 5),
        ])
        #expect(visibleRuns[0].color.isEqual(redColor))
        #expect(visibleRuns[1].color.isEqual(blueColor))
        #expect(visibleRuns[2].color.isEqual(redColor))
    }

    @Test("Highlight render snapshot clears stale font runs without dropping color runs")
    func highlightRenderSnapshotClearsStaleFontRunsWithoutDroppingColorRuns() {
        #if canImport(UIKit)
        let baseFont = UIFont.systemFont(ofSize: 13)
        let syntaxFont = UIFont.boldSystemFont(ofSize: 13)
        let nextBaseFont = UIFont.systemFont(ofSize: 17)
        #elseif canImport(AppKit)
        let baseFont = NSFont.systemFont(ofSize: 13)
        let syntaxFont = NSFont.boldSystemFont(ofSize: 13)
        let nextBaseFont = NSFont.systemFont(ofSize: 17)
        #endif
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 5), color: redColor)],
                fontRuns: [HighlightFontRun(range: NSRange(location: 0, length: 5), font: syntaxFont)]
            ),
            range: NSRange(location: 0, length: 5),
            revision: 1,
            language: .swift,
            textLength: 5,
            baseForeground: baseForeground,
            baseFont: baseFont
        )

        let invalidatedRanges = store.updateBaseFont(
            nextBaseFont,
            textLength: 5,
            clearsFontRuns: true
        )

        #expect(invalidatedRanges == [NSRange(location: 0, length: 5)])
        #expect(store.foregroundColor(at: 0)?.isEqual(redColor) == true)
        #expect(store.font(at: 0) == nil)
    }

    @Test("Highlight render snapshot resets logical state")
    func highlightRenderSnapshotResetsLogicalState() {
        let store = HighlightRenderSnapshotStore()
        store.commitSnapshot(
            runSet: HighlightRunSet(
                colorRuns: [HighlightColorRun(range: NSRange(location: 0, length: 10), color: redColor)],
                fontRuns: []
            ),
            range: NSRange(location: 0, length: 10),
            revision: 1,
            language: .swift,
            textLength: 10,
            baseForeground: baseForeground,
            baseFont: nil
        )

        store.reset(textLength: 40)

        #expect(store.appliedColorRunsForTesting.isEmpty)
        #expect(store.appliedFontRunsForTesting.isEmpty)
        #expect(store.epoch == 2)
    }
}

private var baseForeground: SyntaxEditorTheme.Color {
#if canImport(UIKit)
    .label
#elseif canImport(AppKit)
    .labelColor
#endif
}

private var redColor: SyntaxEditorTheme.Color {
#if canImport(UIKit)
    .red
#elseif canImport(AppKit)
    .red
#endif
}

private var blueColor: SyntaxEditorTheme.Color {
#if canImport(UIKit)
    .blue
#elseif canImport(AppKit)
    .blue
#endif
}

private enum TestHighlightStyle: Equatable {
    case red
    case blue
}
