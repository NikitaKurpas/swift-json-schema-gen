// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "BasicLibraryConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "BasicLibraryConsumer",
            dependencies: [
                .product(name: "JSONSchemaGeneration", package: "SwiftJSONSchemaGen")
            ]
        )
    ]
)
