import Foundation
import Synchronization
import Testing

@testable import DiagnosticsKit

/// Nothing to archive (`hasLogs`, `DiagnosticArchiveError.noLogs`) and typed events (`DiagnosticEventConvertible`).
struct NoLogsAndEventsTests {
    private static let noon = Date(timeIntervalSince1970: 1_793_188_800)

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "nologs-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: hasLogs

    @Test func filesHaveNoLogsInAFolderThatDoesNotExistYetOrIsEmpty() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = DiagnosticLogFiles(directory: directory, namePrefix: "app")
        #expect(try !files.hasLogs())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(try !files.hasLogs())
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "app-2026-10-28.log").path))
    }

    @Test func onlyFilesOfTheLogsShapeAreLogs() throws {
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = DiagnosticLogFiles(directory: directory, namePrefix: "app")
        for name in ["other-2026-10-27.log", "app-2026-10-27.txt", "app.log", "app-2026-10-27.log.bak"] {
            try Data("x\n".utf8).write(to: directory.appending(path: name))
        }
        #expect(try !files.hasLogs())
        try Data("x\n".utf8).write(to: directory.appending(path: "app-2026-10-27.log"))
        #expect(try files.hasLogs())
    }

    @Test func aLogHasLogsOnceSomethingIsWrittenAndNotAfterDeletingThem() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10))
        #expect(try await !log.hasLogs())
        log.start(now: { Self.noon }) { directory }
        #expect(try await !log.hasLogs())
        log.record(DiagnosticEntry(date: Self.noon, level: .notice, category: "test", message: "hello"))
        #expect(try await log.hasLogs())
        try await log.deleteAll()
        #expect(try await !log.hasLogs())
    }

    @Test func aDisabledLogHasNoLogs() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10), isEnabled: false)
        log.start(now: { Self.noon }) { directory }
        log.record(DiagnosticEntry(date: Self.noon, level: .notice, category: "test", message: "dropped"))
        #expect(try await !log.hasLogs())
    }

    // MARK: noLogs

    @Test func requiringLogsAnExportWithNothingToArchiveThrowsNoLogsAndWritesNothing() async throws {
        let directory = Self.temporaryDirectory()
        let output = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10), isEnabled: false)
        log.start(now: { Self.noon }) { directory }
        let zip = output.appending(path: "diagnostics.zip")
        try Data("stale".utf8).write(to: zip)
        await #expect(throws: DiagnosticArchiveError.noLogs) {
            try await log.export(environment: "App", requireLogs: true, to: zip, now: Self.noon)
        }
        #expect(try Data(contentsOf: zip) == Data("stale".utf8))
    }

    @Test func archivingNoFilesThrowsNoLogsWhenLogsAreRequired() {
        let destination = Self.temporaryDirectory().appending(path: "x.zip")
        #expect(throws: DiagnosticArchiveError.noLogs) {
            try DiagnosticArchive.write(
                logFiles: [], environment: "App", requireLogs: true, to: destination, now: Self.noon,
                configuration: DiagnosticLogTests.configuration)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    #if os(macOS)
    /// 0.1.0's behavior stays the default: with no log, the zip still carries `environment.txt` and `summary.txt`.
    @Test func byDefaultAnExportWithNoLogsStillZipsTheEnvironment() async throws {
        let directory = Self.temporaryDirectory()
        let output = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10), isEnabled: false)
        log.start(now: { Self.noon }) { directory }
        let zip = output.appending(path: "diagnostics.zip")
        try await log.export(environment: "App 1.0", to: zip, now: Self.noon)
        #expect(FileManager.default.fileExists(atPath: zip.path(percentEncoded: false)))
    }

    @Test func requiringLogsAnExportWithLogsStillWorks() async throws {
        let directory = Self.temporaryDirectory()
        let output = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10))
        log.start(now: { Self.noon }) { directory }
        log.record(DiagnosticEntry(date: Self.noon, level: .notice, category: "test", message: "export me"))
        let zip = output.appending(path: "diagnostics.zip")
        try await log.export(environment: "App 1.0", requireLogs: true, to: zip, now: Self.noon)
        #expect(FileManager.default.fileExists(atPath: zip.path(percentEncoded: false)))
    }
    #endif

    // MARK: Typed events

    private enum Sample: DiagnosticEventConvertible {
        case synced(count: Int, account: String)
        case failed(code: Int)

        var category: String {
            switch self {
            case .synced: "sync"
            case .failed: "report"
            }
        }

        var level: DiagnosticLevel {
            switch self {
            case .synced: .notice
            case .failed: .error
            }
        }

        var message: DiagnosticMessage {
            switch self {
            case .synced(let count, let account): "synced \(count) for \(account)"
            case .failed(let code): "failed \(code)"
            }
        }
    }

    private func make(
        isEnabled: Bool, policy: OSLogPolicy = .onlyWhileEnabled
    ) -> (log: DiagnosticLog, logger: DiagnosticLogger, system: RecordingSystemLog, directory: URL) {
        let directory = Self.temporaryDirectory()
        var configuration = DiagnosticLogTests.configuration
        configuration.osLog = policy
        let system = RecordingSystemLog()
        let log = DiagnosticLog(
            configuration: configuration, flushDelay: .milliseconds(10), isEnabled: isEnabled, systemLog: system)
        log.start(now: { Self.noon }) { directory }
        return (log, DiagnosticLogger(category: "app", sink: log), system, directory)
    }

    @Test func anEventIsRecordedUnderItsOwnCategoryAndLevelWithItsMessagesPrivacy() async throws {
        let (log, logger, system, directory) = make(isEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.record(Sample.synced(count: 3, account: "alice@exemple.fr"))
        logger.record(Sample.failed(code: 550))
        await log.flush()
        #expect(system.lines == [
            .init(category: "sync", type: .default, redacted: "synced 3 for <private>", full: "synced 3 for alice@exemple.fr"),
            .init(category: "report", type: .error, redacted: "failed 550", full: nil),
        ])
        let file = try #require(try await log.logFiles().first)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1)[1] }
        #expect(lines == ["notice [sync] synced 3 for <private>", "error [report] failed 550"])
    }

    @Test func anEventFollowsThePolicyOffWithoutBuildingItsMessage() async throws {
        let (log, logger, system, directory) = make(isEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        struct Counting: DiagnosticEventConvertible {
            let built: LockedCount
            var category: String { "sync" }
            var level: DiagnosticLevel { .error }
            var message: DiagnosticMessage {
                built.increment()
                return "built"
            }
        }
        let built = LockedCount()
        logger.record(Counting(built: built))
        await log.flush()
        #expect(built.value == 0)
        #expect(system.lines.isEmpty)
        #expect(try await !log.hasLogs())
    }

    @Test func anEventWithAPrivateValueStaysOutOfTheSystemLogWhileOffUnderThePublicMessagesPolicy() async throws {
        let (log, logger, system, directory) = make(isEnabled: false, policy: .publicMessagesAlways)
        defer { try? FileManager.default.removeItem(at: directory) }
        logger.record(Sample.synced(count: 3, account: "alice@exemple.fr"))
        logger.record(Sample.failed(code: 550))
        await log.flush()
        #expect(system.lines == [.init(category: "report", type: .error, redacted: "failed 550", full: nil)])
        #expect(try await !log.hasLogs())
    }
}

private final class LockedCount: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
