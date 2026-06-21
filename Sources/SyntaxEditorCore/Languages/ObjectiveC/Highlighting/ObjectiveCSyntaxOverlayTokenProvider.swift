import Foundation
import SwiftTreeSitter

enum ObjectiveCSyntaxOverlayTokenProvider: SyntaxOverlayProvider {
    static func mergingOverlayTokens(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node? = nil,
        refreshRange: NSRange? = nil
    ) -> [SyntaxEditorHighlighting.Token] {
        var state: ObjectiveCSemanticOverlayState?
        return mergingOverlayResult(
            tokens: tokens,
            source: source,
            rootNode: rootNode,
            refreshRange: refreshRange,
            state: &state
        ).tokens
    }

    static func mergingOverlayResult(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node? = nil,
        refreshRange: NSRange? = nil,
        state: inout ObjectiveCSemanticOverlayState?
    ) -> ObjectiveCSemanticOverlayResult {
        mergingOverlayResult(
            tokens: tokens,
            source: source,
            rootNode: rootNode,
            refreshRange: refreshRange,
            mutation: nil,
            state: &state
        )
    }

    static func mergingOverlayResult(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node? = nil,
        refreshRange: NSRange? = nil,
        mutation: SyntaxEditorTextChange.Replacement?,
        tokenPrefixMaxUpperBounds: [Int]? = nil,
        state: inout ObjectiveCSemanticOverlayState?
    ) -> ObjectiveCSemanticOverlayResult {
        let nsSource = source as NSString
        guard nsSource.length > 0 else {
            state = nil
            return ObjectiveCSemanticOverlayResult(
                tokens: preparedOverlayInput(from: tokens, source: nsSource, targetRange: nil).baseTokensForIndex,
                refreshRangeOverride: nil,
                isCancelled: false
            )
        }

        let proposedTargetRange = refreshRange.map {
            SyntaxEditorRangeUtilities.clampedRange($0, utf16Length: nsSource.length)
        }
        let previousIndex = state?.index
        let requiresSemanticIndexRebuild = mutation.map {
            objectiveCMutationRequiresSemanticIndexRebuild(
                $0,
                in: nsSource,
                previousIndex: previousIndex
            )
        } ?? false
        let shiftedLineSignatureIndex = mutation.flatMap { mutation in
            previousIndex?.lineSignatureIndex.applying(mutation, to: nsSource)
        }
        let shiftedPreviousIndex = mutation.flatMap { mutation in
            previousIndex?.shifted(by: mutation, source: nsSource)
        }
        let cannotShiftPreviousIndex = mutation != nil
            && previousIndex != nil
            && shiftedPreviousIndex == nil
        let shouldCheckStructuralFingerprint = mutation.map {
            requiresSemanticIndexRebuild
                || cannotShiftPreviousIndex
                || objectiveCMutationCanChangeSemanticSignature($0, in: nsSource, previousIndex: previousIndex)
        } ?? true
        let structuralSignature = if let previousIndex, !shouldCheckStructuralFingerprint {
            ObjectiveCSemanticIndexSignature(
                fingerprint: previousIndex.structuralFingerprint,
                structuralEditRanges: previousIndex.structuralEditRanges
            )
        } else if let shiftedLineSignatureIndex {
            ObjectiveCSemanticIndexSignature(
                fingerprint: shiftedLineSignatureIndex.fingerprint,
                structuralEditRanges: shiftedLineSignatureIndex.structuralEditRanges
            )
        } else {
            semanticIndexSignature(in: nsSource)
        }
        let structuralFingerprintChanged = shouldCheckStructuralFingerprint
            ? (previousIndex.map { $0.structuralFingerprint != structuralSignature.fingerprint } ?? true)
            : false
        let localStructuralTargetRange = if structuralFingerprintChanged,
                                            let mutation,
                                            previousIndex != nil {
            objectiveCLocalStructuralRefreshRange(for: mutation, in: nsSource, previousIndex: previousIndex)
        } else {
            nil as NSRange?
        }
        let structuralCheckRequiresFullTarget = structuralFingerprintChanged
            && localStructuralTargetRange == nil
        let targetRange = proposedTargetRange == nil
            || previousIndex == nil
            || structuralCheckRequiresFullTarget
            ? nil
            : (localStructuralTargetRange ?? proposedTargetRange)
        let shouldRebuildIndex = proposedTargetRange == nil
            || previousIndex == nil
            || requiresSemanticIndexRebuild
            || structuralFingerprintChanged
            || structuralCheckRequiresFullTarget
            || cannotShiftPreviousIndex
            || (previousIndex?.sourceUTF16Length != nsSource.length && mutation == nil)
        let preparation = preparedOverlayInput(
            from: tokens,
            source: nsSource,
            targetRange: targetRange,
            tokenPrefixMaxUpperBounds: tokenPrefixMaxUpperBounds,
            preparesFullIndex: shouldRebuildIndex
        )
        let semanticIndex: ObjectiveCSemanticIndex
        if shouldRebuildIndex {
            guard let rebuiltIndex = ObjectiveCFileSymbolIndex(
                source: nsSource,
                tokenIndex: preparation.tokenIndex,
                nonCodeRangeIndex: preparation.nonCodeRangeIndex,
                rootNode: rootNode,
                allowsCancellation: true
            ) else {
                return ObjectiveCSemanticOverlayResult(
                    tokens: tokens,
                    refreshRangeOverride: nil,
                    isCancelled: true
                )
            }
            semanticIndex = ObjectiveCSemanticIndex(
                fileSymbols: rebuiltIndex,
                sourceUTF16Length: nsSource.length,
                structuralFingerprint: structuralSignature.fingerprint,
                structuralEditRanges: structuralSignature.structuralEditRanges,
                lineSignatureIndex: ObjectiveCSemanticLineSignatureIndex(source: nsSource)
            )
        } else if let shiftedIndex = shiftedPreviousIndex {
            semanticIndex = shiftedIndex
        } else {
            semanticIndex = previousIndex!
        }

        guard !Task.isCancelled else {
            return ObjectiveCSemanticOverlayResult(
                tokens: tokens,
                refreshRangeOverride: nil,
                isCancelled: true
            )
        }

        // The per-token classification scan dominates the document pass; nil
        // means it observed cancellation mid-scan — the engine actor must be
        // released quickly once a newer keystroke cancels this merge.
        guard let identifierOverlayTokens = semanticTokens(
            from: preparation.baseTokensForIndex,
            source: nsSource,
            index: semanticIndex.fileSymbols,
            targetRange: targetRange
        ) else {
            return ObjectiveCSemanticOverlayResult(
                tokens: tokens,
                refreshRangeOverride: nil,
                isCancelled: true
            )
        }
        let overlayTokens = identifierOverlayTokens
            + objectiveCMacroTokens(
                in: nsSource,
                nonCodeRanges: preparation.nonCodeRangeIndex.ranges,
                targetRange: targetRange
            )
            + preprocessorStringTokens(in: nsSource, tokens: preparation.baseTokensForIndex, targetRange: targetRange)
            + boxedExpressionDelimiterTokens(
                in: nsSource,
                nonCodeRanges: preparation.nonCodeRangeIndex.ranges,
                targetRange: targetRange
            )
            + boxedBooleanLiteralTokens(
                in: nsSource,
                nonCodeRanges: preparation.nonCodeRangeIndex.ranges,
                targetRange: targetRange
            )
        let mergedTokens = if let partialMergeTargetRange = preparation.partialMergeTargetRange,
                              let partialMergeTokenRange = preparation.partialMergeTokenRange {
            partialMergedTokens(
                existingTokens: tokens,
                replacementOverlayTokens: overlayTokens,
                targetRange: partialMergeTargetRange,
                tokenRange: partialMergeTokenRange
            )
        } else {
            deduplicated(
                mergedTokens(
                    baseTokens: preparation.outputBaseTokens,
                    overlayTokens: preparation.preservedOverlayTokens + overlayTokens
                )
            )
        }
        state = ObjectiveCSemanticOverlayState(index: semanticIndex)
        return ObjectiveCSemanticOverlayResult(
            tokens: mergedTokens,
            refreshRangeOverride: targetRange,
            isCancelled: false
        )
    }

    static func semanticTargetRange(
        _ refreshRange: NSRange,
        in source: NSString,
        mutation: SyntaxEditorTextChange.Replacement? = nil
    ) -> NSRange? {
        let clamped = SyntaxEditorRangeUtilities.clampedRange(refreshRange, utf16Length: source.length)
        guard clamped.length > 0 else {
            return nil
        }

        let targetRange = source.lineRange(for: clamped)
        let contextRange = objectiveCUnsafeEditContextRange(around: targetRange, in: source)
        let context = source.substring(with: contextRange)
        if let mutation,
           objectiveCLocalEditCanKeepSemanticTarget(mutation, in: source) {
            let mutationTargetRange = source.lineRange(
                for: objectiveCMutationChangedRange(mutation, in: source)
            )
            return boxedExpressionRefreshRange(around: mutationTargetRange, in: source) ?? mutationTargetRange
        }
        if let mutation,
           objectiveCInsertedTextCanKeepSemanticTarget(mutation) {
            let mutationTargetRange = source.lineRange(
                for: objectiveCMutationChangedRange(mutation, in: source)
            )
            return boxedExpressionRefreshRange(around: mutationTargetRange, in: source) ?? mutationTargetRange
        }
        guard !objectiveCRefreshLooksStructural(context) else {
            guard let mutation,
                  objectiveCLocalEditCanKeepSemanticTarget(mutation, in: source) else {
                return nil
            }
            let mutationTargetRange = source.lineRange(
                for: objectiveCMutationChangedRange(mutation, in: source)
            )
            if !objectiveCRefreshLooksStructural(source.substring(with: mutationTargetRange)) {
                return boxedExpressionRefreshRange(around: mutationTargetRange, in: source) ?? mutationTargetRange
            }
            guard let scopeRange = ObjectiveCFileSymbolIndex.containingFunctionLikeScopeRange(
                containing: min(max(0, mutation.location), max(0, source.length - 1)),
                in: source
            ) else {
                return nil
            }
            return boxedExpressionRefreshRange(around: scopeRange, in: source) ?? scopeRange
        }
        guard mutation.map({ objectiveCLocalEditCanKeepSemanticTarget($0, in: source) }) != false else {
            return nil
        }
        return boxedExpressionRefreshRange(around: targetRange, in: source) ?? targetRange
    }
}
