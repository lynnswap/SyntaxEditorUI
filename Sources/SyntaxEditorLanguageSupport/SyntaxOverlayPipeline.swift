import Foundation
import SyntaxEditorCoreTypes
import SwiftTreeSitter

package protocol SyntaxOverlayState {}

package struct SyntaxOverlayResult {
    package let tokens: [SyntaxEditorHighlighting.Token]
    package let refreshRangeOverride: NSRange?
    package let isCancelled: Bool

    package init(
        tokens: [SyntaxEditorHighlighting.Token],
        refreshRangeOverride: NSRange?,
        isCancelled: Bool
    ) {
        self.tokens = tokens
        self.refreshRangeOverride = refreshRangeOverride
        self.isCancelled = isCancelled
    }
}

package protocol SyntaxOverlayProvider {
    associatedtype State: SyntaxOverlayState

    static func mergingOverlayResult(
        tokens: [SyntaxEditorHighlighting.Token],
        source: String,
        rootNode: Node?,
        refreshRange: NSRange?,
        state: inout State?
    ) -> SyntaxOverlayResult
}

package struct SyntaxOverlayRangeKey: Hashable {
    package let location: Int
    package let length: Int

    package init(_ range: NSRange) {
        location = range.location
        length = range.length
    }
}

package struct SyntaxOverlayTokenKey: Hashable {
    package let range: SyntaxOverlayRangeKey
    package let rawCaptureName: String

    package init(_ token: SyntaxEditorHighlighting.Token) {
        range = SyntaxOverlayRangeKey(token.range)
        rawCaptureName = token.rawCaptureName
    }
}

package struct SyntaxOverlaySyntaxIDMask: OptionSet {
    package let rawValue: UInt32

    package static let identifier = Self(rawValue: 1 << 0)
    package static let identifierType = Self(rawValue: 1 << 1)
    package static let identifierTypeSystem = Self(rawValue: 1 << 2)
    package static let identifierFunction = Self(rawValue: 1 << 3)
    package static let identifierFunctionSystem = Self(rawValue: 1 << 4)
    package static let declarationType = Self(rawValue: 1 << 5)
    package static let declarationOther = Self(rawValue: 1 << 6)
    package static let keyword = Self(rawValue: 1 << 7)
    package static let plain = Self(rawValue: 1 << 8)

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package init(syntaxID: EditorSourceSyntax.ID) {
        switch syntaxID {
        case .identifier:
            self = .identifier
        case .identifierType:
            self = .identifierType
        case .identifierTypeSystem:
            self = .identifierTypeSystem
        case .identifierFunction:
            self = .identifierFunction
        case .identifierFunctionSystem:
            self = .identifierFunctionSystem
        case .declarationType:
            self = .declarationType
        case .declarationOther:
            self = .declarationOther
        case .keyword:
            self = .keyword
        case .plain:
            self = .plain
        default:
            self = []
        }
    }
}
