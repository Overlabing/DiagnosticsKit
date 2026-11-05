import Foundation

/// What an error may say in clear in os_log: its type and its case, never its values (a refused address, a server's
/// text). The full detail goes in a `privacy: .private` argument.
public enum ErrorLog {
    public static func kind(of error: any Error) -> String {
        if Swift.type(of: error) is NSError.Type {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        let type = String(reflecting: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return type }
        // A case with values: its label alone. A case without values: its name, which carries nothing else.
        if let label = mirror.children.first?.label { return "\(type).\(label)" }
        return "\(type).\(String(describing: error))"
    }
}

extension ErrorLog {
    /// What the exportable diagnostic file may say of an error: its kind, then, for an enum case or a
    /// struct, only its numeric and boolean values and the kinds of the errors it wraps (`NSUnderlyingErrorKey`
    /// included), two levels deep. Never a string, a URL or data: a server's reply, a folder name, a searched text or
    /// an address stay out, whatever the redactor would have caught.
    /// `ProviderError.server(code: 500, message: "…")` → `Sync.ProviderError.server(code: 500)`.
    public static func safeDescription(of error: any Error) -> String {
        describe(error, depth: 0)
    }

    private static func describe(_ error: any Error, depth: Int) -> String {
        let mirror = Mirror(reflecting: error)
        // An NSError, or a Foundation error struct bridged to one (`URLError`, `CocoaError`): domain and code, and the
        // underlying error; never `userInfo`'s texts and URLs (`NSErrorFailingURLStringKey`).
        if Swift.type(of: error) is NSError.Type || (mirror.displayStyle == .struct && error is any CustomNSError) {
            let ns = error as NSError
            let underlying = depth < 2 ? ns.userInfo[NSUnderlyingErrorKey] as? any Error : nil
            return "\(ns.domain) \(ns.code)" + (underlying.map { " (underlying: \(describe($0, depth: depth + 1)))" } ?? "")
        }
        let kind = kind(of: error)
        guard depth < 2 else { return kind }
        let fields: [(label: String?, value: Any)]
        switch mirror.displayStyle {
        case .enum:
            // The case's payload: one value, or a tuple of labelled values.
            guard let payload = mirror.children.first?.value else { return kind }
            let tuple = Mirror(reflecting: payload)
            fields = tuple.displayStyle == .tuple ? tuple.children.map { ($0.label, $0.value) } : [(nil, payload)]
        case .struct, .class:
            fields = mirror.children.map { ($0.label, $0.value) }
        default:
            return kind
        }
        let parts = fields.compactMap { field -> String? in
            guard let value = safeValue(field.value, depth: depth) else { return nil }
            let label = field.label.flatMap { $0.hasPrefix(".") ? nil : $0 }
            return label.map { "\($0): \(value)" } ?? value
        }
        return parts.isEmpty ? kind : "\(kind)(\(parts.joined(separator: ", ")))"
    }

    private static func safeValue(_ value: Any, depth: Int) -> String? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return nil }
            return safeValue(wrapped, depth: depth)
        }
        switch value {
        case let error as any Error: return describe(error, depth: depth + 1)
        case let number as any BinaryInteger: return String(describing: number)
        case let flag as Bool: return flag ? "true" : "false"
        default: return nil
        }
    }
}
