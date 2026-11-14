import Foundation
import UIKit

struct ReferenceAsset: Identifiable {
    let id: UUID
    let title: String
    let assetName: String
    let credit: String
    let license: String
    let source: URL?

    var image: UIImage? { loadImage(in: "images") }
    var preview: UIImage? { loadImage(in: "previews") }

    private func loadImage(in folder: String) -> UIImage? {
        guard let url = Bundle.main.url(
            forResource: assetName,
            withExtension: "jpg",
            subdirectory: "PinterestLibrary/\(folder)"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
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
                source: entry.pinURL
            )
        }
    }()
}
