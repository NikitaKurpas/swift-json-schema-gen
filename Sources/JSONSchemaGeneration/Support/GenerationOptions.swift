import Foundation

public struct GenerationOptions: Sendable {
    public var sendable: Bool
    public var warningsAsErrors: Bool
    public var accessLevel: GeneratedAccessLevel

    public init(
        sendable: Bool = false,
        warningsAsErrors: Bool = false,
        accessLevel: GeneratedAccessLevel = .public
    ) {
        self.sendable = sendable
        self.warningsAsErrors = warningsAsErrors
        self.accessLevel = accessLevel
    }

    var conformancesSuffix: String {
        sendable ? ", Sendable" : ""
    }
}
