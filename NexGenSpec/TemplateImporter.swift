import Foundation

/// Represents the full structure of a heavy inspection template as defined in
/// the accompanying JSON.  This type mirrors all of the keys found in
/// `DIAInspect_Template_Heavy_v1.json` so it can be decoded directly with
/// `JSONDecoder`.  You can convert instances of this type into your own
/// internal template models or use them directly to build inspection forms.
struct HeavyTemplate: Codable {
    let templateId: String
    var name: String
    var version: Int
    var severityScale: [String]
    var statusOptions: [String]
    var sections: [HeavySection]
    
    enum CodingKeys: String, CodingKey {
        case templateId
        case name
        case version
        case severityScale
        case statusOptions
        case sections
    }
}

/// A section within a heavy template.  Each section has its own unique
/// identifier, display title, default contractor tag and a list of items.
struct HeavySection: Codable {
    let sectionId: String
    var title: String
    var defaultContractorTag: String
    var items: [HeavyItem]
    
    enum CodingKeys: String, CodingKey {
        case sectionId
        case title
        case defaultContractorTag
        case items
    }
}

/// An individual inspection item within a heavy section.  Items include
/// metadata such as a default severity category, a contractor tag,
/// a set of boolean fields indicating which text fields should be displayed,
/// and a comment library containing default text.
struct HeavyItem: Codable {
    let itemId: String
    var title: String
    var defaultSeverity: String
    var contractorTag: String
    var fields: HeavyFields
    var commentLibrary: HeavyCommentLibrary
    
    enum CodingKeys: String, CodingKey {
        case itemId
        case title
        case defaultSeverity
        case contractorTag
        case fields
        case commentLibrary
    }
}

/// Field flags used by an inspection item.  Each boolean indicates whether
/// the corresponding text field (location, observed, implication, recommendation)
/// should be displayed for the item during report generation.
struct HeavyFields: Codable {
    var location: Bool
    var observed: Bool
    var implication: Bool
    var recommendation: Bool
}

/// Comment library used by an inspection item.  Each property contains the
/// default text to display for the associated field.  These values are
/// typically empty in the provided JSON and can be customized by users.
struct HeavyCommentLibrary: Codable {
    var observed: String
    var implication: String
    var recommendation: String
}

/// Helper responsible for loading and decoding heavy templates from JSON.
/// To use, call `HeavyTemplateImporter.load(from:)` with a URL pointing
/// at the JSON file.  This returns an instance of `HeavyTemplate` that
/// can be further processed into your app’s template models.
enum HeavyTemplateImporter {
    /// Reads the contents of the file at `url` and attempts to decode it
    /// into a `HeavyTemplate` instance.  If the file cannot be read or
    /// decoded, this method returns `nil`.
    ///
    /// - Parameter url: The location of the JSON template file on disk.
    /// - Returns: A `HeavyTemplate` if decoding succeeds; otherwise `nil`.
    static func load(from url: URL) -> HeavyTemplate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(HeavyTemplate.self, from: data)
    }
}