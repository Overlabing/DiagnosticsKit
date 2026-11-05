import Foundation

/// Why an archive was not written.
public enum DiagnosticArchiveError: Error, Equatable, Sendable {
    /// There is no log file to archive (and the caller required one).
    case noLogs
}

/// The zip a tester sends: a folder `<name>-diagnostics-<UTC stamp>/` holding `summary.txt` (`DiagnosticSummary`), the
/// log files and `environment.txt` (what the app says of itself: versions, system, no address). Zipped by the system
/// (`NSFileCoordinator`, `.forUploading`), no archive code of our own.
public enum DiagnosticArchive {
    public static let environmentFileName = "environment.txt"

    /// `App-diagnostics-20261028-211403` (UTC) for the name `App`.
    public static func folderName(now: Date, name: String) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .gmt, calendar: Calendar(identifier: .gregorian))
        return "\(name)-diagnostics-\(now.formatted(style))"
    }

    /// Writes the zip at `destination`, replacing a file already there only once the new zip is complete: the zip is
    /// read whole, then written atomically (a file the save panel chose: no sibling of ours to rename into place).
    /// `summaryAppendix` joins `summary.txt` after its story (`DiagnosticSummary.make`). With `requireLogs`, no log
    /// file throws `DiagnosticArchiveError.noLogs` before anything is written; without it, the zip then holds
    /// `environment.txt` and `summary.txt` alone.
    public static func write(
        logFiles: [URL], environment: String, summaryAppendix: String = "", requireLogs: Bool = false, to destination: URL,
        now: Date, configuration: DiagnosticsConfiguration
    ) throws {
        if requireLogs, logFiles.isEmpty { throw DiagnosticArchiveError.noLogs }
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appending(path: "\(configuration.fileNamePrefix)-diagnostics-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        let folder = staging.appending(path: folderName(now: now, name: configuration.archiveName), directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in logFiles {
            try manager.copyItem(at: file, to: folder.appending(path: file.lastPathComponent, directoryHint: .notDirectory))
        }
        let text = environment.hasSuffix("\n") ? environment : environment + "\n"
        try Data(text.utf8).write(to: folder.appending(path: environmentFileName, directoryHint: .notDirectory))
        // The story first: the last error and what led to it, from the two newest files.
        let newest = try logFiles.suffix(2).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        let summary = DiagnosticSummary.make(
            lines: newest.split(separator: "\n").map(String.init), appendix: summaryAppendix,
            conventions: configuration.summary)
        try Data(summary.utf8).write(to: folder.appending(path: DiagnosticSummary.fileName, directoryHint: .notDirectory))

        var coordinationError: NSError?
        var zipped: Result<Data, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            zipped = Result { try Data(contentsOf: zip) }
        }
        if let coordinationError { throw coordinationError }
        guard let zipped else { throw CocoaError(.fileWriteUnknown) }
        try zipped.get().write(to: destination, options: .atomic)
    }
}
