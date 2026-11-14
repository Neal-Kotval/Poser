import Foundation
import UIKit

@MainActor
final class ReferenceLikeStore: ObservableObject {
    @Published private(set) var likedIDs: Set<String>
    private let defaults: UserDefaults
    private let key = "poser.referenceLikes.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        likedIDs = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func isLiked(_ referenceID: String) -> Bool { likedIDs.contains(referenceID) }

    func toggle(_ referenceID: String) {
        if likedIDs.contains(referenceID) { likedIDs.remove(referenceID) }
        else { likedIDs.insert(referenceID) }
        defaults.set(likedIDs.sorted(), forKey: key)
    }
}

private enum ReferencePreviewCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()
}

struct ReferenceAsset: Identifiable {
    let id: UUID
    let title: String
    let assetName: String
    let credit: String
    let license: String
    let source: URL?
    var setting: String? = nil
    var pose: String? = nil

    var mockPost: MockReferencePost {
        MockReferencePost(referenceID: assetName)
    }

    var image: UIImage? { loadImage(in: "images") }
    var preview: UIImage? { loadImage(in: "previews") }
    /// Feed cards use the original bundled image, decoded off the main thread.
    /// Small previews remain available for scene matching and placeholders.
    var feedImage: UIImage? {
        guard let url = Bundle.main.url(forResource: assetName, withExtension: "jpg",
                                        subdirectory: "PinterestLibrary/images") else { return nil }
        let key = url.path as NSString
        if let cached = ReferencePreviewCache.images.object(forKey: key) { return cached }
        guard let original = UIImage(contentsOfFile: url.path) else { return nil }
        let decoded = original.preparingForDisplay() ?? original
        let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        ReferencePreviewCache.images.setObject(decoded, forKey: key, cost: cost)
        return decoded
    }
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
        let key = url.path as NSString
        if folder == "previews", let cached = ReferencePreviewCache.images.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        if folder == "previews" {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            ReferencePreviewCache.images.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}

/// Presentation-only mock data; not attribution or engagement from Pinterest.
struct MockReferencePost {
    let accountName: String
    let initials: String
    let likeCount: Int

    init(referenceID: String) {
        let accounts = [
            ("demo.softlight", "SL"), ("demo.cityframes", "CF"),
            ("demo.weekendmuse", "WM"), ("demo.poseedit", "PE"),
            ("demo.slowdays", "SD"), ("demo.goldenhour", "GH")
        ]
        // A stable seed prevents metadata changing across renders or launches.
        let seed = referenceID.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        let account = accounts[Int(seed % UInt64(accounts.count))]
        accountName = account.0
        initials = account.1
        likeCount = 36 + Int((seed / 7) % 9400)
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
