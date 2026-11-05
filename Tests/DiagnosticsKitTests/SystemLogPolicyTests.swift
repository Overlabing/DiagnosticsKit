import Foundation
import Synchronization
import Testing
import os

@testable import DiagnosticsKit

/// Records what the kit hands to the system log, which the system log itself cannot show.
final class RecordingSystemLog: SystemLog {
    struct Line: Equatable {
        let category: String
        let type: OSLogType
        let redacted: String
        let full: String?
    }

    private let recorded = Mutex<[Line]>([])
    /// What the system collects: debug and info are usually not.
    private let collected: Set<OSLogType>

    init(collected: Set<OSLogType> = [.debug, .info, .default, .error, .fault]) { self.collected = collected }

    var lines: [Line] { recorded.withLock { $0 } }

    func channel(category: String) -> any SystemLogChannel {
        Channel(category: category, log: self)
    }

    private struct Channel: SystemLogChannel {
        let category: String
        let log: RecordingSystemLog

        func isEnabled(_ type: OSLogType) -> Bool { log.collected.contains(type) }

        func write(_ type: OSLogType, redacted: String, full: String?) {
            log.recorded.withLock { $0.append(Line(category: category, type: type, redacted: redacted, full: full)) }
        }
    }
}

/// What reaches the system log follows `OSLogPolicy`: with `.onlyWhileEnabled`, nothing while the log is off.
struct SystemLogPolicyTests {
    private static let noon = Date(timeIntervalSince1970: 1_793_188_800)

    private func make(
        _ policy: OSLogPolicy, isEnabled: Bool
    ) -> (log: DiagnosticLog, logger: DiagnosticLogger, system: RecordingSystemLog, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString)")
        var configuration = DiagnosticLogTests.configuration
        configuration.osLog = policy
        let system = RecordingSystemLog()
        let log = DiagnosticLog(
            configuration: configuration, flushDelay: .milliseconds(10), isEnabled: isEnabled, systemLog: system)
        log.start(now: { Self.noon }) { directory }
        return (log, DiagnosticLogger(category: "sync", sink: log), system, directory)
    }

    private func logEveryLevel(_ logger: DiagnosticLogger) {
        logger.trace("trace")
        logger.debug("debug")
        logger.info("info")
        logger.notice("notice \("secret@example.com")")
        logger.log("log")
        logger.warning("warning")
        logger.error("error")
        logger.critical("critical")
        logger.fault("fault")
        logger.log(level: .info, "level info")
        logger.log(level: .error, "level error")
    }

    @Test func onlyWhileEnabledWritesNothingToTheSystemLogWhileOff() async throws {
        let (log, logger, system, directory) = make(.onlyWhileEnabled, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        logEveryLevel(logger)
        log.record(error: CocoaError(.fileNoSuchFile), category: "report", summary: "Failed")
        await log.flush()
        #expect(system.lines.isEmpty)
        #expect(try await log.logFiles().isEmpty)
    }

    @Test func onlyWhileEnabledDoesNotEvenRenderTheMessageWhileOff() {
        let (_, logger, _, directory) = make(.onlyWhileEnabled, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendered = Mutex(0)
        func message() -> DiagnosticMessage {
            rendered.withLock { $0 += 1 }
            return "built"
        }
        logger.debug(message())
        logger.info(message())
        logger.notice(message())
        logger.error(message())
        logger.fault(message())
        #expect(rendered.withLock { $0 } == 0)
    }

    @Test func onlyWhileEnabledWritesEveryLineOnceTurnedOn() async throws {
        let (log, logger, system, directory) = make(.onlyWhileEnabled, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.notice("before")
        log.setEnabled(true)
        logger.notice("synced \(12) for \("secret@example.com")")
        logger.debug("fine")
        log.setEnabled(false)
        logger.notice("after")
        await log.flush()
        #expect(system.lines == [
            .init(category: "sync", type: .default, redacted: "synced 12 for <private>", full: "synced 12 for secret@example.com"),
            .init(category: "sync", type: .debug, redacted: "fine", full: nil),
        ])
    }

    @Test func publicFieldsAlwaysWritesWhileOffWithoutTouchingTheFile() async throws {
        let (log, logger, system, directory) = make(.publicFieldsAlways, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.notice("synced \(12) for \("secret@example.com")")
        logger.info("fine")
        logger.error("failed")
        await log.flush()
        #expect(system.lines == [
            .init(category: "sync", type: .default, redacted: "synced 12 for <private>", full: "synced 12 for secret@example.com"),
            .init(category: "sync", type: .info, redacted: "fine", full: nil),
            .init(category: "sync", type: .error, redacted: "failed", full: nil),
        ])
        #expect(try await log.logFiles().isEmpty)
    }

    @Test func debugAndInfoStayOutWhenTheSystemDoesNotCollectThem() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = RecordingSystemLog(collected: [.default, .error, .fault])
        let log = DiagnosticLog(
            configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10), isEnabled: true,
            systemLog: system)
        let rendered = Mutex(0)
        func message() -> DiagnosticMessage {
            rendered.withLock { $0 += 1 }
            return "built"
        }
        let logger = DiagnosticLogger(category: "sync", sink: log)
        logger.debug(message())
        logger.info(message())
        #expect(rendered.withLock { $0 } == 0)
        #expect(system.lines.isEmpty)
    }

    /// The writer's own failures follow the policy too: a folder that cannot be read is said in the system log only when
    /// the policy lets a line out.
    @Test(arguments: [(OSLogPolicy.onlyWhileEnabled, 0), (OSLogPolicy.publicFieldsAlways, 1)])
    func theWritersOwnFailuresFollowThePolicyWhileOff(policy: OSLogPolicy, expected: Int) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var configuration = DiagnosticLogTests.configuration
        configuration.osLog = policy
        let system = RecordingSystemLog()
        let log = DiagnosticLog(
            configuration: configuration, flushDelay: .milliseconds(10), isEnabled: false, systemLog: system)
        log.start(now: { Self.noon }) { file }
        await log.flush()
        #expect(system.lines.count == expected)
        if expected == 1 {
            #expect(system.lines[0].category == "diagnostics")
            #expect(system.lines[0].redacted.hasPrefix("Diagnostic log not pruned: "))
            #expect(system.lines[0].full == nil)
        }
    }

    @Test func theConfigurationDefaultsToTheStrictPolicy() {
        let configuration = DiagnosticsConfiguration(subsystem: "s", fileNamePrefix: "p", archiveName: "A")
        #expect(configuration.osLog == .onlyWhileEnabled)
        #expect(configuration.limits == .init(keepDays: 7, maxFileBytes: 5_000_000, maxTotalBytes: 25_000_000))
    }

    @Test func filesOfAnotherPrefixAreNotTheLogs() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["app-2026-10-01.log", "other-2026-10-01.log", "app-2026-10-27.log", "app-2026-10-27.txt", "app.log"] {
            try Data("x\n".utf8).write(to: directory.appending(path: name))
        }
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10), isEnabled: false)
        log.start(now: { Self.noon }) { directory }
        await log.flush()
        #expect(try await log.logFiles().map(\.lastPathComponent) == ["app-2026-10-27.log"])
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(left == ["app-2026-10-27.log", "app-2026-10-27.txt", "app.log", "other-2026-10-01.log"])
    }
}
