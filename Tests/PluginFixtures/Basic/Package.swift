// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftJSONSchemaGenPluginFixture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Fixture", targets: ["Fixture"])
    ],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        .target(
            name: "Fixture",
            plugins: [
                .plugin(name: "SwiftJSONSchemaGenPlugin", package: "SwiftJSONSchemaGen")
            ]
        )
    ]
)
