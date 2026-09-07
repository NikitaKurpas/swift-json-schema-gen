import ArgumentParser

public enum DiagnosticsFormat: String, ExpressibleByArgument, Sendable {
    case human
    case json
}
