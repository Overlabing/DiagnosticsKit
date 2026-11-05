import Foundation

/// `summary.txt` of an export: its first two lines tell the story, « thread X selected in the inbox, then reply, then
/// error Y ». Line 1 is the last error shown, line 2 the breadcrumbs that led to it, oldest first; then every error and
/// breadcrumb of the last lines, as written.
public enum DiagnosticSummary {
    public static let fileName = "summary.txt"

    /// How the app's lines are recognised: its breadcrumbs (one line per user interaction), the error report written
    /// right after the breadcrumb of an error the user saw, and its launch line.
    public struct Conventions: Sendable, Equatable {
        public var breadcrumbCategory: String
        public var reportCategory: String
        /// A launch line contains this text, category included: ` [app] Launch: `.
        public var launchMarker: String

        public init(breadcrumbCategory: String = "ui", reportCategory: String = "report", launchMarker: String = " [app] Launch: ") {
            self.breadcrumbCategory = breadcrumbCategory
            self.reportCategory = reportCategory
            self.launchMarker = launchMarker
        }
    }

    /// Breadcrumbs kept before the last error on line 2.
    public static let trailLength = 8

    /// `lines`: log lines, oldest first (`DiagnosticLogFiles.line(for:)` format). `appendix`: a block the app adds after
    /// the story, before the recent lines; nothing when empty.
    public static func make(lines: [String], appendix: String = "", conventions: Conventions = .init()) -> String {
        let isBreadcrumb = { (line: String) in category(of: line) == conventions.breadcrumbCategory }
        let isLaunch = { (line: String) in line.contains(conventions.launchMarker) }
        let isErrorShown = { (line: String) in isBreadcrumb(line) && line.contains("] error shown in ") }
        // The last error the user saw (its `ui` breadcrumb), else the last error-level line.
        let shown = lines.lastIndex(where: isErrorShown)
        let anchor = shown ?? lines.lastIndex(where: isError)
        // The whole error (`report`, written right after the breadcrumb) reads better than its kind alone.
        let detail = shown.flatMap { index in
            lines[(index + 1)...].prefix(3).first { category(of: $0) == conventions.reportCategory }
        }
        let lastError = detail ?? anchor.map { lines[$0] }
        // A relaunch is part of the story: the app's launch line joins the breadcrumbs.
        let trail = lines[..<(anchor ?? lines.endIndex)].filter { isBreadcrumb($0) || isLaunch($0) }.suffix(trailLength)
        let errorText: String = lastError.map { message(of: $0) } ?? "none"
        let trailText: String = trail.isEmpty
            ? "no interaction recorded" : trail.map { message(of: $0, timeOnly: true) }.joined(separator: " → ")
        var text = "Last error: \(errorText)\nBefore it: \(trailText)\n\n"
        let block = appendix.trimmingCharacters(in: .newlines)
        if !block.isEmpty { text += block + "\n\n" }
        let recent = lines.filter { isBreadcrumb($0) || isLaunch($0) || isError($0) }.suffix(200)
        return text + recent.joined(separator: "\n") + (recent.isEmpty ? "" : "\n")
    }

    /// `2026-10-28T20:35:36.150Z error [report] …` → `report`.
    static func category(of line: String) -> String? {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    /// `2026-10-28 20:35:36 <message>` (UTC, to the second); `timeOnly`: `20:35:36 <message>`.
    static func message(of line: String, timeOnly: Bool = false) -> String {
        guard let close = line.firstIndex(of: "]") else { return line }
        let stamp = line.prefix { $0 != " " }.dropLast(5).replacingOccurrences(of: "T", with: " ")
        return "\(timeOnly ? String(stamp.suffix(8)) : stamp) "
            + line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    private static func isError(_ line: String) -> Bool {
        line.contains(" error [") || line.contains(" fault [")
    }
}
