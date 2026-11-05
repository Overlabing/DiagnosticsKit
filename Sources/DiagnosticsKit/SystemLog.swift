import Foundation
import os

/// The seam to the unified system log. The kit's own types write through it, so a test can see exactly what is
/// forwarded, which the system log itself cannot show.
protocol SystemLog: Sendable {
    func channel(category: String) -> any SystemLogChannel
}

/// One category's line to the system log.
protocol SystemLogChannel: Sendable {
    /// Whether the system collects lines of this type at all (debug and info usually not).
    func isEnabled(_ type: OSLogType) -> Bool
    /// `full` is the form with private values, written `privacy: .private`; nil when there is none.
    func write(_ type: OSLogType, redacted: String, full: String?)
}

struct OSLogSystemLog: SystemLog {
    let subsystem: String

    func channel(category: String) -> any SystemLogChannel {
        let osLog = OSLog(subsystem: subsystem, category: category)
        return OSLogChannel(osLog: osLog, logger: Logger(osLog))
    }
}

private struct OSLogChannel: SystemLogChannel {
    let osLog: OSLog
    let logger: Logger

    func isEnabled(_ type: OSLogType) -> Bool { osLog.isEnabled(type: type) }

    func write(_ type: OSLogType, redacted: String, full: String?) {
        if let full {
            logger.log(level: type, "\(redacted, privacy: .public) · \(full, privacy: .private)")
        } else {
            logger.log(level: type, "\(redacted, privacy: .public)")
        }
    }
}
