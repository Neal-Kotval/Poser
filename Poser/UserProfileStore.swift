import Foundation
import UIKit

struct UserProfile: Codable, Equatable {
    var displayName: String
    var avatarFilename: String?

    static let `default` = UserProfile(displayName: "Photographer", avatarFilename: nil)
}

@MainActor
final class UserProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile

    private let folder: URL
    private let profileURL: URL

    init(folder customFolder: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = customFolder ?? documents.appendingPathComponent("Profile", isDirectory: true)
        profileURL = folder.appendingPathComponent("profile.json")
        if let data = try? Data(contentsOf: profileURL),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = decoded
        } else {
            profile = .default
        }
    }

    var initials: String {
        let parts = profile.displayName
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "P" : letters.joined().uppercased()
    }

    var avatarImage: UIImage? {
        guard let filename = profile.avatarFilename else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(filename).path)
    }

    func updateDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.displayName = trimmed
        save()
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
        profile.avatarFilename = filename
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: profileURL, options: .atomic)
        }
    }
}
