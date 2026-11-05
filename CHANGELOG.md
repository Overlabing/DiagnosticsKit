# Changelog

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
- **DiagnosticRedactor**: the last net before the file: query strings, addresses, credentials, OAuth tokens and codes,
  SASL payloads and base64 blobs.
- **DiagnosticArchive** and **DiagnosticSummary**: the zip (`summary.txt`, the log files, `environment.txt`) and the
  story that opens `summary.txt`: the last error shown and the breadcrumbs that led to it.
- **ErrorLog**: what an error may say in clear (`kind(of:)`) and in the file (`safeDescription(of:)`: kinds and
  numbers, never text).
- **DiagnosticLogPreference**: the switch of the log, off by default, which a Debug variable can force on.
