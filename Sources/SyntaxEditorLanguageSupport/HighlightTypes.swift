import Foundation
import SyntaxEditorCoreTypes

/// Optional preparation of the highlighting resources shared by editors.
///
/// Call `prepare(_:)` before presenting an editor when you want to perform
/// first-use setup earlier. Editors also prepare their languages on demand.
public enum SyntaxEditorHighlighting {
package struct Token: Equatable, Sendable {
    package let range: NSRange
    package let syntaxID: EditorSourceSyntax.ID
    package let language: SyntaxLanguage?
    package let rawCaptureName: String
    package let isSemanticOverlay: Bool

    package init(
        range: NSRange,
        rawCaptureName: String,
        language: SyntaxLanguage = .swift
    ) {
        self.init(
            range: range,
            rawCaptureName: rawCaptureName,
            language: language,
            isSemanticOverlay: false
        )
    }

    package init(
        range: NSRange,
        rawCaptureName: String,
        language: SyntaxLanguage,
        isSemanticOverlay: Bool
    ) {
        let classification = EditorSourceSyntax.Capture.parse(
            rawCaptureName: rawCaptureName,
            rootLanguage: language
        )
        self.init(
            range: range,
            syntaxID: classification.syntaxID,
            language: classification.language ?? language,
            rawCaptureName: rawCaptureName,
            isSemanticOverlay: isSemanticOverlay
        )
    }

    package init(
        range: NSRange,
        syntaxID: EditorSourceSyntax.ID,
        language: SyntaxLanguage?,
        rawCaptureName: String
    ) {
        self.init(
            range: range,
            syntaxID: syntaxID,
            language: language,
            rawCaptureName: rawCaptureName,
            isSemanticOverlay: false
        )
    }

    package init(
        range: NSRange,
        syntaxID: EditorSourceSyntax.ID,
        language: SyntaxLanguage?,
        rawCaptureName: String,
        isSemanticOverlay: Bool
    ) {
        self.range = range
        self.syntaxID = syntaxID
        self.language = language
        self.rawCaptureName = rawCaptureName
        self.isSemanticOverlay = isSemanticOverlay
    }
}

package struct Result: Sendable {
    package enum Phase: Equatable, Sendable {
        case syntacticFastPass
        case complete
    }

    package enum Payload: Equatable, Sendable {
        case fullSnapshot
        case replacement
    }

    package let tokens: [SyntaxEditorHighlighting.Token]
    package let source: String
    package let language: SyntaxLanguage
    package let revision: Int
    package let refreshRanges: [NSRange]
    package let phase: SyntaxEditorHighlighting.Result.Phase
    package let tokenPayload: SyntaxEditorHighlighting.Result.Payload

    package init(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        refreshRanges: [NSRange],
        phase: SyntaxEditorHighlighting.Result.Phase = .complete,
        tokenPayload: SyntaxEditorHighlighting.Result.Payload = .fullSnapshot
    ) {
        self.tokens = tokens
        self.source = source
        self.language = language
        self.revision = revision
        self.refreshRanges = SyntaxEditorRangeUtilities.mergedRanges(refreshRanges)
        self.phase = phase
        self.tokenPayload = tokenPayload
    }

}

package struct Request: Equatable, Sendable {
    package enum Operation: Equatable, Sendable {
        case reset
        case update(SyntaxEditorTextChange.Replacement)
    }

    package let source: String
    package let language: SyntaxLanguage
    package let revision: Int
    package let operation: Operation
    /// Viewport hint: progressive opens and background semantic drains process
    /// the chunk nearest this range first. Purely an ordering hint — results
    /// and convergence are identical without it.
    package let visibleRange: NSRange?

    package init(
        source: String,
        language: SyntaxLanguage,
        revision: Int,
        operation: Operation,
        visibleRange: NSRange? = nil
    ) {
        self.source = source
        self.language = language
        self.revision = revision
        self.operation = operation
        self.visibleRange = visibleRange
    }
}

package enum Invalidation {
    // SwiftTreeSitter's LanguageLayer converts Tree-sitter byte ranges through
    // Range<UInt32>.range before returning an IndexSet, so these ranges are
    // already in NSRange/UTF-16 coordinates.
    package static func queryRange(
        invalidatedSet: IndexSet,
        mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length: Int
    ) -> NSRange {
        let replacementLength = mutation.replacement.utf16.count
        var lower = min(max(0, mutation.location), sourceUTF16Length)
        var upper = min(max(lower, mutation.location + replacementLength), sourceUTF16Length)

        for range in invalidatedSet.rangeView {
            lower = min(lower, max(0, min(range.lowerBound, sourceUTF16Length)))
            upper = max(upper, max(0, min(range.upperBound, sourceUTF16Length)))
        }

        if lower == upper, sourceUTF16Length > 0 {
            if upper < sourceUTF16Length {
                upper += 1
            } else {
                lower -= 1
            }
        }

        return NSRange(location: lower, length: upper - lower)
    }
}

/// The highlighting service an editor view talks to.
package protocol Engine: Sendable {
    /// Cancels the request in flight, if any, and starts `request`.
    ///
    /// The stream yields zero or more partial results and ends after the
    /// complete result. A request replaced by a later call ends its stream
    /// without a complete result.
    func replaceCurrentRequest(with request: SyntaxEditorHighlighting.Request) async -> AsyncStream<SyntaxEditorHighlighting.Result>
}
}

extension SyntaxEditorHighlighting.Result {
    package static func empty(source: String, language: SyntaxLanguage, revision: Int) -> SyntaxEditorHighlighting.Result {
        SyntaxEditorHighlighting.Result(
            tokens: [],
            source: source,
            language: language,
            revision: revision,
            refreshRanges: [NSRange(location: 0, length: source.utf16.count)]
        )
    }
}
