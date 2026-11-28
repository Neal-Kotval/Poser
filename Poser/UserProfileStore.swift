import Foundation
import UIKit

struct UserProfile: Codable, Equatable {
    /// Instagram's limits: a 30-character name and a 150-character bio.
    static let nameLimit = 30
    static let bioLimit = 150

    var displayName: String
    var avatarFilename: String?
    var bio: String?

    static let `default` = UserProfile(displayName: "Photographer", avatarFilename: nil, bio: nil)
}

enum StorePersistence {
    static func decodeOrBackup<T: Decodable>(_ type: T.Type, from url: URL, fileManager: FileManager = .default) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let stamp = Int(Date().timeIntervalSince1970)
            let parent = url.deletingLastPathComponent()
            var backup = parent.appendingPathComponent("\(stem).corrupt.\(stamp).\(ext)")
            if fileManager.fileExists(atPath: backup.path) {
                backup = parent.appendingPathComponent("\(stem).corrupt.\(stamp)-\(UUID().uuidString.prefix(6)).\(ext)")
            }
            try? fileManager.moveItem(at: url, to: backup)
            #if DEBUG
            print("[StorePersistence] Backed up unreadable \(url.lastPathComponent) to \(backup.lastPathComponent): \(error)")
            #endif
            return nil
        }
    }
}

@MainActor
final class UserProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile
    @Published private(set) var avatarImage: UIImage?

    private let folder: URL
    private let profileURL: URL

    init(folder customFolder: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = customFolder ?? documents.appendingPathComponent("Profile", isDirectory: true)
        profileURL = folder.appendingPathComponent("profile.json")
        profile = StorePersistence.decodeOrBackup(UserProfile.self, from: profileURL) ?? .default
        if let filename = profile.avatarFilename {
            avatarImage = UIImage(contentsOfFile: folder.appendingPathComponent(filename).path)
        }
    }

    var initials: String {
        let parts = profile.displayName
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "P" : letters.joined().uppercased()
    }

    func updateDisplayName(_ name: String) {
        let singleLine = name.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        profile.displayName = String(trimmed.prefix(UserProfile.nameLimit))
        saveBestEffort()
    }

    func updateBio(_ bio: String) {
        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.bio = trimmed.isEmpty ? nil : String(trimmed.prefix(UserProfile.bioLimit))
        saveBestEffort()
    }

    func updateAvatar(_ image: UIImage) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = "avatar.jpg"
        let size = CGSize(width: 400, height: 400)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            let scale = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.85) else {
            throw InspirationStoreError.imageEncodingFailed
        }
        try data.write(to: folder.appendingPathComponent(filename), options: .atomic)
        let previous = profile
        profile.avatarFilename = filename
        do {
            try save()
            avatarImage = rendered
        } catch {
            profile = previous
            throw error
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: profileURL, options: .atomic)
    }

    private func saveBestEffort() {
        do {
            try save()
        } catch {
            #if DEBUG
            print("[UserProfileStore] Failed to save profile: \(error.localizedDescription)")
            #endif
        }
    }
}
