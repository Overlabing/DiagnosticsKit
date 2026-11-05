import Foundation

/// The last net before the diagnostic file: every line passes here, whatever its source.
/// A URL's query string becomes `?<query>` (a search sits in `?q=`); addresses, plain or percent-encoded (`%40`),
/// become `<address>`; bearer and basic credentials, OAuth tokens and codes, passwords and SASL payloads become
/// `<secret>`; any other run of 24 base64 characters or more holding a digit, `+` or `/` becomes `<blob>`. Private log values never get this far (`DiagnosticMessage`); this catches what a public value or
/// an error's `String(reflecting:)` carries (a server reply quoting an address, a URL with a token).
public enum DiagnosticRedactor {
    public static func redact(_ text: String) -> String {
        var result = text
        // Byte checks first: most lines hold none of these.
        if result.utf8.contains(UInt8(ascii: "?")) {
            result = replace(query, in: result, with: "?<query>")
        }
        if result.utf8.contains(UInt8(ascii: "@")) {
            result = replace(email, in: result, with: "<address>")
        }
        if result.contains("%40") {
            result = replace(encodedEmail, in: result, with: "<address>")
        }
        if mayHoldSecret(result) {
            for (pattern, template) in secrets {
                result = replace(pattern, in: result, with: template)
            }
        }
        if mayHoldBlob(result) {
            result = replace(blob, in: result, with: "<blob>")
        }
        return result
    }

    /// One pass over the bytes: is there a run of 24 base64 characters mixing upper and lower case with a digit, `+`
    /// or `/`? Most lines have none, and the regex (lookaheads on every position) is then skipped.
    static func mayHoldBlob(_ text: String) -> Bool {
        var length = 0
        var upper = false, lower = false, other = false
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): upper = true
            case UInt8(ascii: "a")...UInt8(ascii: "z"): lower = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"): other = true
            case UInt8(ascii: "="): break
            default:
                length = 0
                upper = false
                lower = false
                other = false
                continue
            }
            length += 1
            if length >= 24, upper, lower, other { return true }
        }
        return false
    }

    /// Cheap pre-check so the usual line (no credential vocabulary) skips the secret patterns.
    private static func mayHoldSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["bearer", "basic", "token", "code", "secret", "passw", "auth", "apikey", "api_key", "key="]
            .contains { lowered.contains($0) }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func regex(_ pattern: String, caseSensitive: Bool = false) -> NSRegularExpression {
        // The patterns are literals of this file: a failure is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    private static let email = regex(#"[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"#)

    /// `name%40example.com`, as an address sits in a URL or a form body.
    private static let encodedEmail = regex(#"[A-Z0-9._%+\-]+%40[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"#)

    /// A URL's query string, up to the first space or quote: `…/messages?q=facture%20orange&maxResults=50`.
    private static let query = regex(#"\?[^\s"'<>]+"#)

    /// Base64 or token-like runs: 24+ characters mixing upper and lower case with a digit, `+` or `/`. An identifier
    /// of letters only (`accessGroupMigration`) and a lowercase URL path (`api/v1/accounts/me`) stay.
    private static let blob = regex(
        #"(?<![A-Za-z0-9+/=])(?=[A-Za-z0-9+/=]*[A-Z])(?=[A-Za-z0-9+/=]*[a-z])(?=[A-Za-z0-9+/=]*[0-9+/])[A-Za-z0-9+/=]{24,}(?![A-Za-z0-9+/=])"#,
        caseSensitive: true)

    private static let secrets: [(NSRegularExpression, String)] = [
        // `Authorization: Bearer ya29…`, `Basic dXNlcjpwYXNz`.
        (regex(#"\b(bearer|basic)\s+[A-Z0-9._~+/=\-]{6,}"#), "$1 <secret>"),
        // SASL payloads: `AUTHENTICATE XOAUTH2 dXNlcj1…`, `AUTH PLAIN AHVzZXIA…`.
        (regex(#"\b(authenticate|auth)\s+(plain|login|xoauth2|oauthbearer)\s+\S+"#), "$1 $2 <secret>"),
        // `access_token=…`, `"refresh_token": "…"`, `password: …`, `client_secret=…`, `api_key=…`.
        (
            regex(
                #"\b(access_token|refresh_token|id_token|token|client_secret|secret|password|passwd|api_?key|apikey)(\\?["']?\s*[:=]\s*\\?["']?)[^\s"'\\&,;)}]+"#
            ), "$1$2<secret>"
        ),
        // OAuth authorization code in a form body (`code=4/0Ab…`), lowercase as OAuth writes it; `code: 500` and
        // NSError's `Code=-1001` stay.
        (regex(#"\b(code=)(?![-0-9]+(?:[\s"'&,;)}]|$))[^\s"'&,;)}]+"#, caseSensitive: true), "$1<secret>"),
    ]
}
