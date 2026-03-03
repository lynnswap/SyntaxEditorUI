import Foundation

public enum SyntaxLanguage: String, CaseIterable, Hashable, Sendable {
    case css
    case javascript
    case json
    case swift

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
        case "swift":
            self = .swift
        default:
            return nil
        }
    }
}
