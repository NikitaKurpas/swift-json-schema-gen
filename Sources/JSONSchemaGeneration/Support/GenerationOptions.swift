import Foundation

public struct GenerationOptions: Sendable {
    public var sendable: Bool
    public var warningsAsErrors: Bool

    public init(
        sendable: Bool = false,
        warningsAsErrors: Bool = false
    ) {
        self.sendable = sendable
        self.warningsAsErrors = warningsAsErrors
    }

    var conformancesSuffix: String {
        sendable ? ", Sendable" : ""
    }
}
