import Foundation
import Synchronization
import Testing

@testable import DiagnosticsKit

enum DiagnosticTestError: Error {
    case server(code: Int, message: String)
    case network(retryable: Bool, underlying: any Error)
    case rejected(String)
    case cancelled
}

struct DiagnosticTestFailure: Error {
    let status: Int
    let reply: String
}

/// The local diagnostic log: messages, lines, redaction, rotation, pruning, ordering, writer thread, zip.
struct DiagnosticLogTests {
    private static let noon = Date(timeIntervalSince1970: 1_793_188_800)  // 2026-10-28T12:00:00Z

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "diagnostic-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static let configuration = DiagnosticsConfiguration(
        subsystem: "com.example.app", fileNamePrefix: "app", archiveName: "App", osLog: .publicFieldsAlways)

    private static func entry(_ message: String, level: DiagnosticLevel = .notice, at date: Date = noon) -> DiagnosticEntry {
        DiagnosticEntry(date: date, level: level, category: "test", message: message)
    }

    private static func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// A log started on its own folder, with the writer done starting.
    private static func startedLog(
        limits: DiagnosticLogFiles.Limits = .init(), now: Date = noon
    ) async throws -> (DiagnosticLog, URL) {
        let directory = temporaryDirectory()
        var configuration = Self.configuration
        configuration.limits = limits
        let log = DiagnosticLog(configuration: configuration, flushDelay: .milliseconds(10))
        log.start(now: { now }) { directory }
        await log.flush()
        return (log, directory)
    }

    // MARK: Messages

    @Test func privateValuesNeverReachTheClearForm() {
        let address = "alice@example.com"
        let count = 3
        let message: DiagnosticMessage =
            "sent \(count) to \(address) via \("smtp", privacy: .public) as \(address, privacy: .private) in \(0.1234, format: .fixed(precision: 2)) s, ok \(true)"
        #expect(message.redacted == "sent 3 to <private> via smtp as <private> in 0.12 s, ok true")
        #expect(message.full == "sent 3 to alice@example.com via smtp as alice@example.com in 0.12 s, ok true")
        #expect(message.hasPrivate)
        let plain: DiagnosticMessage = "launch \(42) \(String.self)"
        #expect(plain.redacted == "launch 42 Swift.String")
        #expect(!plain.hasPrivate)
    }

    @Test func loggerMirrorsNoticeAndAboveOnly() async throws {
        let (log, directory) = try await Self.startedLog()
        let logger = DiagnosticLogger(category: "sync", sink: log)
        logger.debug("debug line")
        logger.info("info line")
        logger.notice("synced \(12) messages for \("someone@example.com")")
        logger.error("failed \("IMAP", privacy: .public)")
        await log.flush()
        let text = try await log.logFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(text.contains("notice [sync] synced 12 messages for <private>"))
        #expect(text.contains("error [sync] failed IMAP"))
        #expect(!text.contains("debug line"))
        #expect(!text.contains("info line"))
        #expect(!text.contains("someone"))
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Lines and redaction

    @Test func lineCarriesTimestampLevelCategoryAndOneLineMessage() {
        let line = DiagnosticLogFiles.line(for: Self.entry("first\nsecond", level: .error))
        #expect(line == "2026-10-28T12:00:00.000Z error [test] first\\nsecond\n")
        #expect(DiagnosticLogFiles.fileName(for: Self.noon, namePrefix: "app") == "app-2026-10-28.log")
        #expect(DiagnosticLogFiles.fileName(for: Self.noon, chunk: 1, namePrefix: "app") == "app-2026-10-28.1.log")
    }

    @Test(arguments: [
        ("rejected <alice.smith+news@mail.example.co.uk>", "rejected <<address>>"),
        ("Authorization: Bearer ya29.a0AfH6SMBx-token_value", "Authorization: Bearer <secret>"),
        ("header Basic dXNlcjpwYXNzd29yZA==", "header Basic <secret>"),
        ("C: AUTHENTICATE XOAUTH2 dXNlcj1hbGljZQFhdXRo", "C: AUTHENTICATE XOAUTH2 <secret>"),
        ("AUTH PLAIN AGFsaWNlAHNlY3JldA==", "AUTH PLAIN <secret>"),
        (#"{"access_token": "ya29.abc", "expires_in": 3599}"#, #"{"access_token": "<secret>", "expires_in": 3599}"#),
        ("refresh_token=1//0abc&grant_type=refresh_token", "refresh_token=<secret>&grant_type=refresh_token"),
        ("GET /callback?code=4/0AbCdEf&scope=mail", "GET /callback?<query>"),
        ("POST code=4/0AbCdEf&scope=mail", "POST code=<secret>&scope=mail"),
        (
            "GET https://api.example.com/v1/accounts/me/messages?q=from%3Aalice%40example.com%20facture&maxResults=50 failed",
            "GET https://api.example.com/v1/accounts/me/messages?<query> failed"
        ),
        ("PUT /users/alice.smith%40example.com/settings", "PUT /users/<address>/settings"),
        ("Authorization: Bearer ya29.A0ARrdaM-abc_def123", "Authorization: Bearer <secret>"),
        ("payload eyJhbGciOiJSUzI1NiIsImtpZCI6IjEifQ end", "payload <blob> end"),
        ("data: AGFsaWNlAHNlY3JldHBhc3N3b3JkMTIz==", "data: <blob>"),
        ("accessGroupMigrationIncompleteAgain stays", "accessGroupMigrationIncompleteAgain stays"),
        (
            #"Error Domain=NSURLErrorDomain Code=-1001 UserInfo={NSErrorFailingURLStringKey=https://imap.example.com/x?user=alice}"#,
            #"Error Domain=NSURLErrorDomain Code=-1001 UserInfo={NSErrorFailingURLStringKey=https://imap.example.com/x?<query>"#
        ),
        (#"server(code: 500, message: "Backend Error")"#, #"server(code: 500, message: "Backend Error")"#),
        ("password: hunter2 rejected", "password: <secret> rejected"),
        (#"auth(message: \"password=hunter2\")"#, #"auth(message: \"password=<secret>\")"#),
        ("synced 12 messages in INBOX", "synced 12 messages in INBOX"),
    ])
    func redactsAddressesAndSecrets(input: String, expected: String) {
        #expect(DiagnosticRedactor.redact(input) == expected)
    }

    @Test func reportedErrorKeepsItsKindAndCodesOnly() async throws {
        let (log, directory) = try await Self.startedLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        log.record(
            error: DiagnosticTestError.server(code: 550, message: "550 <bob@example.org> unknown, token=abc123"),
            category: "report", summary: "L'action n'a pas abouti", date: Self.noon)
        let failingURL = "https://api.example.com/v1/accounts/me/messages?q=facture%20orange"
        log.record(
            error: URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: failingURL]), category: "report",
            summary: "Délai dépassé", date: Self.noon)
        await log.flush()
        let text = try String(contentsOf: directory.appending(path: "app-2026-10-28.log"), encoding: .utf8)
        #expect(text.contains("error [report] L'action n'a pas abouti — DiagnosticsKitTests.DiagnosticTestError.server(code: 550)\n"))
        #expect(text.contains("error [report] Délai dépassé — NSURLErrorDomain -1001\n"))
        for leak in ["bob", "abc123", "unknown", "facture", "api.example"] {
            #expect(!text.contains(leak), "\(leak)")
        }
    }

    @Test func safeDescriptionNamesKindsAndNumbersNeverText() {
        let underlying = NSError(
            domain: "NSPOSIXErrorDomain", code: 61, userInfo: [NSLocalizedDescriptionKey: "alice@example.com refused"])
        let wrapped = NSError(
            domain: "AppCore.StoreError", code: 4,
            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "INBOX/Factures"])
        let cases: [(any Error, String)] = [
            (DiagnosticTestError.server(code: 500, message: "Backend Error for INBOX/Factures"),
             "DiagnosticsKitTests.DiagnosticTestError.server(code: 500)"),
            (DiagnosticTestError.network(retryable: true, underlying: URLError(.notConnectedToInternet)),
             "DiagnosticsKitTests.DiagnosticTestError.network(retryable: true, underlying: NSURLErrorDomain -1009)"),
            (DiagnosticTestError.rejected("bob%40example.org"), "DiagnosticsKitTests.DiagnosticTestError.rejected"),
            (DiagnosticTestError.cancelled, "DiagnosticsKitTests.DiagnosticTestError.cancelled"),
            (wrapped, "AppCore.StoreError 4 (underlying: NSPOSIXErrorDomain 61)"),
            (DiagnosticTestFailure(status: 535, reply: "5.7.8 alice@example.com"), "DiagnosticsKitTests.DiagnosticTestFailure(status: 535)"),
        ]
        for (error, expected) in cases {
            #expect(ErrorLog.safeDescription(of: error) == expected)
        }
    }

    // MARK: Files

    @Test func dayFileRollsOverPastItsSizeLimit() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = DiagnosticLogFiles(directory: directory, limits: .init(maxFileBytes: 300), namePrefix: "app")
        let batch = (0..<4).map { Self.entry("line \($0) " + String(repeating: "x", count: 40)) }
        try files.append(batch)  // ~ 4 × 80 bytes: past 300 only on the next batch
        try files.append([Self.entry("after rollover")])
        try files.append([Self.entry("again")])
        let names = try files.allFiles().map(\.lastPathComponent)
        #expect(names == ["app-2026-10-28.1.log", "app-2026-10-28.log"])
        #expect(try Self.lines(of: files.allFiles()[0]).count == 4)
        #expect(try Self.lines(of: files.allFiles()[1]).map { $0.components(separatedBy: "] ").last } == ["after rollover", "again"])
    }

    @Test func entriesAcrossMidnightGoToTheirDay() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = DiagnosticLogFiles(directory: directory, namePrefix: "app")
        let midnight = Self.noon.addingTimeInterval(12 * 3600)
        try files.append([Self.entry("before", at: midnight - 1), Self.entry("after", at: midnight)])
        #expect(try files.allFiles().map(\.lastPathComponent) == ["app-2026-10-28.log", "app-2026-10-29.log"])
    }

    @Test func pruneKeepsSevenDaysThenTheTotalBudget() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = [
            "app-2026-10-20.log", "app-2026-10-21.log", "app-2026-10-22.1.log", "app-2026-10-22.log",
            "app-2026-10-27.log", "app-2026-10-28.log", "notes.txt",
        ]
        for name in names {
            try Data(repeating: 0x61, count: 100).write(to: directory.appending(path: name))
        }
        let files = DiagnosticLogFiles(directory: directory, limits: .init(keepDays: 7, maxTotalBytes: 300), namePrefix: "app")
        try files.prune(now: Self.noon)
        // 20 and 21 are older than seven days; then over 300 bytes, the oldest (22's `.1`) goes.
        #expect(try files.allFiles().map(\.lastPathComponent) == [
            "app-2026-10-22.log", "app-2026-10-27.log", "app-2026-10-28.log",
        ])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "notes.txt").path(percentEncoded: false)))
    }

    // MARK: Writer

    @Test func entriesRecordedBeforeStartAreWrittenInOrder() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(configuration: Self.configuration, flushDelay: .milliseconds(10))
        for index in 0..<200 { log.record(Self.entry("early \(index)")) }
        #expect(try await log.logFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        log.start(now: { Self.noon }) { directory }
        for index in 0..<300 { log.record(Self.entry("late \(index)")) }
        await log.flush()
        let messages = try Self.lines(of: directory.appending(path: "app-2026-10-28.log"))
            .map { $0.components(separatedBy: "] ").last ?? "" }
        #expect(messages == (0..<200).map { "early \($0)" } + (0..<300).map { "late \($0)" })
    }

    @Test func concurrentRecordersKeepTheirOwnOrder() async throws {
        let (log, directory) = try await Self.startedLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for index in 0..<100 { log.record(Self.entry("w\(writer) \(index)")) }
                }
            }
        }
        await log.flush()
        let messages = try Self.lines(of: directory.appending(path: "app-2026-10-28.log"))
            .map { $0.components(separatedBy: "] ").last ?? "" }
        #expect(messages.count == 800)
        for writer in 0..<8 {
            let own = messages.filter { $0.hasPrefix("w\(writer) ") }
            #expect(own == (0..<100).map { "w\(writer) \($0)" })
        }
    }

    @MainActor @Test func recordingFromTheMainActorNeverWritesOnIt() async throws {
        let (log, directory) = try await Self.startedLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<50 { log.record(Self.entry("main \(index)", level: index % 10 == 0 ? .error : .notice)) }
        await log.flush()
        log.flushBeforeExit()
        let stats = log.stats
        #expect(stats.batches > 0)
        #expect(stats.batchesOnMainThread == 0)
        #expect(try Self.lines(of: directory.appending(path: "app-2026-10-28.log")).count == 50)
    }

    @Test func pendingBufferIsBounded() async {
        let log = DiagnosticLog(configuration: Self.configuration)
        for index in 0..<(DiagnosticLog.pendingLimit + 10) { log.record(Self.entry("\(index)")) }
        #expect(log.stats.dropped == 10)
    }

    // MARK: Export

    // These read the archive back with `/usr/bin/unzip`: iOS has no `Process`, and no unzip API to do it otherwise.
    #if os(macOS)
    @Test func exportZipsTheLogsAndTheEnvironment() async throws {
        let (log, directory) = try await Self.startedLog()
        let output = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("2026-10-27T09:00:00.000Z notice [app] yesterday\n".utf8)
            .write(to: directory.appending(path: "app-2026-10-27.log"))
        log.record(Self.entry("export me"))
        let zip = output.appending(path: "diagnostics.zip")
        try Data("stale".utf8).write(to: zip)
        try await log.export(
            environment: "App 1.0 (5)\nAccounts: 1\n- primary: idle",
            summaryAppendix: "Shared accounts\nSharing: off", to: zip, now: Self.noon)

        let folder = "App-diagnostics-20261028-120000"
        #expect(DiagnosticArchive.folderName(now: Self.noon, name: "App") == folder)
        let listing = try Self.unzip(["-Z1", zip.path(percentEncoded: false)])
        #expect(Set(listing.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }) == [
            "\(folder)/app-2026-10-27.log", "\(folder)/app-2026-10-28.log", "\(folder)/environment.txt",
            "\(folder)/summary.txt",
        ])
        let environment = try Self.unzip(["-p", zip.path(percentEncoded: false), "\(folder)/environment.txt"])
        #expect(environment == "App 1.0 (5)\nAccounts: 1\n- primary: idle\n")
        let today = try Self.unzip(["-p", zip.path(percentEncoded: false), "\(folder)/app-2026-10-28.log"])
        #expect(today.hasSuffix("notice [test] export me\n"))
        // The appendix block comes right after the story.
        let summary = try Self.unzip(["-p", zip.path(percentEncoded: false), "\(folder)/summary.txt"])
        #expect(summary.contains("Before it: no interaction recorded\n\nShared accounts\nSharing: off\n\n"))
    }
    #endif

    // MARK: Opt-in

    @Test func disabledLogWritesNothing() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(configuration: Self.configuration, flushDelay: .milliseconds(10), isEnabled: false)
        log.start(now: { Self.noon }) { directory }
        let logger = DiagnosticLogger(category: "sync", sink: log)
        logger.notice("synced \(12) messages")
        logger.error("failed")
        log.record(error: CocoaError(.fileNoSuchFile), category: "report", summary: "Erreur")
        #expect(log.stats.dropped == 0)
        await log.flush()
        log.flushBeforeExit()
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(try await log.logFiles().isEmpty)
        #expect(try await log.totalBytes() == 0)
        #expect(log.stats.batches == 0)
    }

    @Test func oldFilesArePrunedEvenWhenOff() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: directory.appending(path: "app-2026-10-01.log"))
        try Data("recent\n".utf8).write(to: directory.appending(path: "app-2026-10-27.log"))
        let log = DiagnosticLog(configuration: Self.configuration, flushDelay: .milliseconds(10), isEnabled: false)
        log.start(now: { Self.noon }) { directory }
        log.record(Self.entry("dropped"))
        await log.flush()
        #expect(try await log.logFiles().map(\.lastPathComponent) == ["app-2026-10-27.log"])
    }

    @Test func disablingKeepsTheFilesAndStopsWriting() async throws {
        let (log, directory) = try await Self.startedLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        log.record(Self.entry("kept"))
        await log.flush()
        let size = try await log.totalBytes()
        #expect(size > 0)
        log.setEnabled(false)
        log.record(Self.entry("dropped"))
        await log.flush()
        #expect(try await log.totalBytes() == size)
        let text = try String(contentsOf: directory.appending(path: "app-2026-10-28.log"), encoding: .utf8)
        #expect(text.contains("kept") && !text.contains("dropped"))
    }

    @Test func deleteAllEmptiesTheFolder() async throws {
        let (log, directory) = try await Self.startedLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sizes = Mutex<[Int]>([])
        log.observeSize { size in sizes.withLock { $0.append(size) } }
        log.record(Self.entry("one"))
        await log.flush()
        try Data("other".utf8).write(to: directory.appending(path: "notes.txt"))
        #expect(try await log.totalBytes() > 0)
        try await log.deleteAll()
        #expect(try await log.logFiles().isEmpty)
        #expect(try await log.totalBytes() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
        #expect(sizes.withLock { $0.last } == 0)
        #expect(sizes.withLock { $0.contains { $0 > 0 } })
    }

    #if os(macOS)
    @Test func exportAfterDeletingThenReenabling() async throws {
        let (log, directory) = try await Self.startedLog()
        let output = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: output)
        }
        log.record(Self.entry("before deletion"))
        await log.flush()
        log.setEnabled(false)
        log.record(Self.entry("while off"))
        try await log.deleteAll()
        log.setEnabled(true)
        log.record(Self.entry("after reenabling"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let zip = output.appending(path: "diagnostics.zip")
        try await log.export(environment: "App", to: zip, now: Self.noon)
        let folder = DiagnosticArchive.folderName(now: Self.noon, name: "App")
        let listing = try Self.unzip(["-Z1", zip.path(percentEncoded: false)])
        #expect(listing.contains("\(folder)/app-2026-10-28.log"))
        #expect(listing.contains("\(folder)/summary.txt"))
        let today = try Self.unzip(["-p", zip.path(percentEncoded: false), "\(folder)/app-2026-10-28.log"])
        #expect(today.split(separator: "\n").map { $0.components(separatedBy: "] ").last } == ["after reenabling"])
    }

    private static func unzip(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    #endif

    // MARK: Perf

    /// What a call site pays for a notice line: render both forms, os_log, enqueue. The file is written elsewhere.
    @Test func noticeCostAtTheCallSite() {
        let log = DiagnosticLog(configuration: Self.configuration)
        let logger = DiagnosticLogger(category: "perf", sink: log)
        let account = "account-id"
        let timing = PerfBudget.measure(5) {
            for index in 0..<1_000 {
                logger.notice("synced \(index) messages for \(account) in \("INBOX", privacy: .public)")
            }
        }
        PerfBudget.expect("1 000 notices (render, os_log, queue)", timing, budget: .milliseconds(20))
    }

    /// What the writer queue pays per batch: format, redact and append 1 000 lines.
    @Test func writerCostPerThousandLines() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = DiagnosticLogFiles(directory: directory, namePrefix: "app")
        let entries = (0..<1_000).map {
            Self.entry($0 % 50 == 0 ? "rejected <bob@example.org> token=abc \($0)" : "synced \($0) messages in INBOX")
        }
        let timing = try PerfBudget.measure(5) { try files.append(entries) }
        PerfBudget.expect("writing 1 000 lines (format, redaction, append)", timing, budget: .milliseconds(15))
    }
}

/// What goes out in clear in the log carries no address and no server text.
@Suite("Error log")
struct ErrorLogTests {
    enum Sample: Error {
        case recipientRejected(address: String, code: Int, message: String)
        case interrupted
    }

    @Test("Type and case in clear, never the address nor the server text")
    func publicKindHasNoValues() {
        let kind = ErrorLog.kind(of: Sample.recipientRejected(address: "alice@exemple.fr", code: 550, message: "unknown user alice"))
        #expect(kind.hasSuffix("Sample.recipientRejected"))
        #expect(!kind.contains("alice") && !kind.contains("550"))
        #expect(ErrorLog.kind(of: Sample.interrupted).hasSuffix("Sample.interrupted"))
        let ns = NSError(domain: "UNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "alice@exemple.fr"])
        #expect(ErrorLog.kind(of: ns) == "UNErrorDomain 1")
    }
}
