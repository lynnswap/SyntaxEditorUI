import Foundation

enum MiniComparisonSample {
    static let original = #"""
    import Foundation

    struct ReleaseNote {
        let version: String
        let title: String
        let owner: String

        /*
         Keep the internal draft until the team signs off.
         This instruction is removed in the new version.
         */
        func summary() -> String {
            return "\(version): \(title)"
        }
    }

    let release = ReleaseNote(
        version: "1.0",
        title: "Editor preview",
        owner: "Desktop team"
    )

    print(release.summary())
    """# + "\n"

    static let modified = #"""
    import Foundation

    struct ReleaseNote {
        let version: String
        let title: String
        let isPublished: Bool

        /*
         Keep the release notes available to everyone.
         */
        func summary() -> String {
            return "Version \(version) — \(title)"
        }

        var status: String {
            isPublished ? "Published" : "Draft"
        }
    }

    let release = ReleaseNote(
        version: "1.1",
        title: "Compare every change",
        isPublished: true
    )

    print(release.summary())
    print(release.status)
    """# + "\n"

    static let largeOriginal = (0..<10_000).map { "let item_\($0) = \($0)\n" }.joined()

    static let largeModified = (0..<10_000).compactMap { index -> String? in
        if (100..<1_100).contains(index) { return nil }
        if index == 5_000 { return "let item_5000 = 42\n" }
        if index == 9_900 { return "let newItem = \"Added near the end\"\nlet item_9900 = 9900\n" }
        return "let item_\(index) = \(index)\n"
    }.joined()
}
