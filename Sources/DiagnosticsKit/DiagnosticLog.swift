import Dispatch
import Foundation
import Synchronization
import os

/// One line of the diagnostic log, captured at the call site; formatted and redacted on the writer queue.
public struct DiagnosticEntry: Sendable, Equatable {
    public let date: Date
    public let level: DiagnosticLevel
    public let category: String
    /// The clear form of the message: private values are already `<private>`.
    public let message: String

    public init(date: Date, level: DiagnosticLevel, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// The local diagnostic log: lines of level notice and above from every `DiagnosticLogger`, plus every error the app
/// shows (`record(error:category:summary:)`), appended to rotating files that the user can export as a zip.
///
/// Opt-in: disabled, an entry is dropped at once, nothing is buffered and no file or folder is created; disabling keeps
/// the files already written (`deleteAll` removes them). The configuration's `OSLogPolicy` decides whether the
/// loggers on this log reach the system log while it is disabled.
///
/// Recording never blocks: the entry joins a buffer under a lock and a serial utility queue writes the buffer in
/// batches (after `flushDelay`, at once for an error). Before `start`, entries wait in the buffer (bounded) so the
/// launch is not lost; until then nothing touches the disk.
public final class DiagnosticLog: Sendable {
    /// Entries kept while the log is not started or the writer is behind; the oldest are dropped beyond.
    public static let pendingLimit = 5_000

    struct Stats: Sendable, Equatable {
        var batches = 0
        var batchesOnMainThread = 0
        var dropped = 0
    }

    private struct Start: Sendable {
        let now: @Sendable () -> Date
        let directory: @Sendable () throws -> URL
    }

    private struct State: Sendable {
        var isEnabled: Bool
        var pending: [DiagnosticEntry] = []
        var started: Start?
        /// Resolved on the writer queue at the first need; nil before `start` or when the folder could not be resolved.
        var files: DiagnosticLogFiles?
        var flushScheduled = false
        var sizeObserver: (@Sendable (Int) -> Void)?
        var stats = Stats()
    }

    public let configuration: DiagnosticsConfiguration
    let systemLog: any SystemLog
    private let state: Mutex<State>
    private let queue: DispatchQueue
    private let flushDelay: DispatchTimeInterval
    /// The writer's own failures: os_log only, never back into this log, and only where the policy lets a line out.
    private let ownChannel: any SystemLogChannel

    public convenience init(
        configuration: DiagnosticsConfiguration, flushDelay: DispatchTimeInterval = .seconds(1), isEnabled: Bool = true
    ) {
        self.init(
            configuration: configuration, flushDelay: flushDelay, isEnabled: isEnabled,
            systemLog: OSLogSystemLog(subsystem: configuration.subsystem))
    }

    init(
        configuration: DiagnosticsConfiguration, flushDelay: DispatchTimeInterval, isEnabled: Bool,
        systemLog: any SystemLog
    ) {
        self.configuration = configuration
        self.flushDelay = flushDelay
        self.systemLog = systemLog
        ownChannel = systemLog.channel(category: "diagnostics")
        queue = DispatchQueue(label: "\(configuration.subsystem).diagnostics", qos: .utility)
        state = Mutex(State(isEnabled: isEnabled))
    }

    /// Where to write, `directory()` resolved on the writer queue (the app resolves Application Support there, never
    /// on the main thread). Prunes the old files, enabled or not (it creates nothing), then, enabled, writes what was
    /// recorded before; the folder itself is created by the first write.
    public func start(
        now: @escaping @Sendable () -> Date = Date.init, directory: @escaping @Sendable () throws -> URL
    ) {
        state.withLock { $0.started = Start(now: now, directory: directory) }
        queue.async { [self] in
            do {
                try resolvedFiles()?.prune(now: now())
            } catch {
                logOwnFailure("Diagnostic log not pruned", error)
            }
            drain()
        }
    }

    public var isEnabled: Bool { state.withLock { $0.isEnabled } }

    /// Whether the loggers on this log may write to the system log right now (see `OSLogPolicy`).
    var writesToSystemLog: Bool {
        switch configuration.osLog {
        case .publicFieldsAlways: true
        case .onlyWhileEnabled: isEnabled
        }
    }

    /// Turns recording on or off. Off: what waits is dropped and nothing more is written; the files stay.
    public func setEnabled(_ enabled: Bool) {
        state.withLock { state in
            state.isEnabled = enabled
            if !enabled { state.pending.removeAll() }
        }
    }

    /// Called on the writer queue with the logs' total size after each write, deletion or export.
    public func observeSize(_ observer: @escaping @Sendable (Int) -> Void) {
        state.withLock { $0.sizeObserver = observer }
        queue.async { [self] in reportSize() }
    }

    public func record(_ entry: DiagnosticEntry) {
        let schedule: DispatchTimeInterval? = state.withLock { state in
            guard state.isEnabled else { return nil }
            if state.pending.count >= Self.pendingLimit {
                state.pending.removeFirst(state.pending.count - Self.pendingLimit + 1)
                state.stats.dropped += 1
            }
            state.pending.append(entry)
            guard state.started != nil else { return nil }
            if entry.level >= .error { return .never }
            guard !state.flushScheduled else { return nil }
            state.flushScheduled = true
            return flushDelay
        }
        switch schedule {
        case nil: break
        case .never?: queue.async { [self] in drain() }
        case let delay?: queue.asyncAfter(deadline: .now() + delay) { [self] in drain() }
        }
    }

    /// An error the user sees: its summary (a fixed title) and `ErrorLog.safeDescription`, kind and numeric codes
    /// only, never `String(reflecting:)` (server replies, URLs, addresses). Nothing is built when off.
    public func record(error: any Error, category: String, summary: String, date: Date = Date()) {
        guard isEnabled else { return }
        let message = "\(summary) — \(ErrorLog.safeDescription(of: error))"
        record(DiagnosticEntry(date: date, level: .error, category: category, message: message))
    }

    /// Writes everything recorded so far.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                drain()
                continuation.resume()
            }
        }
    }

    /// At quit, from the main thread: the write still runs on the writer queue, waited for at most `timeout`.
    public func flushBeforeExit(timeout: DispatchTimeInterval = .milliseconds(500)) {
        let group = DispatchGroup()
        queue.async(group: group) { [self] in drain() }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Writes the zip the user sends: every log file and `environment.txt`, after a flush, off the caller's thread.
    /// `summaryAppendix` joins `summary.txt` (`DiagnosticArchive.write`).
    public func export(
        environment: String, summaryAppendix: String = "", to destination: URL, now: Date = Date()
    ) async throws {
        try await onQueue { [self] in
            drain()
            try DiagnosticArchive.write(
                logFiles: resolvedFiles()?.allFiles() ?? [], environment: environment, summaryAppendix: summaryAppendix,
                to: destination, now: now, configuration: configuration)
            reportSize()
        }
    }

    /// Empties the log folder: what waits is dropped too, then the size is reported (0).
    public func deleteAll() async throws {
        try await onQueue { [self] in
            state.withLock { $0.pending.removeAll() }
            defer { reportSize() }
            try resolvedFiles()?.removeAll()
        }
    }

    /// Total size of the log files, in bytes (0 without a folder).
    public func totalBytes() async throws -> Int {
        try await onQueue { [self] in try resolvedFiles()?.totalBytes() ?? 0 }
    }

    /// The log files, oldest first (empty before `start` or without a folder).
    public func logFiles() async throws -> [URL] {
        try await onQueue { [self] in try resolvedFiles()?.allFiles() ?? [] }
    }

    var stats: Stats { state.withLock { $0.stats } }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// On the writer queue only: the files of the configured folder, resolved once, without creating it.
    private func resolvedFiles() -> DiagnosticLogFiles? {
        let (files, started) = state.withLock { ($0.files, $0.started) }
        if let files { return files }
        guard let started else { return nil }
        do {
            let files = DiagnosticLogFiles(
                directory: try started.directory(), limits: configuration.limits, namePrefix: configuration.fileNamePrefix)
            state.withLock { $0.files = files }
            return files
        } catch {
            logOwnFailure("Diagnostic log folder not resolved", error)
            return nil
        }
    }

    /// A failure of the writer itself: said in os_log when the policy lets a line out, never in the file.
    private func logOwnFailure(_ what: String, _ error: any Error) {
        guard writesToSystemLog else { return }
        ownChannel.write(.error, redacted: "\(what): \(ErrorLog.safeDescription(of: error))", full: nil)
    }

    /// On the writer queue only. A folder that cannot be read is said in os_log; the size then reads 0.
    private func reportSize() {
        guard let observer = state.withLock({ $0.sizeObserver }) else { return }
        do {
            observer(try resolvedFiles()?.totalBytes() ?? 0)
        } catch {
            logOwnFailure("Diagnostic log size not read", error)
            observer(0)
        }
    }

    /// On the writer queue only.
    private func drain() {
        let ready = state.withLock { state in
            state.flushScheduled = false
            return state.isEnabled && !state.pending.isEmpty
        }
        guard ready, let files = resolvedFiles() else { return }
        let batch: [DiagnosticEntry] = state.withLock { state in
            guard state.isEnabled, !state.pending.isEmpty else { return [] }
            defer { state.pending.removeAll(keepingCapacity: true) }
            state.stats.batches += 1
            if pthread_main_np() != 0 { state.stats.batchesOnMainThread += 1 }
            return state.pending
        }
        guard !batch.isEmpty else { return }
        do {
            try files.append(batch)
        } catch {
            logOwnFailure("Diagnostic log not written", error)
        }
        reportSize()
    }
}
