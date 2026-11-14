import XCTest
import simd
import UIKit
@testable import Poser

final class ShotSpecTests: XCTestCase {
    func testBundledFullBodyReferenceProducesOutlineOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Person segmentation is unavailable in this simulator runtime")
        #else
        let reference = ReferenceCatalog.items[0]
        let image = try XCTUnwrap(reference.image)
        let estimate = await ShotSpecEstimator.estimate(image: image, imageData: reference.imageData)
        XCTAssertGreaterThan(estimate.spec.silhouette.count, 2, estimate.diagnostics.text)
        #endif
    }

    private let leftHip = SIMD3<Float>(0.1, 0, 0)
    private let rightHip = SIMD3<Float>(-0.1, 0, 0)
    private let leftAnkle = SIMD3<Float>(0.1, -0.8, 0)
    private let rightAnkle = SIMD3<Float>(-0.1, -0.8, 0)

    func testCaptureFrameKeepsLongSideOfTallCrop() {
        XCTAssertEqual(LensModel.captureFrame(containing: CGSize(width: 900, height: 1600)),
                       CGSize(width: 1200, height: 1600))
    }

    func testCroppedImageKeepsOriginalFocalLength() {
        let full = LensModel.focalLengthPixels(imageSize: CGSize(width: 3024, height: 4032), equivalentMM: 26)
        let square = LensModel.focalLengthPixels(imageSize: CGSize(width: 3024, height: 3024), equivalentMM: 26)
        XCTAssertEqual(full, 5040 * 26 / 43.27, accuracy: 0.5)
        XCTAssertEqual(square, full, accuracy: 0.5)
    }

    func testIntrinsicsRoundTrip() {
        let data = LensModel.intrinsicsData(width: 3024, height: 4032, focalPixels: 3028)
        XCTAssertEqual(LensModel.focalPixels(fromIntrinsics: data) ?? 0, 3028, accuracy: 0.01)
    }

    func testEyeLevelCameraInFrontOfSubject() {
        let placement = placement(camera: SIMD3(0, 0.62, 2.5))
        XCTAssertEqual(placement.heightRatio, 0.874, accuracy: 0.001)
        XCTAssertEqual(CameraHeightBucket(ratio: placement.heightRatio), .eye)
        XCTAssertEqual(placement.horizontalDistance, 2.5, accuracy: 0.001)
        XCTAssertEqual(placement.subjectYawDegrees, 0, accuracy: 0.01)
        XCTAssertEqual(placement.pitchDegrees, 0, accuracy: 0.01)
    }

    func testCrouchedCameraOnSubjectsLeft() {
        let placement = placement(camera: SIMD3(2, -0.4, 0))
        XCTAssertEqual(CameraHeightBucket(ratio: placement.heightRatio), .knee)
        XCTAssertEqual(placement.subjectYawDegrees, 90, accuracy: 0.01)
    }

    func testVisibleLongLegsSetTheGround() {
        let placement = placement(camera: SIMD3(0, 0, 2.5), ankleY: -1.0)
        XCTAssertEqual(placement.heightRatio, 1.081 / 1.8, accuracy: 0.001)
    }

    func testPitchComesFromCameraOrientation() {
        XCTAssertEqual(placement(camera: SIMD3(0, -0.5, 2.5), pitch: 12).pitchDegrees, 12, accuracy: 0.01)
        XCTAssertEqual(placement(camera: SIMD3(0, 0.5, 2.5), pitch: -8).pitchDegrees, -8, accuracy: 0.01)
    }

    func testCameraPoseInvertsCameraOriginMatrix() {
        let pose = cameraPose(position: SIMD3(0.3, 0.4, 2), pitch: 10)
        let recovered = BodyFrameGeometry.cameraPose(fromCameraOriginMatrix: pose.inverse)
        XCTAssertEqual(recovered.columns.3.z, 2, accuracy: 0.0001)
        XCTAssertEqual(recovered.columns.3.y, 0.4, accuracy: 0.0001)
    }

    func testPinholeDistance() {
        let distance = BodyFrameGeometry.pinholeDistance(focalPixels: 3028, subjectHeightMeters: 1.7,
                                                         visibleFraction: 0.955, spanPixels: 2016)
        XCTAssertEqual(distance ?? 0, 2.438, accuracy: 0.001)
    }

    func testFaceSizeProvidesApproximateDistanceForCroppedPortrait() {
        XCTAssertEqual(FaceDistanceEstimator.distance(focalPixels: 1000, imageWidth: 1000,
                                                      faceWidthFraction: 0.25) ?? 0,
                       0.64, accuracy: 0.001)
        XCTAssertNil(FaceDistanceEstimator.distance(focalPixels: 1000, imageWidth: 1000,
                                                    faceWidthFraction: 0.01))
    }

    func testCroppedReferenceStartsWithFaceDistanceAndAdjustableHeightAndTilt() {
        let setup = ReferenceStartingSetup(spec: ShotSpec(source: .fallback), faceDistanceMeters: 0.64)
        XCTAssertEqual(setup.distanceMeters, 0.64, accuracy: 0.001)
        XCTAssertEqual(setup.heightMeters, 1.5, accuracy: 0.001)
        XCTAssertEqual(setup.tiltDegrees, 0, accuracy: 0.001)
        XCTAssertTrue(setup.distanceFromFace)
    }

    func testCroppedLegsDoNotSupportCameraPlacement() {
        let cropped: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: 0.5, y: 0.1),
            .leftShoulder: CGPoint(x: 0.4, y: 0.2), .rightShoulder: CGPoint(x: 0.6, y: 0.2),
            .leftHip: CGPoint(x: 0.45, y: 0.6), .rightHip: CGPoint(x: 0.55, y: 0.6),
            .leftKnee: CGPoint(x: 0.45, y: 0.9), .rightKnee: CGPoint(x: 0.55, y: 0.9)
        ]
        XCTAssertFalse(Pose2DReader.hasFullBodyEvidence(cropped))
        var complete = cropped
        complete[.leftAnkle] = CGPoint(x: 0.44, y: 0.96)
        complete[.rightAnkle] = CGPoint(x: 0.56, y: 0.96)
        XCTAssertTrue(Pose2DReader.hasFullBodyEvidence(complete))
    }

    func testOneVisibleLegSupportsApproximateDistance() {
        let pose: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: 0.5, y: 0.12),
            .leftShoulder: CGPoint(x: 0.4, y: 0.25), .rightShoulder: CGPoint(x: 0.6, y: 0.25),
            .leftHip: CGPoint(x: 0.45, y: 0.54), .rightHip: CGPoint(x: 0.55, y: 0.54),
            .leftKnee: CGPoint(x: 0.44, y: 0.72), .leftAnkle: CGPoint(x: 0.43, y: 0.92)
        ]
        XCTAssertTrue(Pose2DReader.hasFullBodyEvidence(pose))
        XCTAssertTrue(Pose2DReader.hasUprightBodyEvidence(pose))
        XCTAssertEqual(Pose2DReader.noseToAnkle(pose) ?? 0, 0.8, accuracy: 0.001)
    }

    func testCroppedPortraitDoesNotClaim3DCameraGeometry() async throws {
        let portrait = try XCTUnwrap(UIImage(named: "InspirationPortrait"))
        let source = try XCTUnwrap(portrait.cgImage)
        let crop = CGRect(x: 0, y: 0, width: source.width, height: Int(Double(source.height) * 0.65))
        let croppedImage = UIImage(cgImage: try XCTUnwrap(source.cropping(to: crop)))
        let estimate = await ShotSpecEstimator.estimate(image: croppedImage)
        XCTAssertNotEqual(estimate.spec.source, .pose3D, estimate.diagnostics.text)
    }

    #if !targetEnvironment(simulator)
    func testBundledFullBodyReferenceProvidesCameraMeasurementsOnDevice() async throws {
        let portrait = try XCTUnwrap(UIImage(named: "InspirationPortrait"))
        let estimate = await ShotSpecEstimator.estimate(image: portrait)
        XCTAssertNotNil(estimate.spec.distanceMeters, estimate.diagnostics.text)
        XCTAssertNotNil(estimate.spec.cameraHeightRatio, estimate.diagnostics.text)
        XCTAssertNotNil(estimate.spec.pitchDegrees, estimate.diagnostics.text)
    }
    #endif

    func testSilhouetteSelectsPersonMatchedByPoseInsteadOfLongestContour() {
        let target = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.35, y: 0.1),
                      CGPoint(x: 0.35, y: 0.85), CGPoint(x: 0.1, y: 0.85)]
        let other = [CGPoint(x: 0.55, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                     CGPoint(x: 0.9, y: 0.85), CGPoint(x: 0.75, y: 0.85),
                     CGPoint(x: 0.55, y: 0.85)]
        let selected = ShotSpecEstimator.selectSilhouette(
            contours: [other, target], personBox: CGRect(x: 0.14, y: 0.18, width: 0.16, height: 0.56))
        XCTAssertEqual(selected, target)
    }

    func testSilhouetteRejectsUnassociatedOrAmbiguousPeople() {
        let left = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.35, y: 0.1),
                    CGPoint(x: 0.35, y: 0.8), CGPoint(x: 0.1, y: 0.8)]
        let right = left.map { CGPoint(x: $0.x + 0.5, y: $0.y) }
        XCTAssertTrue(ShotSpecEstimator.selectSilhouette(contours: [left, right], personBox: nil).isEmpty)
        XCTAssertTrue(ShotSpecEstimator.selectSilhouette(
            contours: [left, right], personBox: CGRect(x: 0.38, y: 0.2, width: 0.12, height: 0.4)).isEmpty)
    }

    func test2DAnd3DGeometryMustDescribeSamePerson() {
        let body = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.75)
        XCTAssertTrue(Pose2DReader.boxesLikelySamePerson(body,
            CGRect(x: 0.08, y: 0.08, width: 0.25, height: 0.8)))
        XCTAssertFalse(Pose2DReader.boxesLikelySamePerson(body,
            CGRect(x: 0.65, y: 0.1, width: 0.2, height: 0.75)))
    }

    func testContradictoryDistanceEstimatesAreRejected() {
        XCTAssertTrue(BodyFrameGeometry.distancesAgree(vision: 2, pinhole: 2.2))
        XCTAssertFalse(BodyFrameGeometry.distancesAgree(vision: 2, pinhole: 5))
    }

    func testDepthMeasuredHeightKeepsMetricCameraDistance() {
        XCTAssertEqual(BodyFrameGeometry.scale(bodyHeight: 1.9, heightIsMeasured: true,
                                               assumedHeight: 1.7) ?? 0, 1)
        XCTAssertEqual(BodyFrameGeometry.scale(bodyHeight: 1.8, heightIsMeasured: false,
                                               assumedHeight: 1.7) ?? 0, 1.7 / 1.8, accuracy: 0.0001)
        XCTAssertNil(BodyFrameGeometry.scale(bodyHeight: 0, heightIsMeasured: true,
                                             assumedHeight: 1.7))
    }

    func testImpossibleCameraPlacementIsRejected() {
        let invalid = CameraPlacement(heightRatio: -0.2, horizontalDistance: 2,
                                      subjectYawDegrees: 0, pitchDegrees: 0)
        XCTAssertFalse(BodyFrameGeometry.isPlausible(invalid))
    }

    func testDistanceLabelRoundsToHalfUnits() {
        XCTAssertEqual(ShotSpec.formatDistance(1.93), "≈2 m (6.5 ft)")
    }

    func testShotGeometryUsesRelativeHeightAndAbsoluteDistance() {
        let spec = ShotSpec(source: .pose3D, cameraHeightRatio: 0.3, distanceMeters: 2.1,
                            pitchDegrees: 8, subjectHeightMeters: 1.6)
        let geometry = spec.shotGeometry(fallback: ShotGeometryEstimator.fallback(for: ShotRecipe.presets[0]))
        XCTAssertEqual(geometry.cameraHeightMeters, 0.48, accuracy: 0.001)
        XCTAssertEqual(geometry.distanceMeters, 2.0)
        XCTAssertEqual(geometry.tiltDegrees, 10)
        XCTAssertEqual(geometry.heightLabel, "Knee height")
        XCTAssertEqual(geometry.adjustmentLabel, "Phone ≈0.5 m high\n(knee height)")
        XCTAssertTrue(geometry.inferredFromPose)
    }

    func test2DShotSpecDisplaysOnlyEstimatedDistance() {
        let spec = ShotSpec(source: .pose2D, distanceMeters: 2.1)
        let fallback = ShotGeometryEstimator.fallback(for: ShotRecipe.presets[0])
        let geometry = spec.shotGeometry(fallback: fallback)
        XCTAssertEqual(geometry.distanceLabel, "Stand ≈2 m (7 ft) away")
        XCTAssertEqual(geometry.adjustmentLabel, "Height not measured")
        XCTAssertEqual(geometry.angleLabel, "Match background lines")
        XCTAssertEqual(geometry.heightLabel, "Camera height unknown")
        XCTAssertNotNil(geometry.spec)
    }

    func testFallbackShotSpecKeepsOutlineWithoutInventingMeasurements() {
        let outline = [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.2),
                       CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.3, y: 0.8)]
        let spec = ShotSpec(source: .fallback, silhouette: outline)
        let geometry = spec.shotGeometry(fallback: ShotGeometryEstimator.fallback(for: ShotRecipe.presets[0]))
        XCTAssertEqual(geometry.spec?.silhouette, outline)
        XCTAssertNil(geometry.spec?.cameraHeightMeters)
        XCTAssertNil(geometry.spec?.distanceMeters)
        XCTAssertEqual(geometry.adjustmentLabel, "Height not measured")
    }

    func testSubjectTurnIgnoresSmallYaw() {
        XCTAssertNil(ShotSpec(source: .pose3D, subjectYawDegrees: 10).subjectTurnDegrees)
        XCTAssertEqual(ShotSpec(source: .pose3D, subjectYawDegrees: 32).subjectTurnDegrees, 30)
    }

    func testSetupDiagramTracksDistanceCameraHeightAndPitch() {
        let size = CGSize(width: 354, height: 430)
        func layout(distance: Double, height: Double, pitch: Int) -> ShotDiagramLayout {
            ShotDiagramLayout(size: size, geometry: ShotGeometry(
                cameraHeightMeters: height, distanceMeters: distance,
                tiltDegrees: pitch, inferredFromPose: true
            ))
        }

        let near = layout(distance: 1.5, height: 0.65, pitch: 10)
        let far = layout(distance: 3, height: 0.65, pitch: 10)
        XCTAssertGreaterThan(far.subjectX - far.photographerX,
                             near.subjectX - near.photographerX)

        let eyeLevel = layout(distance: 1.5, height: 1.55, pitch: 10)
        XCTAssertLessThan(eyeLevel.phonePoint.y, near.phonePoint.y)
        XCTAssertLessThan(near.aimPoint.y, near.phonePoint.y)

        let tiltDown = layout(distance: 1.5, height: 1.55, pitch: -10)
        XCTAssertGreaterThan(tiltDown.aimPoint.y, tiltDown.phonePoint.y)
        let drawnPitch = atan((eyeLevel.phonePoint.y - eyeLevel.aimPoint.y) /
                              (eyeLevel.aimPoint.x - eyeLevel.phonePoint.x)) * 180 / .pi
        XCTAssertEqual(drawnPitch, 10, accuracy: 0.001)
    }

    private func placement(camera: SIMD3<Float>, pitch: Float = 0, ankleY: Float = -0.8) -> CameraPlacement {
        BodyFrameGeometry.placement(cameraPose: cameraPose(position: camera, pitch: pitch),
                                    leftHip: leftHip, rightHip: rightHip,
                                    leftAnkle: SIMD3(leftAnkle.x, ankleY, leftAnkle.z),
                                    rightAnkle: SIMD3(rightAnkle.x, ankleY, rightAnkle.z),
                                    bodyHeight: 1.8)
    }

    /// A camera looking down -z, tilted up by `pitch` degrees.
    private func cameraPose(position: SIMD3<Float>, pitch: Float) -> simd_float4x4 {
        let angle = pitch * .pi / 180
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, cos(angle), sin(angle), 0),
            SIMD4(0, -sin(angle), cos(angle), 0),
            SIMD4(position.x, position.y, position.z, 1)
        ))
    }
}
