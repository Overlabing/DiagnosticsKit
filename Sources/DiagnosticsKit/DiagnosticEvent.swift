import Foundation

/// A typed event an app can log in one call: `logger.record(event)`. The app's own enum or struct says where the event
/// belongs (`category`), how serious it is (`level`) and what it says (`message`), with the same per-value privacy as
/// any other message.
public protocol DiagnosticEventConvertible: Sendable {
    var category: String { get }
    var level: DiagnosticLevel { get }
    /// Built only when something uses it: not at all while the log is off under `.onlyWhileEnabled`.
    var message: DiagnosticMessage { get }
}
