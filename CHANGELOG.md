# Changelog

## 0.1.1

Review fixes of the first adopter and the requests of the second.

### Added

- **`OSLogPolicy.publicMessagesAlways`**: a message whose interpolations are all public always reaches the system log;
  a message with at least one private interpolation reaches it only while the log is on. Derived from the message's own
  privacy, with no annotation at the call site. Off, a message is built to be classified and dropped when private.
- **`DiagnosticLogFiles.hasLogs()`** and **`DiagnosticLog.hasLogs()`**: whether there is a log file to export, for an
  app that wants to offer the export only then.
- **`DiagnosticArchiveError.noLogs`**, thrown by `DiagnosticArchive.write` and `DiagnosticLog.export` when
  `requireLogs: true` and there is no log file. Nothing is written, a file already at the destination stays. The default
  (`requireLogs: false`) keeps 0.1.0's behavior: a zip with `environment.txt` and `summary.txt` alone.
- **`DiagnosticEventConvertible`** and **`DiagnosticLogger.record(_:)`**: an app's typed event (category, level,
  `DiagnosticMessage`) logged in one call, under the event's own category and level, with the privacy of its message
  and the logger's policy. The message is not built when nothing would use it.

### Changed

- The gate and the CI use AppTooling 0.2.0 (was 0.1.0).

### Fixed

- A test literal changed on extraction (`alice@exemple.fr` in `ErrorLogTests`) is back to its original.


## 0.1.0

First release, extracted from one app so that a second can share it.

### Added

- **DiagnosticLog**: an opt-in local diagnostic log. Disabled, an entry is dropped at once and no file or folder is
  created. Enabled, entries join a bounded buffer and a serial utility queue writes them in batches (at once for an
  error), to one file per UTC day, rotated past a size, pruned past an age and a total size, exported as a zip.
- **DiagnosticLogger**: a drop-in for `os.Logger` (same methods, same `privacy:` and `format:` interpolations) that
  renders each message twice, with private values replaced by `<private>` for the file and in full for the system log.
- **DiagnosticsConfiguration**: the subsystem, the file name prefix, the archive's name, the limits (7 days, 5 MB per
  file, 25 MB in all by default), the system log policy and the vocabulary of `summary.txt` are the app's.
- **OSLogPolicy**: `.publicFieldsAlways` (every line reaches the system log in its public form) or `.onlyWhileEnabled`
  (nothing reaches it, and the message is not even rendered, while the log is off).
- **DiagnosticSystemLog**: the seam to the system log, so an app can see what its policy lets through, which the
  system log itself cannot show.
- **DiagnosticRedactor**: the last net before the file: query strings, addresses, credentials, OAuth tokens and codes,
  SASL payloads and base64 blobs.
- **DiagnosticArchive** and **DiagnosticSummary**: the zip (`summary.txt`, the log files, `environment.txt`) and the
  story that opens `summary.txt`: the last error shown and the breadcrumbs that led to it.
- **ErrorLog**: what an error may say in clear (`kind(of:)`) and in the file (`safeDescription(of:)`: kinds and
  numbers, never text).
- **DiagnosticLogPreference**: the switch of the log, off by default, which a Debug variable can force on.
