import Foundation
import Synchronization
import Testing
import os

@testable import DiagnosticsKit

/// `.publicMessagesAlways`: a message whose interpolations are all public always reaches the system log; a message with
/// one private interpolation reaches it only while the log is on. Derived from the message's own privacy.
struct PublicMessagesPolicyTests {
    private static let noon = Date(timeIntervalSince1970: 1_793_188_800)

    private func make(
        _ policy: OSLogPolicy, isEnabled: Bool, collected: Set<OSLogType> = [.debug, .info, .default, .error, .fault]
    ) -> (log: DiagnosticLog, logger: DiagnosticLogger, system: RecordingSystemLog, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString)")
        var configuration = DiagnosticLogTests.configuration
        configuration.osLog = policy
        let system = RecordingSystemLog(collected: collected)
        let log = DiagnosticLog(
            configuration: configuration, flushDelay: .milliseconds(10), isEnabled: isEnabled, systemLog: system)
        log.start(now: { Self.noon }) { directory }
        return (log, DiagnosticLogger(category: "sync", sink: log), system, directory)
    }

    /// Every entry point, once, with a string that is private without annotation.
    private func logEveryLevelWithAPrivateValue(_ logger: DiagnosticLogger) {
        let address = "secret@example.com"
        logger.trace("trace \(address)")
        logger.debug("debug \(address)")
        logger.info("info \(address)")
        logger.notice("notice \(address)")
        logger.log("log \(address)")
        logger.warning("warning \(address)")
        logger.error("error \(address)")
        logger.critical("critical \(address)")
        logger.fault("fault \(address)")
        logger.log(level: .info, "level info \(address)")
        logger.log(level: .error, "level error \(address)")
        logger.error("one private among public \(3) \(true) \(address, privacy: .private) \(4, privacy: .public)")
    }

    @Test(arguments: [OSLogPolicy.onlyWhileEnabled, OSLogPolicy.publicMessagesAlways])
    func aMessageWithAPrivateInterpolationNeverReachesTheSystemLogWhileOff(policy: OSLogPolicy) async throws {
        let (log, logger, system, directory) = make(policy, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        logEveryLevelWithAPrivateValue(logger)
        log.record(error: CocoaError(.fileNoSuchFile), category: "report", summary: "Failed")
        await log.flush()
        #expect(system.lines.isEmpty)
        #expect(try await log.logFiles().isEmpty)
    }

    @Test func aPublicMessageAlwaysReachesTheSystemLogAndNeverTheFileWhileOff() async throws {
        let (log, logger, system, directory) = make(.publicMessagesAlways, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.debug("debug")
        logger.info("info \(7)")
        logger.notice("notice \(2.5, format: .fixed(precision: 1)) \(true) \(Int.self)")
        logger.warning("warning \("held", privacy: .public)")
        logger.error("error")
        logger.fault("fault")
        await log.flush()
        #expect(system.lines == [
            .init(category: "sync", type: .debug, redacted: "debug", full: nil),
            .init(category: "sync", type: .info, redacted: "info 7", full: nil),
            .init(category: "sync", type: .default, redacted: "notice 2.5 true Swift.Int", full: nil),
            .init(category: "sync", type: .error, redacted: "warning held", full: nil),
            .init(category: "sync", type: .error, redacted: "error", full: nil),
            .init(category: "sync", type: .fault, redacted: "fault", full: nil),
        ])
        #expect(try await log.logFiles().isEmpty)
    }

    @Test func privateAndPublicMessagesAreToldApartPerMessage() async throws {
        let (log, logger, system, directory) = make(.publicMessagesAlways, isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.notice("public \(1)")
        logger.notice("private \("secret@example.com")")
        logger.notice("public again")
        await log.flush()
        #expect(system.lines.map(\.redacted) == ["public 1", "public again"])
    }

    @Test func turnedOnEveryLineReachesTheSystemLogInItsPrivateFormAndTheFile() async throws {
        let (log, logger, system, directory) = make(.publicMessagesAlways, isEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.notice("synced \(12) for \("secret@example.com")")
        logger.info("fine")
        await log.flush()
        #expect(system.lines == [
            .init(category: "sync", type: .default, redacted: "synced 12 for <private>", full: "synced 12 for secret@example.com"),
            .init(category: "sync", type: .info, redacted: "fine", full: nil),
        ])
        let file = try #require(try await log.logFiles().first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("notice [sync] synced 12 for <private>\n"))
        #expect(!text.contains("secret@example.com"))
    }

    @Test func turningTheLogOffAgainHidesPrivateMessagesAgain() async throws {
        let (log, logger, system, directory) = make(.publicMessagesAlways, isEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        log.setEnabled(false)
        logger.notice("private \("secret@example.com")")
        logger.notice("public")
        await log.flush()
        #expect(system.lines.map(\.redacted) == ["public"])
    }

    /// A message cannot be classified without being built: off, the policy builds it once and drops it when private.
    @Test func offTheMessageIsBuiltOnceAndOnlyWhereTheSystemCollectsTheLevel() {
        let (_, logger, system, directory) = make(.publicMessagesAlways, isEnabled: false, collected: [.default, .error, .fault])
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = Mutex(0)
        func message() -> DiagnosticMessage {
            built.withLock { $0 += 1 }
            return "built"
        }
        logger.debug(message())
        logger.info(message())
        #expect(built.withLock { $0 } == 0)
        logger.notice(message())
        logger.error(message())
        #expect(built.withLock { $0 } == 2)
        #expect(system.lines.count == 2)
    }

    @Test func theWritersOwnFailuresAreNeverPrivateSoTheyReachTheSystemLogWhileOff() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var configuration = DiagnosticLogTests.configuration
        configuration.osLog = .publicMessagesAlways
        let system = RecordingSystemLog()
        let log = DiagnosticLog(
            configuration: configuration, flushDelay: .milliseconds(10), isEnabled: false, systemLog: system)
        log.start(now: { Self.noon }) { file }
        await log.flush()
        #expect(system.lines.count == 1)
        #expect(system.lines[0].category == "diagnostics")
        #expect(system.lines[0].full == nil)
    }
}
