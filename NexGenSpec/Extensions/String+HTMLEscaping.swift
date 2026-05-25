import Foundation

extension String {
    /// Escapes the five characters that are unsafe to interpolate into HTML
    /// markup, so user-provided values can't break out of the surrounding
    /// element or inject tags when a string is sent with `isHTML: true`.
    ///
    /// Order matters: the ampersand is replaced first, otherwise the entities
    /// produced by the later replacements would themselves get double-escaped
    /// (e.g. `<` → `&lt;` → `&amp;lt;`).
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
