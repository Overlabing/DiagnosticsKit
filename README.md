# DiagnosticsKit

An opt-in local diagnostic log for Overlabing's Mac and iOS apps: rotating files a user can export as a zip, a drop-in
for `os.Logger` that feeds them, redaction of what must never reach a file, and the story that opens an export. A Swift
package for macOS 26 and iOS 26, Swift 6 with strict concurrency. Its one dependency is
[AppSupportKit](https://github.com/Overlabing/AppSupportKit) (for the switch's storage). MIT licensed.

The kit never names an app. The os_log subsystem, the file names, the archive's name, the limits and the system log
policy are passed in as a `DiagnosticsConfiguration`.

| Type | What it is |
|---|---|
| `DiagnosticsConfiguration` | The app's choices: `subsystem`, `fileNamePrefix` (files are `<prefix>-YYYY-MM-DD.log`), `archiveName`, `limits`, `osLog`, `summary` |
| `DiagnosticLog` | The log: `record(_:)`, `record(error:category:summary:)`, `setEnabled(_:)`, `start(directory:)`, `flush()`, `flushBeforeExit(timeout:)`, `export(environment:summaryAppendix:requireLogs:to:)`, `hasLogs()`, `deleteAll()`, `totalBytes()`, `observeSize(_:)` |
| `DiagnosticLogger` | `os.Logger`'s methods (`debug`, `info`, `notice`, `warning`, `error`, `fault`) and `record(_:)` for a typed event, over a `DiagnosticLog`; lines of notice and above are also written to the file |
| `DiagnosticEventConvertible` | An app's typed event: a `category`, a `level` and a `DiagnosticMessage`, logged with `logger.record(event)` |
| `DiagnosticMessage` | A message rendered at the call site into its public form and its full form; `privacy: .private` values never reach the file |
| `OSLogPolicy` | `.publicFieldsAlways`, `.onlyWhileEnabled` or `.publicMessagesAlways` |
| `DiagnosticSystemLog` | The seam to the system log, so an app can test its policy with a recording implementation (`DiagnosticLog(configuration:flushDelay:isEnabled:systemLog:)`) |
| `DiagnosticRedactor` | `redact(_:)`: query strings, addresses, credentials, tokens, SASL payloads, base64 blobs |
| `DiagnosticArchive`, `DiagnosticArchiveError`, `DiagnosticSummary` | The export's zip (`.noLogs` when an export that requires logs has none) and its `summary.txt` |
| `DiagnosticLogFiles` | The files themselves: `allFiles()`, `hasLogs()` |
| `ErrorLog` | `kind(of:)` and `safeDescription(of:)`: what an error may say in clear and in the file |
| `DiagnosticLogPreference` | The switch, off by default, which a Debug environment variable can force on |

## Using it

```swift
.package(url: "https://github.com/Overlabing/DiagnosticsKit", exact: "0.1.1"),
```

```swift
import DiagnosticsKit

extension DiagnosticsConfiguration {
    static let app = DiagnosticsConfiguration(
        subsystem: "com.example.app", fileNamePrefix: "app", archiveName: "App", osLog: .onlyWhileEnabled)
}

extension DiagnosticLog {
    static let shared = DiagnosticLog(configuration: .app, isEnabled: false)
}

// At launch, once the switch is read:
DiagnosticLog.shared.setEnabled(preference.isEnabled)
DiagnosticLog.shared.start { try applicationSupport.appending(path: "Logs") }   // resolved on the writer's queue

let logger = DiagnosticLogger(category: "sync", sink: .shared)
logger.notice("synced \(count) messages for \(account)")   // numbers public, strings private by default
```

## What it promises

- **Opt-in.** Disabled, an entry is dropped at once, nothing is buffered, and no file or folder is created. Disabling
  keeps the files already written; `deleteAll()` removes them.
- **Never blocks.** Recording appends to a bounded buffer under a lock; a utility queue writes. Nothing is written on the
  main thread.
- **A private value never reaches the file.** And `DiagnosticRedactor` is the last net over every line, whatever its
  source. An error is written as `ErrorLog.safeDescription(of:)`: its kind and its numeric values, never a string.
- **The system log follows the policy.** With `.onlyWhileEnabled`, nothing reaches os_log while the log is off, and the
  message is not even rendered (the logger's methods take an autoclosure). The writer's own failures follow the same rule.
  With `.publicMessagesAlways`, a message whose interpolations are all public always reaches os_log, and a message with
  one private interpolation reaches it only while the log is on; the kit tells them apart from the message itself, so
  nothing is annotated at the call site, and a private message is built and dropped while the log is off.
