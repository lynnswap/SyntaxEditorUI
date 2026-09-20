// swift-tools-version: 6.3

import PackageDescription

let syntaxEditorSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "SyntaxEditorUI",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .macOS(.v15),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "SyntaxEditorUI",
            targets: ["SyntaxEditorUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/RubixDev/tree-sitter-asm", exact: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-objc", from: "3.0.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-xml", exact: "0.7.0"),
        .package(url: "https://github.com/lynnswap/tree-sitter-swift", exact: "0.1.0"),
        .package(url: "https://github.com/lynnswap/ObservationBridge", exact: "0.13.0"),
        .package(url: "https://github.com/ordo-one/benchmark", exact: "1.34.1", traits: []),
    ],
    targets: [
        .target(
            name: "XclangSpecSyntax",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "SourceModelBridge",
            path: "Sources/SourceModelBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "EditorSpecTool",
            dependencies: [
                "SourceModelBridge",
                "SyntaxEditorCore",
            ],
            path: "Tools/EditorSpecSnapshot/EditorSpecTool",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
                .unsafeFlags([
                    "-I", "Tools/EditorSpecSnapshot/PrivateInterfaces",
                    "-F", "/Applications/Xcode.app/Contents/SharedFrameworks",
                ], .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Applications/Xcode.app/Contents/SharedFrameworks",
                    "-framework", "SourceEditor",
                    "-framework", "SourceModel",
                    "-framework", "SourceModelSupport",
                    "-framework", "SymbolCache",
                    "-framework", "SymbolCacheIndexing",
                    "-framework", "SymbolCacheSupport",
                    "/Applications/Xcode.app/Contents/SharedFrameworks/SourceModel.framework/Versions/A/SourceModel",
                    "/Applications/Xcode.app/Contents/SharedFrameworks/SourceModelSupport.framework/Versions/A/SourceModelSupport",
                    "/Applications/Xcode.app/Contents/SharedFrameworks/SymbolCache.framework/Versions/A/SymbolCache",
                    "/Applications/Xcode.app/Contents/SharedFrameworks/SymbolCacheIndexing.framework/Versions/A/SymbolCacheIndexing",
                    "/Applications/Xcode.app/Contents/SharedFrameworks/SymbolCacheSupport.framework/Versions/A/SymbolCacheSupport",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Applications/Xcode.app/Contents/SharedFrameworks",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "HighlightBenchmark",
            dependencies: [
                "SyntaxEditorCore",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/HighlightBenchmark",
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ],
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
        .target(
            name: "SyntaxEditorCoreTypes",
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorTheme",
            dependencies: [
                "SyntaxEditorCoreTypes",
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorModel",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorTheme",
                .product(name: "ObservationBridge", package: "observationbridge"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageSupport",
            dependencies: [
                "SyntaxEditorCoreTypes",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageAssemblyARM",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterAsm", package: "tree-sitter-asm"),
            ],
            resources: [
                .copy("Resources/AssemblyARMQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageCSS",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
            ],
            resources: [
                .copy("Resources/CSSQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageJavaScript",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
            ],
            resources: [
                .copy("Resources/JavaScriptQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageHTML",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageCSS",
                "SyntaxEditorLanguageJavaScript",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
            ],
            resources: [
                .copy("Resources/HTMLQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageJSON",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            ],
            resources: [
                .copy("Resources/JSONQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageObjectiveC",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterObjc", package: "tree-sitter-objc"),
            ],
            resources: [
                .copy("Resources/ObjectiveCQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguagePlainText",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageSwift",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
            ],
            resources: [
                .copy("Resources/SwiftQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageTOML",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
            ],
            resources: [
                .copy("Resources/TOMLQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguageXML",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                .product(name: "TreeSitterXML", package: "tree-sitter-xml"),
            ],
            resources: [
                .copy("Resources/XMLQueries"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorLanguages",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageAssemblyARM",
                "SyntaxEditorLanguageCSS",
                "SyntaxEditorLanguageHTML",
                "SyntaxEditorLanguageJavaScript",
                "SyntaxEditorLanguageJSON",
                "SyntaxEditorLanguageObjectiveC",
                "SyntaxEditorLanguagePlainText",
                "SyntaxEditorLanguageSupport",
                "SyntaxEditorLanguageSwift",
                "SyntaxEditorLanguageTOML",
                "SyntaxEditorLanguageXML",
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorEditing",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageSupport",
                "SyntaxEditorLanguages",
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorHighlighting",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorLanguageCSS",
                "SyntaxEditorLanguageHTML",
                "SyntaxEditorLanguageObjectiveC",
                "SyntaxEditorLanguageSupport",
                "SyntaxEditorLanguageSwift",
                "SyntaxEditorLanguages",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "SwiftTreeSitterLayer", package: "SwiftTreeSitter"),
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorCore",
            dependencies: [
                "SyntaxEditorCoreTypes",
                "SyntaxEditorEditing",
                "SyntaxEditorHighlighting",
                "SyntaxEditorLanguageSupport",
                "SyntaxEditorLanguages",
                "SyntaxEditorModel",
                "SyntaxEditorTheme",
            ],
            swiftSettings: syntaxEditorSwiftSettings
        ),
        .target(
            name: "SyntaxEditorUI",
            dependencies: [
                "SyntaxEditorCore",
                "SyntaxEditorUICommon",
                "SyntaxEditorUISwiftUI",
                .target(name: "SyntaxEditorUIAppKit", condition: .when(platforms: [.macOS])),
                .target(name: "SyntaxEditorUIUIKit", condition: .when(platforms: [.iOS, .macCatalyst, .visionOS])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "SyntaxEditorUICommon",
            dependencies: [
                "SyntaxEditorCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "SyntaxEditorUIAppKit",
            dependencies: [
                "SyntaxEditorCore",
                "SyntaxEditorUICommon",
                .product(name: "ObservationBridge", package: "observationbridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "SyntaxEditorUIUIKit",
            dependencies: [
                "SyntaxEditorCore",
                "SyntaxEditorUICommon",
                .product(name: "ObservationBridge", package: "observationbridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "SyntaxEditorUISwiftUI",
            dependencies: [
                "SyntaxEditorCore",
                .target(name: "SyntaxEditorUIAppKit", condition: .when(platforms: [.macOS])),
                .target(name: "SyntaxEditorUIUIKit", condition: .when(platforms: [.iOS, .macCatalyst, .visionOS])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "SyntaxEditorUICommonTests",
            dependencies: [
                "SyntaxEditorUICommon",
            ]
        ),
        .testTarget(
            name: "SyntaxEditorUIAppKitTests",
            dependencies: [
                "SyntaxEditorUIAppKit",
                "SyntaxEditorUITestSupport",
            ]
        ),
        .testTarget(
            name: "SyntaxEditorUIUIKitTests",
            dependencies: [
                "SyntaxEditorUIUIKit",
                "SyntaxEditorUITestSupport",
            ]
        ),
        .testTarget(
            name: "SyntaxEditorUISwiftUITests",
            dependencies: [
                "SyntaxEditorUISwiftUI",
                "SyntaxEditorUITestSupport",
            ]
        ),
        .target(
            name: "SyntaxEditorUITestSupport",
            dependencies: [
                "SyntaxEditorCore",
                "SyntaxEditorUI",
                .product(name: "ObservationBridge", package: "observationbridge"),
            ],
            path: "Tests/SyntaxEditorUITestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "SyntaxEditorCoreTests",
            dependencies: [
                "SyntaxEditorCore",
                "SyntaxEditorModel",
                .product(name: "ObservationBridge", package: "observationbridge"),
            ]
        ),
        .testTarget(
            name: "XclangSpecSyntaxTests",
            dependencies: ["XclangSpecSyntax"]
        ),
        .testTarget(
            name: "SyntaxEditorCorePlatformTests",
            dependencies: ["SyntaxEditorCore"]
        ),
        .testTarget(
            name: "SyntaxEditorUITests",
            dependencies: [
                "SyntaxEditorUI",
                "SyntaxEditorUIAppKit",
                "SyntaxEditorUIUIKit",
                "SyntaxEditorUITestSupport",
                .product(name: "ObservationBridge", package: "observationbridge"),
            ]
        ),
    ]
)
