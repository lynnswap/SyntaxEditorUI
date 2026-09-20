import Foundation
import SyntaxEditorUI

extension MiniPreviewPreset:Hashable,Identifiable{
    nonisolated static func == (lhs: MiniPreviewPreset, rhs: MiniPreviewPreset) -> Bool {
        lhs.id == rhs.id
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct MiniPreviewPreset {
    enum ID: String, CaseIterable, Sendable {
        case comparison
        case largeComparison = "large-comparison"
        case plainText = "plain-text"
        case assemblyARM = "assembly-arm"
        case css
        case html
        case javascript
        case json
        case objectiveCHeader = "objective-c-header"
        case objectiveC = "objective-c"
        case swift
        case toml
        case xml
    }

    let id: ID
    let title: String
    let sampleFilename: String?
    let fallbackSampleText: String
    let language: SyntaxLanguage

    init(
        id: ID,
        title: String? = nil,
        sampleFilename: String? = nil,
        fallbackSampleText: String,
        language: SyntaxLanguage
    ) {
        self.id = id
        self.title = title ?? language.displayName
        self.sampleFilename = sampleFilename
        self.fallbackSampleText = fallbackSampleText
        self.language = language
    }

    var sampleText: String {
        sampleFilename.flatMap(Self.sampleText(named:)) ?? fallbackSampleText
    }

    var accessibilityIdentifier: String {
        "mini.language.\(id.rawValue)"
    }

    var comparisonReference: String? {
        switch id {
        case .comparison: MiniComparisonSample.original
        case .largeComparison: MiniComparisonSample.largeOriginal
        default: nil
        }
    }

    static let comparison = MiniPreviewPreset(
        id: .comparison,
        title: "Comparison",
        fallbackSampleText: MiniComparisonSample.modified,
        language: .swift
    )

    static let largeComparison = MiniPreviewPreset(
        id: .largeComparison,
        title: "Large Comparison",
        fallbackSampleText: MiniComparisonSample.largeModified,
        language: .swift
    )

    static let plainText = MiniPreviewPreset(
        id: .plainText,
        sampleFilename: "Reference.txt",
        fallbackSampleText: """
        Plain text note

        Parentheses (like this), quotes "like this", and brackets [like this]
        stay ordinary text in this mode.
        """,
        language: SyntaxLanguage.plainText
    )

    static let assemblyARM = MiniPreviewPreset(
        id: .assemblyARM,
        sampleFilename: "Reference.arm64.txt",
        fallbackSampleText: ".text\n_main:\n    mov x0, #42\n    ret\n",
        language: .assemblyARM
    )

    static let css = MiniPreviewPreset(
        id: .css,
        sampleFilename: "Reference.css",
        fallbackSampleText: "body {\n    color: red;\n    background: white;\n}\n",
        language: SyntaxLanguage.css
    )

    static let html = MiniPreviewPreset(
        id: .html,
        sampleFilename: "Reference.html",
        fallbackSampleText: """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            body { color: red; }
            </style>
        </head>
        <body>
            <!-- greeting -->
            <script>
            const answer = 42;
            </script>
            <div class=\"message\">Hello</div>
        </body>
        </html>
        """,
        language: SyntaxLanguage.html
    )

    static let javascript = MiniPreviewPreset(
        id: .javascript,
        sampleFilename: "Reference.js",
        fallbackSampleText: """
        const answer = 42;
        function greet(name) {
            return `Hello, ${name}! ` + "\(String(repeating: "Hello, ", count: 120))";
        }
        """,
        language: SyntaxLanguage.javascript
    )

    static let json = MiniPreviewPreset(
        id: .json,
        sampleFilename: "Reference.json",
        fallbackSampleText: """
        {
          \"enabled\": true,
          \"count\": 1
        }
        """,
        language: SyntaxLanguage.json
    )

    static let objectiveCHeader = MiniPreviewPreset(
        id: .objectiveCHeader,
        title: "Objective-C Header",
        sampleFilename: "Reference.h",
        fallbackSampleText: """
        #import <Foundation/Foundation.h>

        @interface Sample : NSObject
        @end
        """,
        language: SyntaxLanguage.objectiveC
    )

    static let objectiveC = MiniPreviewPreset(
        id: .objectiveC,
        title: "Objective-C Implementation",
        sampleFilename: "Reference.m",
        fallbackSampleText: """
        #import "Sample.h"

        @implementation Sample
        @end
        """,
        language: SyntaxLanguage.objectiveC
    )

    static let swift = MiniPreviewPreset(
        id: .swift,
        sampleFilename: "Reference.swift",
        fallbackSampleText: """
        struct Greeting {
            let message = \"Hello\"
        }
        """,
        language: SyntaxLanguage.swift
    )

    static let toml = MiniPreviewPreset(
        id: .toml,
        sampleFilename: "Reference.toml",
        fallbackSampleText: """
        [package]
        name = \"SyntaxEditorUI\"
        enabled = true
        """,
        language: SyntaxLanguage.toml
    )

    static let xml = MiniPreviewPreset(
        id: .xml,
        sampleFilename: "Reference.xml",
        fallbackSampleText: """
        <?xml version=\"1.0\"?>
        <note priority=\"high\">Hello</note>
        """,
        language: SyntaxLanguage.xml
    )

    static let all: [MiniPreviewPreset] = [
        comparison,
        largeComparison,
        plainText,
        assemblyARM,
        css,
        html,
        javascript,
        json,
        objectiveCHeader,
        objectiveC,
        swift,
        toml,
        xml,
    ]

    static func preset(for id: ID) -> MiniPreviewPreset? {
        all.first { $0.id == id }
    }

    private static func sampleText(named filename: String) -> String? {
        if let bundledURL = sampleURLInBundle(named: filename),
           let text = try? String(contentsOf: bundledURL, encoding: .utf8)
        {
            return text
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ReferenceSamples", isDirectory: true)
            .appendingPathComponent(filename)
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func sampleURLInBundle(named filename: String) -> URL? {
        let fileURL = URL(fileURLWithPath: filename)
        let resourceName = fileURL.deletingPathExtension().lastPathComponent
        let pathExtension = fileURL.pathExtension
        let resolvedExtension = pathExtension.isEmpty ? nil : pathExtension
        if let nestedURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: resolvedExtension,
            subdirectory: "ReferenceSamples"
        ) {
            return nestedURL
        }
        return Bundle.main.url(
            forResource: resourceName,
            withExtension: resolvedExtension
        )
    }
}
