// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SyntaxEditorUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "SyntaxEditorUI",
            targets: ["SyntaxEditorUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.1-with-generated-files"),
        .package(url: "https://github.com/lynnswap/ObservationBridge", exact: "0.5.1"),
    ],
    targets: [
        .target(
            name: "SyntaxEditorUI",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "ObservationBridge", package: "observationbridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "SyntaxEditorUITests",
            dependencies: ["SyntaxEditorUI"]
        ),
    ]
)
