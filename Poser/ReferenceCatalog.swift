import Foundation
import UIKit

struct ReferenceAsset: Identifiable {
    let id: UUID
    let title: String
    let assetName: String
    let credit: String
    let license: String
    let source: URL?
    var setting: String? = nil
    var pose: String? = nil

    var image: UIImage? { loadImage(in: "images") }
    var preview: UIImage? { loadImage(in: "previews") }
    var imageData: Data? {
        guard let url = Bundle.main.url(forResource: assetName, withExtension: "jpg",
                                        subdirectory: "PinterestLibrary/images") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func loadImage(in folder: String) -> UIImage? {
        guard let url = Bundle.main.url(
            forResource: assetName,
            withExtension: "jpg",
            subdirectory: "PinterestLibrary/\(folder)"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

struct ReferenceTag: Hashable, Identifiable {
    enum Kind: String { case setting, pose }

    let kind: Kind
    let value: String
    var id: String { "\(kind.rawValue):\(value)" }
    var title: String { value == "cafe" ? "Café" : value.capitalized }

    func matches(_ asset: ReferenceAsset) -> Bool {
        switch kind {
        case .setting: asset.setting == value
        case .pose: asset.pose == value
        }
    }
}

enum ReferenceCatalog {
    private struct Library: Decodable {
        let references: [Entry]
    }

    private struct Entry: Decodable {
        let id: UUID
        let pinID: String
        let title: String
        let pinURL: URL
        let setting: String?
        let pose: String?
    }

    static let items: [ReferenceAsset] = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "PinterestLibrary"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(Library.self, from: data) else { return [] }
        return library.references.map { entry in
            ReferenceAsset(
                id: entry.id,
                title: entry.title,
                assetName: entry.pinID,
                credit: "Creator unverified",
                license: "Rights unverified",
                source: entry.pinURL,
                setting: entry.setting,
                pose: entry.pose
            )
        }
    }()

    static let tags: [ReferenceTag] = {
        let settings = Set(items.compactMap(\.setting)).sorted()
        let poses = Set(items.compactMap(\.pose)).sorted()
        return settings.map { ReferenceTag(kind: .setting, value: $0) }
            + poses.map { ReferenceTag(kind: .pose, value: $0) }
    }()

    static func items(matching tag: ReferenceTag?, query: String = "") -> [ReferenceAsset] {
        let terms = searchText(query).split { !$0.isLetter && !$0.isNumber }
        return items.filter { asset in
            guard tag?.matches(asset) ?? true else { return false }
            let text = searchText([asset.title, asset.setting ?? "", asset.pose ?? ""].joined(separator: " "))
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private static func searchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
