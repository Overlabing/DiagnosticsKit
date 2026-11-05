import Foundation

/// The files of the diagnostic log: one per UTC day, `<prefix>-YYYY-MM-DD.log`, one line per entry
/// (`<ISO 8601 UTC> <level> [<category>] <message>`, redacted by `DiagnosticRedactor`). Past `Limits.maxFileBytes`
/// the day's file becomes `<prefix>-YYYY-MM-DD.1.log` (replacing the previous one) and a new file starts. At launch,
/// `prune` keeps `Limits.keepDays` days and at most `Limits.maxTotalBytes` overall, oldest dropped first.
public struct DiagnosticLogFiles: Sendable {
    public struct Limits: Sendable, Equatable {
        public var keepDays: Int
        public var maxFileBytes: Int
        public var maxTotalBytes: Int

        public init(keepDays: Int = 7, maxFileBytes: Int = 5_000_000, maxTotalBytes: Int = 25_000_000) {
            self.keepDays = keepDays
            self.maxFileBytes = maxFileBytes
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public let directory: URL
    public let limits: Limits
    public let namePrefix: String

    /// Touches nothing: the folder is created by the first `append`. Only files named `<namePrefix>-…` are the log's.
    public init(directory: URL, limits: Limits = .init(), namePrefix: String) {
        self.directory = directory
        self.limits = limits
        self.namePrefix = namePrefix
    }

    // MARK: Lines

    /// One line, newline included; a multi-line message stays on one line (`\n` written as `\\n`).
    public static func line(for entry: DiagnosticEntry) -> String {
        let message = DiagnosticRedactor.redact(entry.message)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(entry.date.formatted(timestampStyle)) \(entry.level.rawValue) [\(entry.category)] \(message)\n"
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    private static let dayStyle = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()

    /// `app-2026-10-28.log` (`chunk` 1: `app-2026-10-28.1.log`) for the prefix `app`.
    public static func fileName(for date: Date, chunk: Int = 0, namePrefix: String) -> String {
        "\(namePrefix)-\(date.formatted(dayStyle))" + (chunk == 0 ? "" : ".\(chunk)") + ".log"
    }

    // MARK: Writing

    /// Appends the entries, in order, to their day's file; creates the folder if needed.
    func append(_ entries: [DiagnosticEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var day = ""
        var text = ""
        for entry in entries {
            let name = Self.fileName(for: entry.date, namePrefix: namePrefix)
            if name != day, !text.isEmpty {
                try append(Data(text.utf8), toFileNamed: day)
                text = ""
            }
            day = name
            text += Self.line(for: entry)
        }
        if !text.isEmpty { try append(Data(text.utf8), toFileNamed: day) }
    }

    private func append(_ data: Data, toFileNamed name: String) throws {
        let manager = FileManager.default
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        let path = url.path(percentEncoded: false)
        let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > limits.maxFileBytes {
            let previous = directory.appending(
                path: name.replacingOccurrences(of: ".log", with: ".1.log"), directoryHint: .notDirectory)
            if manager.fileExists(atPath: previous.path(percentEncoded: false)) { try manager.removeItem(at: previous) }
            try manager.moveItem(at: url, to: previous)
        }
        guard manager.fileExists(atPath: path) else {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: Pruning

    /// Removes the files older than `keepDays` days (today counts), then the oldest while over `maxTotalBytes`.
    func prune(now: Date) throws {
        let manager = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        guard let oldestKept = calendar.date(byAdding: .day, value: -(limits.keepDays - 1), to: today) else { return }
        var kept: [(file: LogFile, size: Int)] = []
        for file in try logFiles() {
            if file.day < oldestKept {
                try manager.removeItem(at: file.url)
            } else {
                let size = (try? manager.attributesOfItem(atPath: file.url.path(percentEncoded: false))[.size] as? Int) ?? 0
                kept.append((file, size))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for (file, size) in kept where total > limits.maxTotalBytes {
            try manager.removeItem(at: file.url)
            total -= size
        }
    }

    /// Empties the folder (every file in it, log or not); keeps the folder.
    func removeAll() throws {
        let manager = FileManager.default
        for name in try names() {
            try manager.removeItem(at: directory.appending(path: name))
        }
    }

    /// Total size of the log files, in bytes.
    func totalBytes() throws -> Int {
        try logFiles().reduce(0) { total, file in
            total + ((try? FileManager.default.attributesOfItem(atPath: file.url.path(percentEncoded: false))[.size] as? Int) ?? 0)
        }
    }

    /// Every log file, oldest first (by day, then a day's `.1` before its current file).
    public func allFiles() throws -> [URL] { try logFiles().map(\.url) }

    /// Whether there is at least one log file: what an export has to archive. False in a folder that does not exist yet.
    public func hasLogs() throws -> Bool { try !logFiles().isEmpty }

    struct LogFile {
        let url: URL
        let day: Date
        let chunk: Int
    }

    /// The folder's entries; none when it does not exist yet (nothing written). Any other failure is thrown.
    private func names() throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return []
        }
    }

    private func logFiles() throws -> [LogFile] {
        let head = namePrefix + "-"
        return try names().compactMap { name -> LogFile? in
            guard name.hasPrefix(head),
                let match = String(name.dropFirst(head.count)).wholeMatch(of: #/(\d{4}-\d{2}-\d{2})(?:\.(\d+))?\.log/#),
                let day = try? Date(String(match.1) + "T00:00:00Z", strategy: .iso8601)
            else { return nil }
            return LogFile(
                url: directory.appending(path: name, directoryHint: .notDirectory), day: day,
                chunk: match.2.flatMap { Int($0) } ?? 0)
        }
        .sorted { ($0.day, -$0.chunk) < ($1.day, -$1.chunk) }
    }
}
