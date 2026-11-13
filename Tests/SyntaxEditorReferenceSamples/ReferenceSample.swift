import Foundation

/// Sample documents, one per supported language, for highlighter tests and
/// benchmarks.
package enum ReferenceSample {
    /// The location of the bundled sample, such as `Reference.swift`.
    package static func url(named fileName: String) -> URL? {
        Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "Samples")
    }

    /// The contents of the bundled sample.
    ///
    /// - Throws: `CocoaError(.fileNoSuchFile)` when no sample has that name, or
    ///   the error from reading the file.
    package static func text(named fileName: String) throws -> String {
        guard let url = url(named: fileName) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileName])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
