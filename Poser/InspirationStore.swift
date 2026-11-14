import Foundation
import UIKit

struct InspirationItem: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let source: String
    let createdAt: Date
    let filename: String
}

enum InspirationSource: Equatable {
    case photoLibrary
    case link

    var label: String {
        switch self {
        case .photoLibrary: "Photo library"
        case .link: "Photo link"
        }
    }
}

enum InspirationStoreError: LocalizedError {
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: "This photo could not be saved to your inspiration library."
        }
    }
}

@MainActor
final class InspirationStore: ObservableObject {
    @Published private(set) var items: [InspirationItem] = []

    private let folder: URL
    private let indexURL: URL

    init(folder customFolder: URL? = nil, fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = customFolder ?? documents.appendingPathComponent("Inspiration", isDirectory: true)
        indexURL = folder.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([InspirationItem].self, from: data) {
            items = decoded
        }
    }

    @discardableResult
    func add(_ image: UIImage, source: InspirationSource, originalData: Data? = nil) throws -> InspirationItem {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let size = image.size
        let scale = min(1, 1600 / max(max(size.width, size.height), 1))
        let renderSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let normalized = UIGraphicsImageRenderer(size: renderSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.82) else {
            throw InspirationStoreError.imageEncodingFailed
        }
        let imageURL = folder.appendingPathComponent(filename)
        let originalURL = folder.appendingPathComponent("\(id.uuidString).original")
        let item = InspirationItem(
            id: id,
            title: source == .link ? "Linked photo \(items.count + 1)" : "Reference \(items.count + 1)",
            source: source.label,
            createdAt: Date(),
            filename: filename
        )
        let updated = [item] + items
        do {
            try data.write(to: imageURL, options: .atomic)
            if let originalData { try originalData.write(to: originalURL, options: .atomic) }
            try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
            items = updated
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: originalURL)
            throw error
        }
        return item
    }

    func remove(_ ids: Set<UUID>) throws {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let updated = items.filter { !ids.contains($0.id) }
        try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
        items = updated
        for item in removed {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(item.filename))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(item.id.uuidString).original"))
        }
    }

    func image(for item: InspirationItem) -> UIImage? {
        UIImage(contentsOfFile: folder.appendingPathComponent(item.filename).path)
    }

    /// Original bytes preserve EXIF lens and depth metadata for later shot analysis.
    func originalData(for item: InspirationItem) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent("\(item.id.uuidString).original"))
    }
}
