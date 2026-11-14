import XCTest
@testable import Poser

final class LiveCoachTests: XCTestCase {
    private let box = CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.8)
    private lazy var spec = ShotSpec(source: .pose3D, cameraHeightRatio: 0.3, distanceMeters: 2.0, pitchDegrees: 10,
                                     subjectYawDegrees: 0, subjectBox: box, subjectHeightMeters: 1.7, imageAspect: 0.75)

    private func reading(height: Double = 0.3, distance: Double = 2.0, yaw: Double = 0,
                         box: CGRect? = CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.8)) -> LiveReading {
        LiveReading(cameraHeightRatio: height, distanceMeters: distance, subjectYawDegrees: yaw, subjectBox: box)
    }

    private func instruction(for reading: LiveReading, pitch: Double = 10, roll: Double = 0) -> CoachInstruction {
        LiveCoach(spec: spec).update(reading: reading, pitchDegrees: pitch, rollDegrees: roll)
    }

    func testHoldsWhenEverythingMatches() {
        XCTAssertEqual(instruction(for: reading()).kind, .hold)
    }

    func testDistanceComesBeforeHeight() {
        let result = instruction(for: reading(height: 0.8, distance: 3.0))
        XCTAssertEqual(result.kind, .stepCloser)
        XCTAssertEqual(result.text, "Step ≈1 m closer")
    }

    func testLowerPhoneToTargetBucket() {
        let result = instruction(for: reading(height: 0.75))
        XCTAssertEqual(result.kind, .lowerPhone)
        XCTAssertEqual(result.targetHeight, .knee)
        XCTAssertEqual(result.text, "Lower the phone to knee height")
    }

    func testSmallHeightChangeWithinBucketUsesCentimeters() {
        let result = instruction(for: reading(height: 0.18))
        XCTAssertEqual(result.kind, .raisePhone)
        XCTAssertEqual(result.text, "Raise the phone ≈20 cm")
    }

    func testSubjectTurnsTowardTheirRightToPutCameraOnTheirLeft() {
        spec = ShotSpec(source: .pose3D, cameraHeightRatio: 0.3, distanceMeters: 2.0, pitchDegrees: 10,
                        subjectYawDegrees: 30, subjectBox: box, imageAspect: 0.75)
        let result = instruction(for: reading(yaw: 0))
        XCTAssertEqual(result.kind, .subjectTurnRight)
        XCTAssertEqual(result.text, "Ask them to turn ≈30° to their right")
    }

    func testAngleDifferenceWrapsAround() {
        XCTAssertEqual(LiveCoach.angleDifference(170, -170), -20, accuracy: 0.001)
        XCTAssertEqual(LiveCoach.angleDifference(-170, 170), 20, accuracy: 0.001)
    }

    func testTiltUpTowardReferencePitch() {
        let result = instruction(for: reading(), pitch: 0)
        XCTAssertEqual(result.kind, .tiltUp)
        XCTAssertEqual(result.text, "Tilt the phone up ≈10°")
    }

    func testLevelWhenRolled() {
        XCTAssertEqual(instruction(for: reading(), roll: 6).kind, .level)
    }

    func testPanLeftWhenSubjectSitsTooFarLeft() {
        let shifted = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.8)
        XCTAssertEqual(instruction(for: reading(box: shifted)).kind, .panLeft)
    }

    func testFineFramingStepsBackWhenSubjectLooksTooBig() {
        let bigger = CGRect(x: 0.3, y: 0.02, width: 0.4, height: 0.96)
        let result = instruction(for: reading(box: bigger))
        XCTAssertEqual(result.kind, .stepBack)
        XCTAssertEqual(result.text, "Step back a little")
    }

    func testInstructionNeedsSeveralFramesToChange() {
        let coach = LiveCoach(spec: spec)
        XCTAssertEqual(coach.update(reading: reading(), pitchDegrees: 10, rollDegrees: 0).kind, .hold)
        XCTAssertEqual(coach.update(reading: reading(box: nil), pitchDegrees: 10, rollDegrees: 0).kind, .hold)
        XCTAssertEqual(coach.update(reading: nil, pitchDegrees: 10, rollDegrees: 0).kind, .hold)
        XCTAssertEqual(coach.update(reading: nil, pitchDegrees: 10, rollDegrees: 0).kind, .findSubject)
    }

    func testTallReferenceFillsLiveFrameHeight() {
        let mapped = FrameMapping.map(CGPoint(x: 1, y: 0), fromAspect: 0.5625, intoAspect: 0.75)
        XCTAssertEqual(mapped.x, 0.875, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 0, accuracy: 0.001)
    }

    func testLandscapeReferenceShrinksInPortraitFrame() {
        let mapped = FrameMapping.map(CGPoint(x: 0.5, y: 0), fromAspect: 1.5, intoAspect: 0.75)
        XCTAssertEqual(mapped.y, 1.0 / 6.0, accuracy: 0.001)
    }

    func testViewPointUsesAspectFill() {
        let size = CGSize(width: 390, height: 844)
        let center = FrameMapping.viewPoint(CGPoint(x: 0.5, y: 0.5), frameAspect: 0.75, viewSize: size)
        let corner = FrameMapping.viewPoint(.zero, frameAspect: 0.75, viewSize: size)
        XCTAssertEqual(center.x, 195, accuracy: 0.01)
        XCTAssertEqual(center.y, 422, accuracy: 0.01)
        XCTAssertEqual(corner.x, -121.5, accuracy: 0.01)
        XCTAssertEqual(corner.y, 0, accuracy: 0.01)
    }
}
