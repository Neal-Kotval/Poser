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
}
