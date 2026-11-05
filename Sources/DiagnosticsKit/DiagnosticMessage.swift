import Foundation
import os

/// Level of a line in the file. `warning` is os_log's error type, kept apart so the file says what the code said.
public enum DiagnosticLevel: String, Sendable, Comparable, CaseIterable {
    case notice, warning, error, fault

    var osLogType: OSLogType {
        switch self {
        case .notice: .default
        case .warning, .error: .error
        case .fault: .fault
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Same meaning as os_log's: `.private` values are `<private>` in clear and never written to the file. Without an
/// explicit privacy, os_log's defaults apply: numbers, booleans and types are public, strings and objects private.
public enum DiagnosticPrivacy: Sendable {
    case `public`, `private`
}

/// `format:` of a floating-point interpolation, as os_log's `.fixed(precision:)`.
public enum DiagnosticFloatFormat: Sendable {
    case fixed(precision: Int)

    public static var fixed: Self { .fixed(precision: 6) }

    func render(_ value: Double) -> String {
        switch self {
        case .fixed(let precision): String(format: "%.\(max(0, precision))f", value)
        }
    }
}

/// A log message, rendered at the call site into its clear (`redacted`) and full forms.
public struct DiagnosticMessage: ExpressibleByStringInterpolation, Sendable {
    public let redacted: String
    public let full: String
    public let hasPrivate: Bool

    public init(stringLiteral value: String) {
        redacted = value
        full = value
        hasPrivate = false
    }

    public init(stringInterpolation: StringInterpolation) {
        redacted = stringInterpolation.redacted
        full = stringInterpolation.full
        hasPrivate = stringInterpolation.hasPrivate
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var redacted = ""
        var full = ""
        var hasPrivate = false

        public init(literalCapacity: Int, interpolationCount: Int) {
            redacted.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            redacted += literal
            full += literal
        }

        public mutating func appendInterpolation(_ value: String, privacy: DiagnosticPrivacy = .private) {
            append(value, privacy)
        }

        public mutating func appendInterpolation(_ value: some CustomStringConvertible, privacy: DiagnosticPrivacy = .private) {
            append(value.description, privacy)
        }

        public mutating func appendInterpolation(_ value: some BinaryInteger, privacy: DiagnosticPrivacy = .public) {
            append(String(value), privacy)
        }

        public mutating func appendInterpolation(
            _ value: Double, format: DiagnosticFloatFormat? = nil, privacy: DiagnosticPrivacy = .public
        ) {
            append(format?.render(value) ?? String(value), privacy)
        }

        public mutating func appendInterpolation(
            _ value: Float, format: DiagnosticFloatFormat? = nil, privacy: DiagnosticPrivacy = .public
        ) {
            appendInterpolation(Double(value), format: format, privacy: privacy)
        }

        public mutating func appendInterpolation(
            _ value: CGFloat, format: DiagnosticFloatFormat? = nil, privacy: DiagnosticPrivacy = .public
        ) {
            appendInterpolation(Double(value), format: format, privacy: privacy)
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: DiagnosticPrivacy = .public) {
            append(value ? "true" : "false", privacy)
        }

        public mutating func appendInterpolation(_ value: Any.Type, privacy: DiagnosticPrivacy = .public) {
            append(String(reflecting: value), privacy)
        }

        private mutating func append(_ text: String, _ privacy: DiagnosticPrivacy) {
            full += text
            switch privacy {
            case .public:
                redacted += text
            case .private:
                redacted += "<private>"
                hasPrivate = true
            }
        }
    }
}
