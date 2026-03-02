import Foundation

public enum SyntaxLanguage: String, CaseIterable, Hashable, Sendable {
    case css
    case javascript
    case json

    public init?(normalizedRawValue: String) {
        let lowered = normalizedRawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch lowered {
        case "css":
            self = .css
        case "javascript", "js":
            self = .javascript
        case "json":
            self = .json
        default:
            return nil
        }
    }
}
