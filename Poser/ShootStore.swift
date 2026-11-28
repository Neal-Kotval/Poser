import Foundation
import UIKit

struct CompletedShot: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let photoFilename: String
    let referenceFilename: String
    /// Pose or outline match at capture time. Nil for shots saved before scores were stored.
    var matchScore: Int?
    /// Which reference was recreated, so distinct poses can be counted.
    var referenceID: UUID?
    /// When the owner liked the post. Nil means not liked. Optional so older saved shots still decode.
    var likedAt: Date?
    var comments: [ShotComment]?

    var isLiked: Bool { likedAt != nil }
    var likeCount: Int { isLiked ? 1 : 0 }
    var commentList: [ShotComment] { comments ?? [] }
}

struct ShotComment: Codable, Identifiable, Equatable {
    /// Instagram's comment limit.
    static let limit = 2200

    let id: UUID
    let author: String
    let text: String
    let createdAt: Date
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
        if let decoded = StorePersistence.decodeOrBackup([CompletedShot].self, from: indexURL) {
            shots = decoded
        }
    }

    @discardableResult
    func add(photo: UIImage, reference: UIImage, matchScore: Int? = nil,
             referenceID: UUID? = nil, createdAt: Date = Date()) throws -> CompletedShot {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let photoFilename = "\(id.uuidString)-photo.jpg"
        let referenceFilename = "\(id.uuidString)-reference.jpg"
        let photoURL = folder.appendingPathComponent(photoFilename)
        let referenceURL = folder.appendingPathComponent(referenceFilename)
        do {
            try jpeg(photo).write(to: photoURL, options: .atomic)
            try jpeg(reference).write(to: referenceURL, options: .atomic)
            let shot = CompletedShot(id: id, createdAt: createdAt, photoFilename: photoFilename,
                                     referenceFilename: referenceFilename, matchScore: matchScore,
                                     referenceID: referenceID)
            let updated = ([shot] + shots).sorted { $0.createdAt > $1.createdAt }
            try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
            shots = updated
            return shot
        } catch {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: referenceURL)
            throw error
        }
    }

    func remove(_ shot: CompletedShot) throws {
        let updated = shots.filter { $0.id != shot.id }
        try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
        shots = updated
        thumbnails.removeObject(forKey: shot.photoFilename as NSString)
        thumbnails.removeObject(forKey: shot.referenceFilename as NSString)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(shot.photoFilename))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(shot.referenceFilename))
    }

    func toggleLike(_ shotID: UUID, now: Date = Date()) throws {
        try update(shotID) { $0.likedAt = $0.likedAt == nil ? now : nil }
    }

    @discardableResult
    func addComment(_ text: String, author: String, to shotID: UUID, now: Date = Date()) throws -> ShotComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let comment = ShotComment(id: UUID(), author: author,
                                  text: String(trimmed.prefix(ShotComment.limit)), createdAt: now)
        try update(shotID) { $0.comments = ($0.comments ?? []) + [comment] }
        return comment
    }

    func removeComment(_ commentID: UUID, from shotID: UUID) throws {
        try update(shotID) { shot in
            let remaining = (shot.comments ?? []).filter { $0.id != commentID }
            shot.comments = remaining.isEmpty ? nil : remaining
        }
    }

    private var scoringAttempted: Set<UUID> = []

    /// Scores shots saved without a match %: older shots, and ones saved before scoring finished.
    /// Each shot is tried once per launch so photos with no visible pose aren't re-analyzed forever.
    func scoreMissingMatches() async {
        for shot in shots where shot.matchScore == nil && !scoringAttempted.contains(shot.id) {
            scoringAttempted.insert(shot.id)
            guard let photo = photo(for: shot), let reference = reference(for: shot),
                  let score = await Self.matchScore(reference: reference, shot: photo) else { continue }
            try? update(shot.id) { $0.matchScore = score }
        }
    }

    static func matchScore(reference: UIImage, shot: UIImage) async -> Int? {
        guard let target = try? await AnalysisService.analyze(reference),
              let live = try? await AnalysisService.analyze(shot),
              target.poseSkeleton != nil, live.poseSkeleton != nil else { return nil }
        return PoseMatcher.compare(reference: target.poseSkeleton, live: live.poseSkeleton,
                                   referenceOutline: target.shotSpec.silhouette,
                                   liveOutline: live.shotSpec.silhouette)?.score
    }

    private func update(_ shotID: UUID, _ change: (inout CompletedShot) -> Void) throws {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        var updated = shots
        change(&updated[index])
        try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
        shots = updated
    }

    var bestMatch: Int? { shots.compactMap(\.matchScore).max() }

    private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    /// Grid-sized images, decoded once and cached; full-size files are only read for detail and sharing.
    func photoThumbnail(for shot: CompletedShot) -> UIImage? { thumbnail(shot.photoFilename) }
    func referenceThumbnail(for shot: CompletedShot) -> UIImage? { thumbnail(shot.referenceFilename) }

    private func thumbnail(_ filename: String) -> UIImage? {
        if let cached = thumbnails.object(forKey: filename as NSString) { return cached }
        guard let full = UIImage(contentsOfFile: folder.appendingPathComponent(filename).path) else { return nil }
        let longest = max(full.size.width, full.size.height, 1)
        let scale = min(1, 480 / longest)
        let image = full.preparingThumbnail(of: CGSize(width: full.size.width * scale,
                                                       height: full.size.height * scale)) ?? full
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        thumbnails.setObject(image, forKey: filename as NSString, cost: cost)
        return image
    }

    func photo(for shot: CompletedShot) -> UIImage? {
        UIImage(contentsOfFile: folder.appendingPathComponent(shot.photoFilename).path)
    }

    func reference(for shot: CompletedShot) -> UIImage? {
        UIImage(contentsOfFile: folder.appendingPathComponent(shot.referenceFilename).path)
    }

    private func jpeg(_ image: UIImage) throws -> Data {
        guard let data = image.resizedJPEGData(maxDimension: 1800, quality: 0.84) else {
            throw InspirationStoreError.imageEncodingFailed
        }
        return data
    }
}

/// Everything the Profile page derives from a person's shots: streaks, match trend, milestones.
struct ProfileInsights: Equatable {
    struct Milestone: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let progress: Int
        let goal: Int
        var isEarned: Bool { progress >= goal }
    }

    let shotCount: Int
    let bestMatch: Int?
    let posesTried: Int
    let currentStreak: Int
    let longestStreak: Int
    /// Scored shots, oldest first, at most the last 12.
    let recentScores: [Int]
    let milestones: [Milestone]

    init(shots: [CompletedShot], savedPoses: Int, now: Date = Date(), calendar: Calendar = .current) {
        shotCount = shots.count
        let scores = shots.compactMap(\.matchScore)
        bestMatch = scores.max()
        posesTried = Set(shots.compactMap(\.referenceID)).count + shots.filter { $0.referenceID == nil }.count

        let days = Set(shots.map { calendar.startOfDay(for: $0.createdAt) })
        let today = calendar.startOfDay(for: now)
        var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        currentStreak = current

        var longest = 0, run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        longestStreak = longest

        recentScores = Array(shots.sorted { $0.createdAt < $1.createdAt }.compactMap(\.matchScore).suffix(12))

        let dialedIn = scores.filter { $0 >= 85 }.count
        milestones = [
            Milestone(id: "first", title: "First shot", detail: "Finish a shot", symbol: "camera.fill",
                      progress: min(shots.count, 1), goal: 1),
            Milestone(id: "streak", title: "On a roll", detail: "Shoot 3 days in a row", symbol: "flame.fill",
                      progress: min(longest, 3), goal: 3),
            Milestone(id: "explorer", title: "Explorer", detail: "Try 5 different poses", symbol: "map.fill",
                      progress: min(posesTried, 5), goal: 5),
            Milestone(id: "sharp", title: "Sharp eye", detail: "Hit a 90% match", symbol: "scope",
                      progress: (scores.max() ?? 0) >= 90 ? 1 : 0, goal: 1),
            Milestone(id: "dialed", title: "Dialed in", detail: "Three shots at 85%+", symbol: "target",
                      progress: min(dialedIn, 3), goal: 3),
            Milestone(id: "curator", title: "Curator", detail: "Save 10 poses", symbol: "square.stack.fill",
                      progress: min(savedPoses, 10), goal: 10),
        ]
    }

    var averageScore: Int? {
        recentScores.isEmpty ? nil : Int((Double(recentScores.reduce(0, +)) / Double(recentScores.count)).rounded())
    }

    /// Compares the last three scored shots with the three before them.
    var trendDelta: Int? {
        guard recentScores.count >= 4 else { return nil }
        let latest = recentScores.suffix(3)
        let earlier = recentScores.dropLast(3).suffix(3)
        let mean: (ArraySlice<Int>) -> Double = { Double($0.reduce(0, +)) / Double($0.count) }
        return Int((mean(latest) - mean(earlier)).rounded())
    }

    var trendHeadline: String {
        if let delta = trendDelta {
            if delta > 0 { return "Up \(delta) points lately" }
            if delta < 0 { return "Down \(-delta) points lately" }
            return "Holding steady"
        }
        return averageScore.map { "Average \($0)%" } ?? ""
    }

    var earnedCount: Int { milestones.filter(\.isEarned).count }
}
