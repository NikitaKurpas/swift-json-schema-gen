# Third-party software

SwiftJSONSchemaGen links open-source packages resolved by Swift Package Manager
and bundles meta-schema documents published by the JSON Schema project.

Source releases use `Package.resolved` as the authoritative dependency version and
revision inventory. Binary archives include that inventory plus every resolved
package's root license and notice files under `ThirdPartyLicenses/`.
The JSON Schema meta-schema notice and BSD license terms are reproduced in `NOTICE`.

The direct runtime dependencies are:

- [Swift Argument Parser](https://github.com/apple/swift-argument-parser)
- [Swift Configuration](https://github.com/apple/swift-configuration)
- [SwiftSyntax](https://github.com/swiftlang/swift-syntax)

Their transitive dependencies are included in the archive inventory. The
test-only [swift-json-schema](https://github.com/ajevans99/swift-json-schema)
license may also be included; including it does not add it to the shipped executable.
