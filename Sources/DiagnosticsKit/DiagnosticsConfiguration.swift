import Foundation

/// Where a diagnostic log's lines may go besides its own files: the system log (os_log).
public enum OSLogPolicy: Sendable, Equatable {
    /// Every line of level notice and above reaches the system log in its public form (private values read
    /// `<private>`, the full form is `privacy: .private`), whether the file log is on or off.
    case publicFieldsAlways
    /// Nothing reaches the system log while the file log is off, and the line is not even rendered. On, as
    /// `publicFieldsAlways`. The writer's own failures follow the same rule.
    case onlyWhileEnabled
}

/// Everything one app decides about its diagnostic log. The kit names no app: the subsystem, the file names and the
/// archive's name come from here.
public struct DiagnosticsConfiguration: Sendable, Equatable {
    /// The os_log subsystem, usually the bundle identifier. Also names the writer's queue (`<subsystem>.diagnostics`).
    public var subsystem: String
    /// The log files are `<fileNamePrefix>-YYYY-MM-DD.log`. Only files of this shape are pruned and exported.
    public var fileNamePrefix: String
    /// The exported folder is `<archiveName>-diagnostics-<UTC stamp>/`.
    public var archiveName: String
    public var limits: DiagnosticLogFiles.Limits
    public var osLog: OSLogPolicy
    /// How `summary.txt` recognizes the lines it tells the story with.
    public var summary: DiagnosticSummary.Conventions

    public init(
        subsystem: String, fileNamePrefix: String, archiveName: String, limits: DiagnosticLogFiles.Limits = .init(),
        osLog: OSLogPolicy = .onlyWhileEnabled, summary: DiagnosticSummary.Conventions = .init()
    ) {
        self.subsystem = subsystem
        self.fileNamePrefix = fileNamePrefix
        self.archiveName = archiveName
        self.limits = limits
        self.osLog = osLog
        self.summary = summary
    }
}
