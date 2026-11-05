import Foundation

/// Where a diagnostic log's lines may go besides its own files: the system log (os_log).
public enum OSLogPolicy: Sendable, Equatable {
    /// Every line of level notice and above reaches the system log in its public form (private values read
    /// `<private>`, the full form is `privacy: .private`), whether the file log is on or off.
    case publicFieldsAlways
    /// Nothing reaches the system log while the file log is off, and the line is not even rendered. On, as
    /// `publicFieldsAlways`. The writer's own failures follow the same rule.
    case onlyWhileEnabled
    /// A message whose interpolations are all public always reaches the system log, whether the file log is on or off.
    /// A message with at least one private interpolation (`privacy: .private`, or none on a string or an object, which
    /// os_log treats as private) reaches it only while the log is on, as `publicFieldsAlways` does then. Derived from the
    /// message itself, with no annotation at the call site. A message cannot be classified without being built, so, off,
    /// every message at a level the system collects is built once and dropped when private. The writer's own failures
    /// are never private, so they follow the public messages.
    case publicMessagesAlways

    /// What the policy lets reach the system log, given whether the file log is on.
    enum Access: Equatable {
        case nothing
        case publicMessagesOnly
        case everything
    }

    func access(whileEnabled isEnabled: Bool) -> Access {
        switch self {
        case .publicFieldsAlways: .everything
        case .onlyWhileEnabled: isEnabled ? .everything : .nothing
        case .publicMessagesAlways: isEnabled ? .everything : .publicMessagesOnly
        }
    }
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
