import XCTest
import UIKit
@testable import Poser

final class MatchingTests: XCTestCase {
    @MainActor
    func testReferenceLikesPersistWithoutChangingOtherPostsAndCanBeUndone() throws {
        let suite = "poser-likes-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReferenceLikeStore(defaults: defaults)
        XCTAssertFalse(store.isLiked("pin-a"))

        store.toggle("pin-a")
        let reloaded = ReferenceLikeStore(defaults: defaults)
        XCTAssertTrue(reloaded.isLiked("pin-a"))
        XCTAssertFalse(reloaded.isLiked("pin-b"))

        reloaded.toggle("pin-a")
        XCTAssertFalse(ReferenceLikeStore(defaults: defaults).isLiked("pin-a"))
        reloaded.toggle("pin-b")
        XCTAssertEqual(ReferenceLikeStore(defaults: defaults).likedIDs, ["pin-b"])
    }

    func testFeedImagesUseOriginalResolutionInsteadOfSmallThumbnails() throws {
        for reference in [ReferenceCatalog.items[0], ReferenceCatalog.items[407], ReferenceCatalog.items[815]] {
            let feed = try XCTUnwrap(reference.feedImage)
            let original = try XCTUnwrap(reference.image)
            let thumbnail = try XCTUnwrap(reference.preview)
            XCTAssertEqual(feed.size.width * feed.scale, original.size.width * original.scale)
            XCTAssertEqual(feed.size.height * feed.scale, original.size.height * original.scale)
            XCTAssertGreaterThan(max(feed.size.width, feed.size.height) * feed.scale,
                                 max(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale)
        }
    }

    func testInteriorHorizontalScrollingCannotTurnPagesEvenWithALongDrag() {
        for x in [CGFloat(50), 196, 340] {
            XCTAssertFalse(HomePaging.allowsSwipe(start: CGPoint(x: x, y: 300),
                                                 translation: CGSize(width: -250, height: 0),
                                                 excluding: .null, viewportWidth: 393))
        }
    }

    func testPageNavigationRequiresInwardEdgeDragAndDeliberateDistance() {
        XCTAssertTrue(HomePaging.allowsSwipe(start: CGPoint(x: 385, y: 400),
                                            translation: CGSize(width: -140, height: 12),
                                            excluding: .null, viewportWidth: 393))
        XCTAssertTrue(HomePaging.allowsSwipe(start: CGPoint(x: 8, y: 400),
                                            translation: CGSize(width: 140, height: 12),
                                            excluding: .null, viewportWidth: 393))
        XCTAssertFalse(HomePaging.allowsSwipe(start: CGPoint(x: 8, y: 400),
                                             translation: CGSize(width: -140, height: 0),
                                             excluding: .null, viewportWidth: 393))
        XCTAssertNil(HomePaging.pageStep(translation: CGSize(width: -55, height: 0), viewportWidth: 393))
        XCTAssertNil(HomePaging.pageStep(translation: CGSize(width: -140, height: 100), viewportWidth: 393))
        XCTAssertEqual(HomePaging.pageStep(translation: CGSize(width: -140, height: 12), viewportWidth: 393), 1)
        XCTAssertEqual(HomePaging.pageStep(translation: CGSize(width: 140, height: 12), viewportWidth: 393), -1)
    }

    func testHorizontalControlHasProtectedMarginsEvenInsidePageSwipeEdge() {
        let control = CGRect(x: 24, y: 200, width: 345, height: 150)
        XCTAssertFalse(HomePaging.allowsSwipe(start: CGPoint(x: 382, y: 195),
                                             translation: CGSize(width: -200, height: 0),
                                             excluding: control, viewportWidth: 393))
    }

    func testReferenceSearchMatchesMultipleWordsRegardlessOfCaseAndSpacing() {
        let results = ReferenceCatalog.items(matching: nil, query: "  STREET   walking ")
        let expected = ReferenceCatalog.items.filter { $0.setting == "street" && $0.pose == "walking" }
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.map(\.id), expected.map(\.id))
    }

    func testReferenceSearchCombinesCategoryAndText() {
        let street = ReferenceTag(kind: .setting, value: "street")
        let results = ReferenceCatalog.items(matching: street, query: "walking")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.setting == "street" && $0.pose == "walking" })
        XCTAssertTrue(ReferenceCatalog.items(matching: street, query: "beach").isEmpty)
    }

    func testReferenceSearchHandlesAccentsResetAndNoMatches() {
        XCTAssertEqual(ReferenceCatalog.items(matching: nil, query: "CAFÉ").map(\.id),
                       ReferenceCatalog.items.filter { $0.setting == "cafe" }.map(\.id))
        XCTAssertEqual(ReferenceCatalog.items(matching: nil, query: " \n ").map(\.id),
                       ReferenceCatalog.items.map(\.id))
        XCTAssertTrue(ReferenceCatalog.items(matching: nil, query: "zzznomatch").isEmpty)
    }

    func testFilterBarDragsNeverPageEvenWhenDraggedOutsideTheBar() {
        let bar = CGRect(x: 24, y: 220, width: 340, height: 44)
        for translation in [CGSize(width: -250, height: 5), CGSize(width: 250, height: 100)] {
            XCTAssertFalse(HomePaging.allowsSwipe(start: CGPoint(x: 100, y: 240),
                                                 translation: translation, excluding: bar))
        }
    }

    func testPageSwipeOutsideFiltersRequiresHorizontalMovement() {
        let bar = CGRect(x: 24, y: 220, width: 340, height: 44)
        XCTAssertTrue(HomePaging.allowsSwipe(start: CGPoint(x: 200, y: 400),
                                            translation: CGSize(width: -100, height: 10), excluding: bar))
        XCTAssertFalse(HomePaging.allowsSwipe(start: CGPoint(x: 200, y: 400),
                                             translation: CGSize(width: 10, height: -100), excluding: bar))
        XCTAssertTrue(HomePaging.allowsSwipe(start: CGPoint(x: 200, y: 240),
                                            translation: CGSize(width: 100, height: 0), excluding: .null))
    }

    func testReferenceTagsFilterBySettingAndPose() {
        XCTAssertFalse(ReferenceCatalog.tags.isEmpty)
        XCTAssertEqual(Set(ReferenceCatalog.tags.map(\.id)).count, ReferenceCatalog.tags.count)
        for tag in ReferenceCatalog.tags {
            let matches = ReferenceCatalog.items(matching: tag)
            XCTAssertFalse(matches.isEmpty, "Empty tag: \(tag.id)")
            let expected = ReferenceCatalog.items.filter {
                tag.kind == .setting ? $0.setting == tag.value : $0.pose == tag.value
            }
            XCTAssertEqual(matches.map(\.id), expected.map(\.id))
            XCTAssertLessThan(matches.count, ReferenceCatalog.items.count)
        }
    }

    func testAllReferenceTagRestoresOriginalFeedOrder() {
        _ = ReferenceCatalog.items(matching: ReferenceTag(kind: .setting, value: "street"))
        XCTAssertEqual(ReferenceCatalog.items(matching: nil).map(\.id), ReferenceCatalog.items.map(\.id))
        XCTAssertTrue(ReferenceCatalog.items(matching: ReferenceTag(kind: .pose, value: "missing")).isEmpty)
    }

    func testSceneMatcherPrefersSameSceneOverContrastingColor() async {
        let scene = solidImage(.systemGreen)
        let matchingID = UUID()
        let contrastingID = UUID()
        let matches = await SceneMatcher.rank(
            scene: scene,
            candidates: [
                SceneCandidate(id: contrastingID, image: solidImage(.systemPink)),
                SceneCandidate(id: matchingID, image: scene)
            ]
        )

        XCTAssertEqual(matches.map(\.id), [matchingID, contrastingID])
        XCTAssertGreaterThan(matches[0].score, matches[1].score)
        XCTAssertTrue(matches.allSatisfy { (0...1).contains($0.score) })
    }

    func testSceneMatcherReturnsNoResultsForEmptyLibrary() async {
        let matches = await SceneMatcher.rank(scene: solidImage(.gray), candidates: [])
        XCTAssertTrue(matches.isEmpty)
    }

    func testBundledPinterestReferencesLoad() {
        XCTAssertEqual(ReferenceCatalog.items.count, 816)
        for reference in ReferenceCatalog.items {
            XCTAssertNotNil(reference.preview, "Missing preview for \(reference.assetName)")
            XCTAssertEqual(reference.source?.host, "www.pinterest.com")
            XCTAssertEqual(reference.license, "Rights unverified")
        }
        for reference in [ReferenceCatalog.items[0], ReferenceCatalog.items[407], ReferenceCatalog.items[815]] {
            XCTAssertNotNil(reference.image, "Missing full image for \(reference.assetName)")
            XCTAssertNotNil(reference.imageData, "Missing original bytes for \(reference.assetName)")
        }
    }

    func testSceneMatcherHonorsCameraImageOrientation() async {
        let original = asymmetricImage()
        let rotated = UIImage(cgImage: original.cgImage!, scale: 1, orientation: .right)
        let upright = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { _ in
            rotated.draw(in: CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        let uprightID = UUID()
        let unrotatedID = UUID()
        let matches = await SceneMatcher.rank(
            scene: rotated,
            candidates: [
                SceneCandidate(id: unrotatedID, image: original),
                SceneCandidate(id: uprightID, image: upright)
            ]
        )
        XCTAssertEqual(matches.first?.id, uprightID)
    }

    func testPoseMatcherGivesPerfectScoreToSameJoints() {
        let pose = fiveJointPose(rightWristY: 0.3)
        let result = PoseMatcher.compare(reference: pose, live: pose)

        XCTAssertEqual(result?.score, 100)
        XCTAssertEqual(result?.comparedJoints, 6)
        XCTAssertEqual(result?.cue, "Pose is close to the reference")
    }

    func testPoseMatcherTellsSubjectToRaiseLowRightArm() {
        let reference = fiveJointPose(rightWristY: 0.3)
        let live = fiveJointPose(rightWristY: 0.75)
        let result = PoseMatcher.compare(reference: reference, live: live)

        XCTAssertNotNil(result)
        XCTAssertLessThan(result!.score, 85)
        XCTAssertEqual(result?.cue, "Raise your right arm")
    }

    func testPoseMatcherNeedsAtLeastFiveSharedJoints() {
        let reference = fiveJointPose(rightWristY: 0.3)
        let incomplete = PoseSkeleton(points: [
            .leftShoulder: CGPoint(x: 0.3, y: 0.2),
            .rightShoulder: CGPoint(x: 0.7, y: 0.2),
            .leftHip: CGPoint(x: 0.4, y: 0.6),
            .rightHip: CGPoint(x: 0.6, y: 0.6)
        ])
        XCTAssertNil(PoseMatcher.compare(reference: reference, live: incomplete))
    }

    func testJointOnlyScoreNeedsAnArmAndLeg() {
        let torsoOnly = PoseSkeleton(points: [
            .nose: CGPoint(x: 0.5, y: 0.1),
            .leftShoulder: CGPoint(x: 0.3, y: 0.2), .rightShoulder: CGPoint(x: 0.7, y: 0.2),
            .leftHip: CGPoint(x: 0.4, y: 0.6), .rightHip: CGPoint(x: 0.6, y: 0.6)
        ])
        XCTAssertNil(PoseMatcher.compare(reference: torsoOnly, live: torsoOnly))

        let armOnly = fiveJointPose(rightWristY: 0.3)
        let noLeg = PoseSkeleton(points: armOnly.points.filter { $0.key != .leftKnee })
        XCTAssertNil(PoseMatcher.compare(reference: noLeg, live: noLeg))
    }

    func testOutlineContributesToPoseScore() {
        let pose = fiveJointPose(rightWristY: 0.3)
        let full = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                    CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]
        let narrow = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                      CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.1, y: 0.9)]

        let score = PoseMatcher.compare(reference: pose, live: pose,
                                        referenceOutline: full, liveOutline: narrow)
        XCTAssertNotNil(score)
        XCTAssertLessThan(score!.score, 85, "Matching joints should not hide a mismatched outline")
        XCTAssertEqual(PoseMatcher.compare(reference: pose, live: pose,
                                           referenceOutline: full, liveOutline: full)?.score, 100)
        XCTAssertEqual(score?.cue, "Match your outline to the guide")
    }

    func testMatchingOutlineCannotHideWrongArm() {
        let reference = fiveJointPose(rightWristY: 0.3)
        let live = fiveJointPose(rightWristY: 0.75)
        let outline = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                       CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]
        let result = PoseMatcher.compare(reference: reference, live: live,
                                         referenceOutline: outline, liveOutline: outline)
        XCTAssertLessThan(result!.score, 85)
        XCTAssertEqual(result?.cue, "Raise your right arm")
    }

    func testOutlineRejectsInvalidOrTinyContours() {
        let full = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                    CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]
        let tiny = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.11, y: 0.1),
                    CGPoint(x: 0.11, y: 0.11), CGPoint(x: 0.1, y: 0.11)]
        let invalid = [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertNil(SilhouetteMatcher.score(reference: full, live: tiny))
        XCTAssertNil(SilhouetteMatcher.score(reference: full, live: invalid))
    }

    func testOutlineWithoutJointsCannotProducePoseScore() {
        let reference = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.1),
                         CGPoint(x: 0.4, y: 0.8), CGPoint(x: 0.1, y: 0.8)]
        let shifted = reference.map { CGPoint(x: $0.x + 0.4, y: $0.y) }

        XCTAssertNil(PoseMatcher.compare(reference: nil, live: nil,
                                         referenceOutline: reference, liveOutline: shifted))
        XCTAssertEqual(SilhouetteMatcher.frameOverlap(reference: reference, live: shifted), 0)
        XCTAssertEqual(SilhouetteMatcher.frameOverlap(reference: reference, live: reference), 100)
    }

    func testLiveScoreUsesPoseShapeRatherThanFramePosition() {
        let reference = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.1),
                         CGPoint(x: 0.4, y: 0.8), CGPoint(x: 0.1, y: 0.8)]
        let shifted = reference.map { CGPoint(x: $0.x + 0.4, y: $0.y) }
        let result = CameraModel.scoreLivePose(referencePose: nil, livePose: nil,
                                               referenceOutline: reference, liveOutline: shifted,
                                               referenceAspect: 0.75, liveAspect: 0.75,
                                               focalRatio: 1)

        XCTAssertNil(result.pose)
        XCTAssertEqual(result.frameOverlap, 0)
    }

    @MainActor
    func testImportedInspirationPersistsAcrossStoreReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = InspirationStore(folder: folder)
        let saved = try store.add(solidImage(.systemGreen), source: .photoLibrary)
        let reopened = InspirationStore(folder: folder)

        XCTAssertEqual(reopened.items, [saved])
        XCTAssertNotNil(reopened.image(for: saved))
    }

    @MainActor
    func testDeletingImportedReferenceRemovesOriginalAndIndexEntry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = solidImage(.systemGreen)
        let original = try XCTUnwrap(image.pngData())
        let store = InspirationStore(folder: folder)
        let item = try store.add(image, source: .photoLibrary, originalData: original)

        try store.remove(item)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.image(for: item))
        XCTAssertNil(store.originalData(for: item))
        XCTAssertTrue(InspirationStore(folder: folder).items.isEmpty)
    }

    @MainActor
    func testBulkDeletionPreservesUnselectedReferencesAndSurvivesReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = solidImage(.systemGreen)
        let original = try XCTUnwrap(image.pngData())
        let store = InspirationStore(folder: folder)
        let first = try store.add(image, source: .photoLibrary, originalData: original)
        let retained = try store.add(image, source: .photoLibrary, originalData: original)
        let last = try store.add(image, source: .photoLibrary, originalData: original)

        try store.remove(ids: [first.id, last.id, UUID()])

        let reopened = InspirationStore(folder: folder)
        XCTAssertEqual(reopened.items, [retained])
        XCTAssertNotNil(reopened.image(for: retained))
        XCTAssertEqual(reopened.originalData(for: retained), original)
        for deleted in [first, last] {
            XCTAssertNil(reopened.image(for: deleted))
            XCTAssertNil(reopened.originalData(for: deleted))
        }
        try store.remove(ids: [])
        try store.remove(ids: [first.id])
        XCTAssertEqual(store.items, [retained])
    }

    @MainActor
    func testBulkDeletionDoesNotRemovePhotosIfIndexCannotBeWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = InspirationStore(folder: folder)
        let first = try store.add(solidImage(.systemGreen), source: .photoLibrary)
        let second = try store.add(solidImage(.systemBlue), source: .photoLibrary)
        let index = folder.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.remove(ids: [first.id, second.id]))
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        XCTAssertNotNil(store.image(for: first))
        XCTAssertNotNil(store.image(for: second))
    }

    @MainActor
    func testOriginalReferenceDataSurvivesLibraryReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = solidImage(.systemGreen)
        let original = try XCTUnwrap(image.pngData())

        let saved = try InspirationStore(folder: folder).add(image, source: .photoLibrary, originalData: original)
        let reopened = InspirationStore(folder: folder)

        XCTAssertEqual(reopened.originalData(for: saved), original)
        XCTAssertNotNil(reopened.image(for: saved))
    }

    func test2DFramingDoesNotClaimLowCameraHeight() {
        let points: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: 0.5, y: 0.1),
            .leftShoulder: CGPoint(x: 0.4, y: 0.24), .rightShoulder: CGPoint(x: 0.6, y: 0.24),
            .leftHip: CGPoint(x: 0.44, y: 0.55), .rightHip: CGPoint(x: 0.56, y: 0.55),
            .leftAnkle: CGPoint(x: 0.44, y: 0.9), .rightAnkle: CGPoint(x: 0.56, y: 0.9)
        ]
        let estimate = ShotGeometryEstimator.estimate(points: points, recipe: ShotRecipe.presets[0])

        XCTAssertTrue(estimate.inferredFromPose)
        XCTAssertGreaterThan(estimate.distanceMeters, 1)
        XCTAssertLessThan(estimate.distanceMeters, 3)
        XCTAssertEqual(estimate.cameraHeightMeters, 1.5)
        XCTAssertEqual(estimate.heightLabel, "Camera height unknown")
    }

    func testCroppedPoseDoesNotInventCameraMeasurements() {
        let points: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: 0.5, y: 0.2),
            .leftShoulder: CGPoint(x: 0.4, y: 0.3), .rightShoulder: CGPoint(x: 0.6, y: 0.3),
            .leftHip: CGPoint(x: 0.43, y: 0.8), .rightHip: CGPoint(x: 0.57, y: 0.8)
        ]
        let estimate = ShotGeometryEstimator.estimate(points: points, recipe: ShotRecipe.presets[0])
        XCTAssertFalse(estimate.inferredFromPose)
        XCTAssertEqual(estimate.distanceLabel, "Move until framing matches")
        XCTAssertEqual(estimate.angleLabel, "Match background lines")
    }

    func testPoseNormalizationPreservesBodyProportionsAndMissingJoints() {
        let raw: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: 0.5, y: 0.1), .neck: CGPoint(x: 0.5, y: 0.2),
            .leftShoulder: CGPoint(x: 0.4, y: 0.25), .rightShoulder: CGPoint(x: 0.6, y: 0.25),
            .leftHip: CGPoint(x: 0.45, y: 0.6), .rightHip: CGPoint(x: 0.55, y: 0.6),
            .leftAnkle: CGPoint(x: 0.45, y: 0.9)
        ]
        let pose = PoseSkeleton.normalized(raw)
        XCTAssertNotNil(pose)
        XCTAssertNil(pose?[.rightAnkle])
        let shoulderWidth = pose![.rightShoulder]!.x - pose![.leftShoulder]!.x
        let bodyHeight = pose![.leftAnkle]!.y - pose![.nose]!.y
        XCTAssertEqual(shoulderWidth / bodyHeight, 0.25, accuracy: 0.001)
    }

    func testDiagramFillsMissingJointsWithoutChangingDetectedPose() {
        let detected = PoseSkeleton(points: [
            .nose: CGPoint(x: 0.52, y: 0.12),
            .leftShoulder: CGPoint(x: 0.38, y: 0.28),
            .rightShoulder: CGPoint(x: 0.62, y: 0.28),
            .leftHip: CGPoint(x: 0.44, y: 0.56),
            .rightHip: CGPoint(x: 0.58, y: 0.56),
            .leftKnee: CGPoint(x: 0.42, y: 0.75)
        ])

        let diagram = detected.displayingMissingJoints()

        XCTAssertEqual(diagram.points.count, PoseJoint.allCases.count)
        XCTAssertEqual(diagram[.nose], detected[.nose])
        XCTAssertEqual(diagram[.leftKnee], detected[.leftKnee])
        XCTAssertNil(detected[.leftWrist])
        XCTAssertNotNil(diagram[.leftWrist])
        XCTAssertNotNil(diagram[.rightAnkle])
    }

    func testDiagramContainsImplausibleWristWithoutChangingScoringPose() {
        let detected = PoseSkeleton(points: [
            .leftShoulder: CGPoint(x: 0.38, y: 0.28),
            .rightShoulder: CGPoint(x: 0.62, y: 0.28),
            .leftWrist: CGPoint(x: 1.4, y: -0.5)
        ])
        let diagram = detected.displayingMissingJoints()
        XCTAssertEqual(detected[.leftWrist], CGPoint(x: 1.4, y: -0.5))
        XCTAssertLessThan(diagram[.leftWrist]!.x, 0.8)
        XCTAssertGreaterThan(diagram[.leftWrist]!.y, 0)
    }

    @MainActor
    func testCompletedShotPersistsWithPhotoAndReference() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ShootStore(folder: folder)
        let shot = try store.add(photo: solidImage(.systemGreen), reference: solidImage(.systemPink))
        let reopened = ShootStore(folder: folder)

        XCTAssertEqual(reopened.shots, [shot])
        XCTAssertNotNil(reopened.photo(for: shot))
        XCTAssertNotNil(reopened.reference(for: shot))
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
    }

    private func asymmetricImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 60, y: 0, width: 60, height: 60))
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 60, width: 60, height: 60))
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 60, y: 60, width: 60, height: 60))
        }
    }

    private func fiveJointPose(rightWristY: CGFloat) -> PoseSkeleton {
        PoseSkeleton(points: [
            .leftShoulder: CGPoint(x: 0.3, y: 0.2),
            .rightShoulder: CGPoint(x: 0.7, y: 0.2),
            .leftHip: CGPoint(x: 0.4, y: 0.6),
            .rightHip: CGPoint(x: 0.6, y: 0.6),
            .rightWrist: CGPoint(x: 0.8, y: rightWristY),
            .leftKnee: CGPoint(x: 0.42, y: 0.75)
        ])
    }
}
