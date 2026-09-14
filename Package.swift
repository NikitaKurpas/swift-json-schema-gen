// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SwiftJSONSchemaGen",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "JSONSchemaGeneration",
            targets: ["JSONSchemaGeneration"]
        ),
        .executable(name: "SwiftJSONSchemaGen", targets: ["SwiftJSONSchemaGenCLI"]),
        .plugin(name: "SwiftJSONSchemaGenPlugin", targets: ["SwiftJSONSchemaGenPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
        .package(url: "https://github.com/ajevans99/swift-json-schema.git", from: "0.11.1"),
    ],
    targets: [
        .target(
            name: "JSONSchemaGeneration",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            resources: [
                .copy("Resources/MetaSchemas/draft-07-schema.json"),
                .copy("Resources/MetaSchemas/draft-2020-12-core.json"),
                .copy("Resources/MetaSchemas/draft-2020-12-applicator.json"),
                .copy("Resources/MetaSchemas/draft-2020-12-validation.json"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .strictMemorySafety(),
            ]
        ),
        .executableTarget(
            name: "SwiftJSONSchemaGenCLI",
            dependencies: [
                "JSONSchemaGeneration",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .strictMemorySafety(),
            ]
        ),
        .plugin(
            name: "SwiftJSONSchemaGenPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftJSONSchemaGenCLI"]
        ),
        .testTarget(
            name: "SwiftJSONSchemaGenTests",
            dependencies: [
                "JSONSchemaGeneration",
                "SwiftJSONSchemaGenCLI",
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SwiftJSONSchemaGenCLITests",
            dependencies: ["SwiftJSONSchemaGenCLI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
