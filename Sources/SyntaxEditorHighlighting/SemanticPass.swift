import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SyntaxEditorLanguageCSS
import SyntaxEditorLanguageHTML
import SyntaxEditorLanguageObjectiveC
import SyntaxEditorLanguageSwift
import SwiftTreeSitter

/// The per-language semantic seam.
///
/// Stage S1: every language runs the conservative path — `fullMerge` produces
/// the complete merged token list for the whole document (identical to what a
/// fresh full pass yields, so incremental == full holds by construction).
/// Later stages add edit-local planning behind this same seam without touching
/// the engine pipeline.
package protocol SemanticPass: AnyObject {
    /// Full-document semantic merge over the current base tokens.
    /// `tokens` is the store's merged materialization (base + stale overlays);
    /// passes strip/replace overlay tokens per their language's rules.
    func fullMerge(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node?
    ) -> (tokens: [SyntaxEditorHighlighting.Token], isCancelled: Bool)

    /// Drops any cached state (after cancellation or reset).
    func invalidate()

    /// Edit-local planning: validate/maintain the language's semantic state for
    /// the committed edit and bound the reclassification targets. nil means the
    /// pass has no incremental support (the engine runs `fullMerge`).
    /// `previousSource` is the pre-edit text (`mutation` is in its
    /// coordinates); passes that classify removed text need it.
    func plannedUpdate(
        mutation: SyntaxEditorTextChange.Replacement,
        envelope: NSRange,
        source: String,
        previousSource: String,
        rootNode: Node?
    ) -> SemanticUpdatePlan?

    /// Overlay tokens for one target range (planned path). `baseTokens` are the
    /// store's base-plane tokens intersecting the target.
    func overlayTokens(
        in targetRange: NSRange,
        baseTokens: [SyntaxEditorHighlighting.Token],
        source: String
    ) -> [SyntaxEditorHighlighting.Token]

    /// True when the full-document pass can run as chunked `overlayTokens`
    /// calls over a debt set instead of one monolithic `fullMerge` — the
    /// engine then never blocks its actor for a document-sized pass.
    var supportsChunkedFullPass: Bool { get }

    /// Validates/rebuilds whatever state `overlayTokens` needs for a chunked
    /// full pass over the current text. Returns false when cancelled
    /// mid-build; the engine then leaves convergence to the next update.
    func prepareFullPass(source: String, rootNode: Node?) -> Bool
}

/// Outcome of `plannedUpdate`.
package enum SemanticUpdatePlan {
    /// Semantic state survived the edit; only the edit envelope needs overlays.
    case reuse
    /// State updated; the envelope plus these scope-bounded ranges need overlays.
    case targets([NSRange])
    /// State updated; the envelope, bounded ranges, and base-token lines whose
    /// text exactly matches one of these names need overlays.
    case tokenTextTargets(names: Set<String>, ranges: [NSRange])
    /// The edit's effects are not boundable; run the full-document merge.
    case full
}

package extension SemanticPass {
    func plannedUpdate(
        mutation: SyntaxEditorTextChange.Replacement,
        envelope: NSRange,
        source: String,
        previousSource: String,
        rootNode: Node?
    ) -> SemanticUpdatePlan? {
        nil
    }

    func overlayTokens(
        in targetRange: NSRange,
        baseTokens: [SyntaxEditorHighlighting.Token],
        source: String
    ) -> [SyntaxEditorHighlighting.Token] {
        []
    }

    var supportsChunkedFullPass: Bool { false }

    func prepareFullPass(source: String, rootNode: Node?) -> Bool {
        true
    }
}

package enum SemanticPassFactory {
    package static func make(language: SyntaxLanguage) -> SemanticPass? {
        switch language {
        case .swift:
            return SwiftSemanticPass()
        case .objectiveC:
            return ObjectiveCSemanticPass()
        case .css:
            return CSSSemanticPass(rawTextRegionsProvider: nil)
        case .html:
            return CSSSemanticPass(rawTextRegionsProvider: { source in
                let regions = HTMLLanguage.rawTextContentRegions(in: source)
                return CSSSemanticPass.RawTextRegions(all: regions.all, css: regions.css)
            })
        default:
            return nil
        }
    }
}

/// Swift semantic pass on the tree-derived scope index.
///
/// The classification rules (the color specification) live in
/// `SwiftSyntaxOverlayTokenProvider`; this pass owns state and locality:
/// in-place shift + bounded subtree rebuild validate the index per edit, and
/// the declaration diff bounds reclassification to the scopes that actually
/// changed (a declaration's influence cannot exceed its scope).
final class SwiftSemanticPass: SemanticPass {
    private var state: SwiftSemanticOverlayState?

    func fullMerge(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node?
    ) -> (tokens: [SyntaxEditorHighlighting.Token], isCancelled: Bool) {
        let result = SwiftSyntaxOverlayTokenProvider.mergingOverlayResult(
            tokens: tokens,
            source: source,
            rootNode: rootNode,
            refreshRange: nil,
            state: &state
        )
        return (result.tokens, result.isCancelled)
    }

    func plannedUpdate(
        mutation: SyntaxEditorTextChange.Replacement,
        envelope: NSRange,
        source: String,
        previousSource: String,
        rootNode: Node?
    ) -> SemanticUpdatePlan? {
        // Every .full return discards state: a failed in-place shift leaves the
        // index partially mutated, and a kept-but-stale index would otherwise
        // slip past `prepareFullPass`'s length check on length-neutral edits.
        guard let rootNode else {
            state = nil
            return .full
        }
        let nsSource = source as NSString
        guard nsSource.length > 0 else {
            state = nil
            return .full
        }
        guard let index = state?.scopeIndex,
              index.shiftInPlace(by: mutation, sourceUTF16Length: nsSource.length)
        else {
            state = nil
            return .full
        }
        guard let update = index.applySubtreeUpdate(
            envelope: SyntaxEditorRangeUtilities.clampedRange(envelope, utf16Length: nsSource.length),
            rootNode: rootNode,
            source: nsSource
        ) else {
            // Cancelled mid-maintenance or unsplicable: the shifted index is
            // coordinate-correct but stale in the envelope — discard it.
            state = nil
            return .full
        }
        state = SwiftSemanticOverlayState(scopeIndex: index, indexedSourceUTF16Length: nsSource.length)
        if update.requiresFullPass {
            return .full
        }
        if !update.tokenTextTargetNames.isEmpty {
            return .tokenTextTargets(
                names: update.tokenTextTargetNames,
                ranges: update.boundedTargets
            )
        }
        if update.boundedTargets.isEmpty {
            return .reuse
        }
        return .targets(update.boundedTargets)
    }

    func overlayTokens(
        in targetRange: NSRange,
        baseTokens: [SyntaxEditorHighlighting.Token],
        source: String
    ) -> [SyntaxEditorHighlighting.Token] {
        SwiftSyntaxOverlayTokenProvider.overlayTokens(
            in: targetRange,
            baseTokens: baseTokens,
            source: source,
            index: state?.scopeIndex
        )
    }

    var supportsChunkedFullPass: Bool { true }

    /// `.full` plans always discard state (see `plannedUpdate`), so a surviving
    /// index here is the requiresFullPass case — already shifted and rebuilt for
    /// this text. Anything else rebuilds from the current tree; nil = cancelled.
    func prepareFullPass(source: String, rootNode: Node?) -> Bool {
        let nsSource = source as NSString
        guard nsSource.length > 0 else { return false }
        if let existing = state, existing.scopeIndex != nil,
           existing.indexedSourceUTF16Length == nsSource.length {
            return true
        }
        guard let rootNode, let index = SwiftScopeIndex(rootNode: rootNode, source: nsSource) else {
            state = nil
            return false
        }
        state = SwiftSemanticOverlayState(scopeIndex: index, indexedSourceUTF16Length: nsSource.length)
        return true
    }

    func invalidate() {
        state = nil
    }
}

/// Objective-C pass: `plannedUpdate` bounds in-body edits via the provider's
/// shifted semantic index; anything declaration-shaped falls back to the
/// conservative full-document merge. `supportsChunkedFullPass` stays false —
/// the position-keyed classification runs its document pass as one detached
/// merge, so the engine must not plan against this pass while that merge is
/// in flight (its detached task writes the shared state on completion).
final class ObjectiveCSemanticPass: SemanticPass {
    private var state: ObjectiveCSemanticOverlayState?

    func fullMerge(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node?
    ) -> (tokens: [SyntaxEditorHighlighting.Token], isCancelled: Bool) {
        let result = ObjectiveCSyntaxOverlayTokenProvider.mergingOverlayResult(
            tokens: tokens,
            source: source,
            rootNode: rootNode,
            refreshRange: nil,
            state: &state
        )
        return (result.tokens, result.isCancelled)
    }

    func plannedUpdate(
        mutation: SyntaxEditorTextChange.Replacement,
        envelope: NSRange,
        source: String,
        previousSource: String,
        rootNode: Node?
    ) -> SemanticUpdatePlan? {
        switch ObjectiveCSyntaxOverlayTokenProvider.plannedSemanticUpdate(
            mutation: mutation,
            envelope: envelope,
            source: source,
            state: &state
        ) {
        case .bounded(let target):
            return .targets([target])
        case .full:
            return .full
        }
    }

    func overlayTokens(
        in targetRange: NSRange,
        baseTokens: [SyntaxEditorHighlighting.Token],
        source: String
    ) -> [SyntaxEditorHighlighting.Token] {
        ObjectiveCSyntaxOverlayTokenProvider.overlayTokens(
            in: targetRange,
            baseTokens: baseTokens,
            source: source,
            state: state
        )
    }

    func invalidate() {
        state = nil
    }
}

/// CSS (and CSS-in-HTML) pass: the provider is pure and stateless; for HTML the
/// scanning ranges are the embedded `<style>` contents of the masked source.
///
/// `plannedUpdate` covers one exactly-provable case: an edit strictly outside
/// every raw-text region that neither adds nor removes quote characters.
/// Every input of the CSS overlay synthesis is region-scoped (the scanners are
/// clipped to the scanning ranges, keyword suppression reads css-language base
/// tokens which only exist inside them), and with `<`/`>` already excluded by
/// the engine's markup-boundary reset and quotes excluded here, no HTML
/// analyzer state downstream of the edit can change ('>' cannot occur in
/// unquoted attribute values, so quote parity is the only remaining ripple).
/// The overlay set is therefore shift-only, which the token planes already
/// performed — the plan is `.reuse`. Everything else stays the conservative
/// full merge.
final class CSSSemanticPass: SemanticPass {
    struct RawTextRegions {
        let all: [NSRange]
        let css: [NSRange]
    }

    private struct State {
        var regions: RawTextRegions
        var sourceUTF16Length: Int
    }

    private let rawTextRegionsProvider: ((String) -> RawTextRegions)?
    private var state: State?

    init(rawTextRegionsProvider: ((String) -> RawTextRegions)?) {
        self.rawTextRegionsProvider = rawTextRegionsProvider
    }

    func fullMerge(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node?
    ) -> (tokens: [SyntaxEditorHighlighting.Token], isCancelled: Bool) {
        if let rawTextRegionsProvider {
            let regions = rawTextRegionsProvider(source)
            state = State(regions: regions, sourceUTF16Length: (source as NSString).length)
            return (
                CSSSyntaxOverlayTokenProvider.mergingOverlayTokens(
                    tokens: tokens,
                    source: source,
                    scanningRanges: regions.css
                ),
                false
            )
        }
        return (
            CSSSyntaxOverlayTokenProvider.mergingOverlayTokens(tokens: tokens, source: source),
            false
        )
    }

    func plannedUpdate(
        mutation: SyntaxEditorTextChange.Replacement,
        envelope: NSRange,
        source: String,
        previousSource: String,
        rootNode: Node?
    ) -> SemanticUpdatePlan? {
        guard rawTextRegionsProvider != nil else {
            // Pure CSS documents scan the whole text; no boundable case yet.
            return .full
        }
        guard let previousState = state else {
            state = nil
            return .full
        }
        let nsPrevious = previousSource as NSString
        let nsNext = source as NSString
        let replacementLength = mutation.replacement.utf16.count
        guard previousState.sourceUTF16Length == nsPrevious.length,
              mutation.location >= 0,
              mutation.length >= 0,
              mutation.location + mutation.length <= nsPrevious.length,
              nsNext.length == nsPrevious.length - mutation.length + replacementLength
        else {
            state = nil
            return .full
        }

        // Quote characters toggle the only analyzer state that can leak past
        // the engine's markup-boundary guard (quoted attribute values may
        // contain '>'); adding or removing one can move region boundaries
        // far from the edit.
        let removedText = nsPrevious.substring(
            with: NSRange(location: mutation.location, length: mutation.length)
        )
        guard !Self.containsQuote(removedText), !Self.containsQuote(mutation.replacement) else {
            state = nil
            return .full
        }

        // The edit must sit strictly outside every raw-text content range
        // (touching an endpoint grows that region's content), and the
        // reclassified envelope must not clear overlays inside a CSS range.
        let editSpan = NSRange(location: mutation.location, length: mutation.length)
        guard !previousState.regions.all.contains(where: { Self.touches($0, editSpan) }) else {
            state = nil
            return .full
        }
        let delta = replacementLength - mutation.length
        guard let shiftedAll = Self.shifted(previousState.regions.all, after: editSpan, by: delta),
              let shiftedCSS = Self.shifted(previousState.regions.css, after: editSpan, by: delta)
        else {
            state = nil
            return .full
        }
        guard !shiftedCSS.contains(where: { Self.touches($0, envelope) }) else {
            state = nil
            return .full
        }

        state = State(
            regions: RawTextRegions(all: shiftedAll, css: shiftedCSS),
            sourceUTF16Length: nsNext.length
        )
        return .reuse
    }

    /// Only reached on the `.reuse` path, whose plan guarantees the envelope
    /// is disjoint from every CSS scanning range — there are no overlays to
    /// produce (or clear) there.
    func overlayTokens(
        in targetRange: NSRange,
        baseTokens: [SyntaxEditorHighlighting.Token],
        source: String
    ) -> [SyntaxEditorHighlighting.Token] {
        []
    }

    func invalidate() {
        state = nil
    }

    private static func containsQuote(_ text: String) -> Bool {
        text.utf16.contains { $0 == 34 || $0 == 39 }
    }

    private static func touches(_ range: NSRange, _ span: NSRange) -> Bool {
        span.location <= range.upperBound && span.upperBound >= range.location
    }

    private static func shifted(_ ranges: [NSRange], after editSpan: NSRange, by delta: Int) -> [NSRange]? {
        var shiftedRanges: [NSRange] = []
        shiftedRanges.reserveCapacity(ranges.count)
        for range in ranges {
            if range.location >= editSpan.upperBound {
                let location = range.location + delta
                guard location >= 0 else { return nil }
                shiftedRanges.append(NSRange(location: location, length: range.length))
            } else {
                shiftedRanges.append(range)
            }
        }
        return shiftedRanges
    }
}
