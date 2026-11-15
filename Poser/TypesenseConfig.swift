import Foundation

/// Reads Typesense Cloud (or local) credentials from `Secrets/Typesense.plist` when present.
/// Copy `Secrets/Typesense.plist.example` → `Secrets/Typesense.plist` and fill in values.
enum TypesenseConfig {
    static let collection = "references"

    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Typesense", withExtension: "plist",
                                        subdirectory: "Secrets"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return plist
    }()

    static var host: String { values["Host"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static var port: String { values["Port"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "443" }
    static var proto: String { values["Protocol"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "https" }
    /// Search-only key for the iOS app. Never put the admin key here.
    static var searchAPIKey: String { values["SearchAPIKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    static var isConfigured: Bool {
        !host.isEmpty && !searchAPIKey.isEmpty
    }

    /// Enable only after `references` has an image embedding field. Keyword-only clusters
    /// use Vision labels with Typesense text search instead.
    static var imageSearchEnabled: Bool { values["ImageSearchEnabled"] == "true" }

    static var baseURL: URL? {
        guard isConfigured else { return nil }
        var components = URLComponents()
        components.scheme = proto
        components.host = host
        if let portNumber = Int(port), !(proto == "https" && portNumber == 443), !(proto == "http" && portNumber == 80) {
            components.port = portNumber
        }
        return components.url
    }
}
