import XCTest
import simd
@testable import Poser

final class ShotSpecTests: XCTestCase {
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
        XCTAssertTrue(geometry.inferredFromPose)
    }

    func testSubjectTurnIgnoresSmallYaw() {
        XCTAssertNil(ShotSpec(source: .pose3D, subjectYawDegrees: 10).subjectTurnDegrees)
        XCTAssertEqual(ShotSpec(source: .pose3D, subjectYawDegrees: 32).subjectTurnDegrees, 30)
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
