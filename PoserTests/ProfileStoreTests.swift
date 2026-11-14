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
