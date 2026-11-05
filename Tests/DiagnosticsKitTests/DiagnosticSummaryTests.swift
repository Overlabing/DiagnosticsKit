import Foundation
import Testing

@testable import DiagnosticsKit

struct SummaryFailure: Error {
    let code: Int
    let reply: String
}

/// `summary.txt`: its first two lines tell the story, the breadcrumbs come in order with the error they precede.
struct DiagnosticSummaryTests {
    @Test func breadcrumbsAndTheErrorStayInOrderAndRedacted() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "summary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(configuration: DiagnosticLogTests.configuration, flushDelay: .milliseconds(10))
        log.start { directory }
        let ui = DiagnosticLogger(category: "ui", sink: log)
        ui.notice("list filter all opened")
        ui.notice("thread 1234 selected in filter all (3 messages, 1 unread)")
        ui.notice("compose reply to message 88")
        ui.notice("error shown in alert: SummaryFailure")
        log.record(
            error: SummaryFailure(code: 550, reply: "550 <bob@example.org> unknown"), category: "report",
            summary: "Envoi refusé")
        await log.flush()
        let lines = try await log.logFiles().flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
            .map(String.init)
        #expect(lines.map { DiagnosticSummary.category(of: $0) } == ["ui", "ui", "ui", "ui", "report"])
        #expect(lines[1].hasSuffix("notice [ui] thread 1234 selected in filter all (3 messages, 1 unread)"))
        #expect(lines[3].hasSuffix("notice [ui] error shown in alert: SummaryFailure"))
        #expect(lines[4].hasSuffix("error [report] Envoi refusé — DiagnosticsKitTests.SummaryFailure(code: 550)"))
        #expect(!lines.joined().contains("bob@"))

        let summary = DiagnosticSummary.make(lines: lines).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(summary[0].hasPrefix("Last error: 20"))
        #expect(summary[0].hasSuffix("Envoi refusé — DiagnosticsKitTests.SummaryFailure(code: 550)"))
        #expect(summary[1].hasPrefix("Before it: "))
        #expect(summary[1].contains(" list filter all opened → "))
        #expect(summary[1].contains(" thread 1234 selected in filter all (3 messages, 1 unread) → "))
        #expect(summary[1].hasSuffix(" compose reply to message 88"))
    }

    @Test func theConventionsNameTheCategoriesAndTheLaunchLine() {
        let lines = [
            "2026-10-28T11:59:58.000Z notice [boot] Started: App 0.1.0",
            "2026-10-28T12:00:00.000Z notice [nav] list opened",
            "2026-10-28T12:00:01.000Z notice [nav] error shown in banner: Timeout",
            "2026-10-28T12:00:01.100Z error [problem] Timeout — NSURLErrorDomain -1001",
        ]
        let conventions = DiagnosticSummary.Conventions(
            breadcrumbCategory: "nav", reportCategory: "problem", launchMarker: " [boot] Started: ")
        let summary = DiagnosticSummary.make(lines: lines, conventions: conventions).split(separator: "\n")
        #expect(summary[0] == "Last error: 2026-10-28 12:00:01 Timeout — NSURLErrorDomain -1001")
        #expect(summary[1] == "Before it: 11:59:58 Started: App 0.1.0 → 12:00:00 list opened")
        // With the defaults none of those lines is a breadcrumb or a launch.
        #expect(DiagnosticSummary.make(lines: lines).split(separator: "\n")[1] == "Before it: no interaction recorded")
    }

    @Test func summaryWithoutErrorSaysSo() {
        let lines = [
            "2026-10-28T11:59:58.000Z notice [app] Launch: App 0.1.0 (5), Version 26.1",
            "2026-10-28T11:59:59.000Z notice [sync] synced 12 messages",
            "2026-10-28T12:00:00.000Z notice [ui] list filter all opened",
        ]
        let summary = DiagnosticSummary.make(lines: lines).split(separator: "\n")
        #expect(summary[0] == "Last error: none")
        #expect(summary[1] == "Before it: 11:59:58 Launch: App 0.1.0 (5), Version 26.1 → 12:00:00 list filter all opened")
        #expect(!summary.contains { $0.contains("synced") })
    }

    /// The app's block between the story and the recent lines; nothing when empty.
    @Test func summaryAppendixFollowsTheStory() {
        let lines = ["2026-10-28T12:00:00.000Z notice [ui] list filter all opened"]
        let summary = DiagnosticSummary.make(lines: lines, appendix: "Shared accounts\nSharing: on\n")
        #expect(summary.hasPrefix(
            "Last error: none\nBefore it: 12:00:00 list filter all opened\n\nShared accounts\nSharing: on\n\n2026-10-28T12:00:00.000Z"))
        #expect(DiagnosticSummary.make(lines: lines, appendix: "\n") == DiagnosticSummary.make(lines: lines))
    }
}
