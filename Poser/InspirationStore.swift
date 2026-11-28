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

    var label: String {
        switch self {
        case .photoLibrary: "Photo library"
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

extension UIImage {
    func resized(maxDimension: CGFloat, pixelScale: Bool = false) -> UIImage {
        let width = pixelScale ? CGFloat(cgImage?.width ?? Int(size.width * scale)) : size.width
        let height = pixelScale ? CGFloat(cgImage?.height ?? Int(size.height * scale)) : size.height
        let longest = max(max(width, height), 1)
        if pixelScale && longest <= maxDimension { return self }
        let ratio = min(1, maxDimension / longest)
        let renderSize = CGSize(width: max(1, width * ratio), height: max(1, height * ratio))
        let format = UIGraphicsImageRendererFormat()
        if pixelScale { format.scale = 1 }
        return UIGraphicsImageRenderer(size: renderSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }

    func resizedJPEGData(maxDimension: CGFloat, quality: CGFloat) -> Data? {
        resized(maxDimension: maxDimension).jpegData(compressionQuality: quality)
    }
}

@MainActor
final class InspirationStore: ObservableObject {
    @Published private(set) var items: [InspirationItem] = []

    private let folder: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    init(folder customFolder: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = customFolder ?? documents.appendingPathComponent("Inspiration", isDirectory: true)
        indexURL = folder.appendingPathComponent("library.json")
        if let decoded = StorePersistence.decodeOrBackup([InspirationItem].self, from: indexURL, fileManager: fileManager) {
            items = decoded
        }
    }

    @discardableResult
    func add(_ image: UIImage, source: InspirationSource, originalData: Data? = nil) throws -> InspirationItem {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        guard let data = image.resizedJPEGData(maxDimension: 1600, quality: 0.82) else {
            throw InspirationStoreError.imageEncodingFailed
        }
        let imageURL = folder.appendingPathComponent(filename)
        let originalURL = folder.appendingPathComponent("\(id.uuidString).original")
        let item = InspirationItem(
            id: id,
            title: "Reference \(items.count + 1)",
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
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: originalURL)
            throw error
        }
        return item
    }

    func image(for item: InspirationItem) -> UIImage? {
        let key = item.filename as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(item.filename).path) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        imageCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Original bytes preserve EXIF lens and depth metadata for later shot analysis.
    func originalData(for item: InspirationItem) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent("\(item.id.uuidString).original"))
    }

    func remove(_ item: InspirationItem) throws {
        try remove(ids: [item.id])
    }

    func remove(ids: Set<UUID>) throws {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let updated = items.filter { !ids.contains($0.id) }
        // Commit the index once for the whole selection before deleting files.
        try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
        items = updated
        for item in removed { imageCache.removeObject(forKey: item.filename as NSString) }
        for item in removed {
            let imageURL = folder.appendingPathComponent(item.filename)
            let originalURL = folder.appendingPathComponent("\(item.id.uuidString).original")
            for url in [imageURL, originalURL] {
                do {
                    try fileManager.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                } catch {
                    #if DEBUG
                    print("[InspirationStore] Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }
}
