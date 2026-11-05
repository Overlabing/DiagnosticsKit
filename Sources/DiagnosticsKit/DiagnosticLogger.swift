import Foundation
import os

/// Drop-in for `os.Logger` (same method names, same `privacy:` and `format:` interpolations) that also mirrors every
/// line of level notice and above into the local diagnostic log (`DiagnosticLog`), the file a tester exports.
///
/// `os.Logger` itself cannot be wrapped: its `OSLogMessage` is built by the compiler and cannot be read back, and
/// reading the unified log back with `OSLogStore` costs about ten seconds per read (measured 2026-10-28). The message is
/// therefore rendered here, twice: with private values replaced by `<private>` (os_log in clear, and the file), and in
/// full (os_log, `privacy: .private`). A private value never reaches the file.
///
/// Debug and info lines go to os_log only and are not even rendered unless the system collects that level. What reaches
/// os_log at all follows the log's `OSLogPolicy`: with `.onlyWhileEnabled`, a line is not even rendered while the log is
/// off.
public struct DiagnosticLogger: Sendable {
    public let category: String
    public let sink: DiagnosticLog
    private let channel: any DiagnosticSystemLogChannel

    public init(category: String, sink: DiagnosticLog) {
        self.category = category
        self.sink = sink
        channel = sink.systemLog.channel(category: category)
    }

    public func trace(_ message: @autoclosure () -> DiagnosticMessage) { debug(message()) }

    public func debug(_ message: @autoclosure () -> DiagnosticMessage) {
        guard sink.writesToSystemLog, channel.isEnabled(.debug) else { return }
        emit(.debug, message())
    }

    public func info(_ message: @autoclosure () -> DiagnosticMessage) {
        guard sink.writesToSystemLog, channel.isEnabled(.info) else { return }
        emit(.info, message())
    }

    public func notice(_ message: @autoclosure () -> DiagnosticMessage) { record(.notice, message) }

    public func log(_ message: @autoclosure () -> DiagnosticMessage) { record(.notice, message) }

    public func warning(_ message: @autoclosure () -> DiagnosticMessage) { record(.warning, message) }

    public func error(_ message: @autoclosure () -> DiagnosticMessage) { record(.error, message) }

    public func critical(_ message: @autoclosure () -> DiagnosticMessage) { record(.fault, message) }

    public func fault(_ message: @autoclosure () -> DiagnosticMessage) { record(.fault, message) }

    public func log(level: OSLogType, _ message: @autoclosure () -> DiagnosticMessage) {
        switch level {
        case .debug: debug(message())
        case .info: info(message())
        case .error: record(.error, message)
        case .fault: record(.fault, message)
        default: record(.notice, message)
        }
    }

    /// Off with `.onlyWhileEnabled`: the message is never built, nothing is written anywhere.
    private func record(_ level: DiagnosticLevel, _ message: () -> DiagnosticMessage) {
        let toSystemLog = sink.writesToSystemLog
        guard toSystemLog || sink.isEnabled else { return }
        let message = message()
        if toSystemLog { emit(level.osLogType, message) }
        sink.record(DiagnosticEntry(date: Date(), level: level, category: category, message: message.redacted))
    }

    private func emit(_ type: OSLogType, _ message: DiagnosticMessage) {
        channel.write(type, redacted: message.redacted, full: message.hasPrivate ? message.full : nil)
    }
}
