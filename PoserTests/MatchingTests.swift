import XCTest
import UIKit
@testable import Poser

final class MatchingTests: XCTestCase {
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
        XCTAssertEqual(result?.comparedJoints, 5)
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

    func testGeometryEstimatorUsesVisibleBodyForDistanceAndHeight() {
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
        XCTAssertEqual(estimate.heightLabel, "Waist height")
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
            .rightWrist: CGPoint(x: 0.8, y: rightWristY)
        ])
    }
}
