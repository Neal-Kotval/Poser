import XCTest
@testable import Poser

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testDefaultProfilePersistsNameChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = UserProfileStore(folder: folder)
        XCTAssertEqual(store.profile.displayName, "Photographer")
        XCTAssertEqual(store.initials, "P")

        store.updateDisplayName("  Aarush Mathad  ")
        XCTAssertEqual(store.profile.displayName, "Aarush Mathad")
        XCTAssertEqual(store.initials, "AM")

        let reopened = UserProfileStore(folder: folder)
        XCTAssertEqual(reopened.profile.displayName, "Aarush Mathad")
        XCTAssertEqual(reopened.initials, "AM")
    }

    func testAvatarRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = UserProfileStore(folder: folder)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        try store.updateAvatar(image)

        let reopened = UserProfileStore(folder: folder)
        XCTAssertNotNil(reopened.avatarImage)
        XCTAssertEqual(reopened.profile.avatarFilename, "avatar.jpg")
    }

    func testCorruptJSONBackedUpOnStoreInit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let corrupt = Data("{corrupt json".utf8)

        let profileDir = root.appendingPathComponent("profile", isDirectory: true)
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try corrupt.write(to: profileDir.appendingPathComponent("profile.json"))
        let profileStore = UserProfileStore(folder: profileDir)
        XCTAssertEqual(profileStore.profile, .default)
        let profileBackups = try fm.contentsOfDirectory(atPath: profileDir.path).filter { $0.hasPrefix("profile.corrupt.") }
        XCTAssertEqual(profileBackups.count, 1)
        XCTAssertEqual(try Data(contentsOf: profileDir.appendingPathComponent(profileBackups[0])), corrupt)

        let inspDir = root.appendingPathComponent("inspiration", isDirectory: true)
        try fm.createDirectory(at: inspDir, withIntermediateDirectories: true)
        try corrupt.write(to: inspDir.appendingPathComponent("library.json"))
        let inspStore = InspirationStore(folder: inspDir)
        XCTAssertTrue(inspStore.items.isEmpty)
        let inspBackups = try fm.contentsOfDirectory(atPath: inspDir.path).filter { $0.hasPrefix("library.corrupt.") }
        XCTAssertEqual(inspBackups.count, 1)

        let shootDir = root.appendingPathComponent("shoots", isDirectory: true)
        try fm.createDirectory(at: shootDir, withIntermediateDirectories: true)
        try corrupt.write(to: shootDir.appendingPathComponent("shots.json"))
        let shootStore = ShootStore(folder: shootDir)
        XCTAssertTrue(shootStore.shots.isEmpty)
        let shootBackups = try fm.contentsOfDirectory(atPath: shootDir.path).filter { $0.hasPrefix("shots.corrupt.") }
        XCTAssertEqual(shootBackups.count, 1)
    }

    func testInspirationBulkRemoveContinuesPastSingleFileFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let failingFM = FailingRemoveFileManager()
        let store = InspirationStore(folder: folder, fileManager: failingFM)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let original = try XCTUnwrap(image.pngData())
        let first = try store.add(image, source: .photoLibrary, originalData: original)
        let second = try store.add(image, source: .photoLibrary, originalData: original)

        // Delete one original early to exercise .fileNoSuchFile, and fail removal on the second's jpg.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(first.id.uuidString).original"))
        failingFM.blockedFilename = second.filename

        try store.remove(ids: [first.id, second.id])

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(first.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(second.id.uuidString).original").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(second.filename).path))
    }
}

private final class FailingRemoveFileManager: FileManager {
    var blockedFilename: String?

    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent == blockedFilename {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

final class ProfileInsightsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = ISO8601DateFormatter().date(from: "2026-11-14T18:00:00Z")!

    private func shot(daysAgo: Int, score: Int?, reference: UUID? = UUID()) -> CompletedShot {
        CompletedShot(id: UUID(), createdAt: now.addingTimeInterval(Double(-daysAgo) * 86_400),
                      photoFilename: "p", referenceFilename: "r", matchScore: score, referenceID: reference)
    }

    func testStreakCountsConsecutiveDaysEndingToday() {
        let shots = [shot(daysAgo: 0, score: 70), shot(daysAgo: 1, score: 72), shot(daysAgo: 2, score: 75),
                     shot(daysAgo: 5, score: 60)]
        let insights = ProfileInsights(shots: shots, savedPoses: 0, now: now, calendar: calendar)
        XCTAssertEqual(insights.currentStreak, 3)
        XCTAssertEqual(insights.longestStreak, 3)
    }

    func testStreakSurvivesUntilEndOfNextDay() {
        let insights = ProfileInsights(shots: [shot(daysAgo: 1, score: 70), shot(daysAgo: 2, score: 70)],
                                       savedPoses: 0, now: now, calendar: calendar)
        XCTAssertEqual(insights.currentStreak, 2)
    }

    func testBrokenStreakIsZero() {
        let insights = ProfileInsights(shots: [shot(daysAgo: 3, score: 70)], savedPoses: 0, now: now, calendar: calendar)
        XCTAssertEqual(insights.currentStreak, 0)
        XCTAssertEqual(insights.longestStreak, 1)
    }

    func testTrendComparesLastThreeWithThreeBefore() {
        let scores = [60, 62, 64, 80, 82, 84]
        let shots = scores.enumerated().map { shot(daysAgo: 10 - $0.offset, score: $0.element) }
        let insights = ProfileInsights(shots: shots, savedPoses: 0, now: now, calendar: calendar)
        XCTAssertEqual(insights.recentScores, scores)
        XCTAssertEqual(insights.trendDelta, 20)
        XCTAssertEqual(insights.trendHeadline, "Up 20 points lately")
    }

    func testPosesTriedCountsDistinctReferencesAndMilestones() {
        let reference = UUID()
        let shots = [shot(daysAgo: 0, score: 92, reference: reference), shot(daysAgo: 0, score: 86, reference: reference),
                     shot(daysAgo: 0, score: nil, reference: nil)]
        let insights = ProfileInsights(shots: shots, savedPoses: 10, now: now, calendar: calendar)
        XCTAssertEqual(insights.posesTried, 2)
        XCTAssertEqual(insights.bestMatch, 92)
        let earned = Set(insights.milestones.filter(\.isEarned).map(\.id))
        XCTAssertEqual(earned, ["first", "sharp", "curator"])
    }

    @MainActor func testLikesAndCommentsPersistOnShots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let store = ShootStore(folder: folder)
        let shot = try store.add(photo: image, reference: image)
        let fresh = store.shots[0]
        XCTAssertFalse(fresh.isLiked)

        try store.toggleLike(shot.id)
        let blank = try store.addComment("   ", author: "Nathan", to: shot.id)
        XCTAssertNil(blank)
        let added = try store.addComment("  nailed it  ", author: "Nathan", to: shot.id)
        let comment = try XCTUnwrap(added)
        try store.addComment("again", author: "Nathan", to: shot.id)

        let reopened = ShootStore(folder: folder)
        let saved = reopened.shots[0]
        XCTAssertTrue(saved.isLiked)
        XCTAssertEqual(saved.likeCount, 1)
        XCTAssertEqual(saved.commentList.map(\.text), ["nailed it", "again"])

        try reopened.removeComment(comment.id, from: shot.id)
        try reopened.toggleLike(shot.id)
        let edited = reopened.shots[0]
        XCTAssertFalse(edited.isLiked)
        XCTAssertEqual(edited.commentList.map(\.text), ["again"])
    }

    func testShotsSavedBeforeLikesStillDecode() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","createdAt":0,"photoFilename":"a.jpg","referenceFilename":"b.jpg"}]"#
        let shots = try JSONDecoder().decode([CompletedShot].self, from: Data(json.utf8))
        XCTAssertFalse(shots[0].isLiked)
        XCTAssertTrue(shots[0].commentList.isEmpty)
    }
}
