import Foundation
import UIKit

struct CompletedShot: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let photoFilename: String
    let referenceFilename: String
}

@MainActor
final class ShootStore: ObservableObject {
    @Published private(set) var shots: [CompletedShot] = []

    private let folder: URL
    private let indexURL: URL

    init(folder customFolder: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = customFolder ?? documents.appendingPathComponent("Shoots", isDirectory: true)
        indexURL = folder.appendingPathComponent("shots.json")
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([CompletedShot].self, from: data) {
            shots = decoded
        }
    }

    @discardableResult
    func add(photo: UIImage, reference: UIImage) throws -> CompletedShot {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let photoFilename = "\(id.uuidString)-photo.jpg"
        let referenceFilename = "\(id.uuidString)-reference.jpg"
        let photoURL = folder.appendingPathComponent(photoFilename)
        let referenceURL = folder.appendingPathComponent(referenceFilename)
        do {
            try jpeg(photo).write(to: photoURL, options: .atomic)
            try jpeg(reference).write(to: referenceURL, options: .atomic)
            let shot = CompletedShot(id: id, createdAt: Date(), photoFilename: photoFilename, referenceFilename: referenceFilename)
            let updated = [shot] + shots
            try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
            shots = updated
            return shot
        } catch {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: referenceURL)
            throw error
        }
    }

    func photo(for shot: CompletedShot) -> UIImage? {
        UIImage(contentsOfFile: folder.appendingPathComponent(shot.photoFilename).path)
    }

    func reference(for shot: CompletedShot) -> UIImage? {
        UIImage(contentsOfFile: folder.appendingPathComponent(shot.referenceFilename).path)
    }

    private func jpeg(_ image: UIImage) throws -> Data {
        let scale = min(1, 1800 / max(max(image.size.width, image.size.height), 1))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let normalized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.84) else {
            throw InspirationStoreError.imageEncodingFailed
        }
        return data
    }
}
