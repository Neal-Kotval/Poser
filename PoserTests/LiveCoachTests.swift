import XCTest
@testable import Poser

final class LiveCoachTests: XCTestCase {
    func testGuideSnapsToCenterAndKeepsItsScale() {
        let base = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.4)
        let result = PoseGuideSnapping.snap(.init(scale: 1.2, offset: CGSize(width: 0.19, height: 0.09)),
                                           base: base, viewport: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           threshold: CGSize(width: 0.02, height: 0.02))
        let box = result.placement.applying(to: base)
        XCTAssertEqual(box.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(box.midY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.placement.scale, 1.2)
        XCTAssertEqual(result.lines, .init(vertical: 0.5, horizontal: 0.5))
    }

    func testGuideSnapsOutlineEdgesToPreviewMargins() {
        let base = CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.3)
        let viewport = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        for (offset, edge) in [(CGFloat(-0.04), CGFloat(0.05)), (CGFloat(0.64), CGFloat(0.95))] {
            let result = PoseGuideSnapping.snap(.init(offset: CGSize(width: offset, height: 0.34)),
                                               base: base, viewport: viewport,
                                               threshold: CGSize(width: 0.02, height: 0.02))
            let box = result.placement.applying(to: base)
            XCTAssertEqual(offset < 0 ? box.minX : box.maxX, edge, accuracy: 0.0001)
            XCTAssertEqual(box.maxY, viewport.maxY, accuracy: 0.0001)
            XCTAssertEqual(result.lines.vertical ?? .nan, edge, accuracy: 0.0001)
            XCTAssertEqual(result.lines.horizontal, viewport.maxY)
        }
    }

    func testGuideSnapHasReleaseZoneAndAllowsFreeMovement() {
        let base = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        let viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        let threshold = CGSize(width: 0.02, height: 0.02)
        let near = PoseGuidePlacement(offset: CGSize(width: 0.03, height: 0.1))
        let free = PoseGuideSnapping.snap(near, base: base, viewport: viewport, threshold: threshold)
        XCTAssertEqual(free.placement, near)
        XCTAssertNil(free.lines.vertical)
        let retained = PoseGuideSnapping.snap(near, base: base, viewport: viewport, threshold: threshold,
                                              retaining: .init(vertical: 0.5))
        XCTAssertEqual(retained.placement.applying(to: base).midX, 0.5, accuracy: 0.0001)
        let far = PoseGuidePlacement(offset: CGSize(width: 0.05, height: 0.1))
        let released = PoseGuideSnapping.snap(far, base: base, viewport: viewport, threshold: threshold,
                                              retaining: .init(vertical: 0.5))
        XCTAssertEqual(released.placement, far)
        XCTAssertNil(released.lines.vertical)
    }

    func testGuidePlacementMovesAndScalesOutlineWithoutChangingItsShape() throws {
        let points = [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.6, y: 0.2),
                      CGPoint(x: 0.6, y: 0.8), CGPoint(x: 0.3, y: 0.8)]
        let placement = PoseGuidePlacement(scale: 1.5, offset: CGSize(width: 0.1, height: -0.05))
        let bounds = try XCTUnwrap(FrameMapping.boundingBox(of: placement.applying(to: points)))
        XCTAssertEqual(bounds.midX, 0.55, accuracy: 0.0001)
        XCTAssertEqual(bounds.midY, 0.45, accuracy: 0.0001)
        XCTAssertEqual(bounds.width, 0.45, accuracy: 0.0001)
        XCTAssertEqual(bounds.height, 0.9, accuracy: 0.0001)
        let constrained = PoseGuidePlacement(scale: 99, offset: CGSize(width: 20, height: -20))
            .constrained(baseBounds: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.6),
                         visibleBounds: CGRect(x: 0.2, y: 0, width: 0.6, height: 1))
        XCTAssertEqual(constrained.scale, 2.5)
        XCTAssertEqual(constrained.offset.width + 0.45, 0.8, accuracy: 0.0001)
        XCTAssertEqual(constrained.offset.height + 0.5, 0, accuracy: 0.0001)
    }

    func testGuideDragMappingAccountsForAspectFillCropping() {
        let size = CGSize(width: 393, height: 800)
        let point = CGPoint(x: 0.35, y: 0.6)
        let rendered = FrameMapping.viewPoint(point, frameAspect: 0.75, viewSize: size)
        let restored = FrameMapping.framePoint(rendered, frameAspect: 0.75, viewSize: size)
        XCTAssertEqual(restored.x, point.x, accuracy: 0.0001)
        XCTAssertEqual(restored.y, point.y, accuracy: 0.0001)
        let delta = FrameMapping.frameTranslation(CGSize(width: 60, height: -80), frameAspect: 0.75, viewSize: size)
        let moved = FrameMapping.viewPoint(CGPoint(x: point.x + delta.width, y: point.y + delta.height),
                                           frameAspect: 0.75, viewSize: size)
        XCTAssertEqual(moved.x - rendered.x, 60, accuracy: 0.0001)
        XCTAssertEqual(moved.y - rendered.y, -80, accuracy: 0.0001)
    }

    func testLiveOverlapAndCoachFramingFollowAdjustedGuide() throws {
        let outline = [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.6, y: 0.2),
                       CGPoint(x: 0.6, y: 0.8), CGPoint(x: 0.3, y: 0.8)]
        let placement = PoseGuidePlacement(scale: 0.8, offset: CGSize(width: 0.15, height: 0.04))
        let mapped = FrameMapping.mapOutline(outline, fromAspect: 0.75, intoAspect: 0.75)
        let live = placement.applying(to: mapped)
        let scores = CameraModel.scoreLivePose(referencePose: nil, livePose: nil,
                                               referenceOutline: outline, liveOutline: live,
                                               referenceAspect: 0.75, liveAspect: 0.75, focalRatio: 1,
                                               placement: placement)
        XCTAssertEqual(scores.frameOverlap, 100)
        let original = CameraModel.scoreLivePose(referencePose: nil, livePose: nil,
                                                referenceOutline: outline, liveOutline: live,
                                                referenceAspect: 0.75, liveAspect: 0.75, focalRatio: 1)
        XCTAssertLessThan(original.frameOverlap ?? 100, 100)
        let spec = ShotSpec(source: .fallback, subjectBox: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.6),
                            silhouette: outline, imageAspect: 0.75)
        let pose = PoseSkeleton(points: [
            .nose: CGPoint(x: 0.5, y: 0.1),
            .leftShoulder: CGPoint(x: 0.3, y: 0.25), .rightShoulder: CGPoint(x: 0.7, y: 0.25),
            .leftElbow: CGPoint(x: 0.2, y: 0.4), .rightElbow: CGPoint(x: 0.8, y: 0.4),
            .leftKnee: CGPoint(x: 0.4, y: 0.75), .rightKnee: CGPoint(x: 0.6, y: 0.75)
        ])
        let coach = LiveCoach(spec: spec, referencePose: pose, switchAfter: 1, guidePlacement: placement)
        let bounds = try XCTUnwrap(FrameMapping.boundingBox(of: live))
        XCTAssertEqual(coach.targetBox?.midX ?? 0, bounds.midX, accuracy: 0.0001)
        var reading = LiveReading()
        reading.subjectBox = bounds
        reading.pose = pose
        reading.silhouette = live
        reading.frameAspect = 0.75
        XCTAssertEqual(coach.update(reading: reading, pitchDegrees: 0, rollDegrees: 0).kind, .hold)
    }

    private let box = CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.8)
    private lazy var spec = ShotSpec(source: .pose3D, cameraHeightRatio: 0.3, distanceMeters: 2.0, pitchDegrees: 10,
                                     subjectYawDegrees: 0, subjectBox: box, subjectHeightMeters: 1.7, imageAspect: 0.75)

    func testLiveSubjectSelectionUsesReferencePositionInsteadOfFirstDetection() {
        let left = CGRect(x: 0.05, y: 0.15, width: 0.24, height: 0.65)
        let right = CGRect(x: 0.65, y: 0.15, width: 0.24, height: 0.65)
        XCTAssertEqual(LiveSubjectSelector.select(boxes: [left, right], targetX: 0.77, previousBox: nil), 1)
    }

    func testLiveSubjectSelectionStaysWithTrackedPerson() {
        let left = CGRect(x: 0.25, y: 0.15, width: 0.24, height: 0.65)
        let right = CGRect(x: 0.55, y: 0.15, width: 0.24, height: 0.65)
        XCTAssertEqual(LiveSubjectSelector.select(boxes: [left, right], targetX: 0.5,
                                                   previousBox: CGRect(x: 0.57, y: 0.15, width: 0.24, height: 0.65)), 1)
        XCTAssertNil(LiveSubjectSelector.select(boxes: [], targetX: 0.5, previousBox: nil))
    }

    private func reading(height: Double = 0.3, distance: Double = 2.0, yaw: Double = 0,
                         box: CGRect? = CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.8)) -> LiveReading {
        LiveReading(cameraHeightRatio: height, distanceMeters: distance, subjectYawDegrees: yaw,
                    visionPitchDegrees: 10, subjectBox: box)
    }

    private func instruction(for reading: LiveReading, pitch: Double = 10, roll: Double = 0) -> CoachInstruction {
        LiveCoach(spec: spec).update(reading: reading, pitchDegrees: pitch, rollDegrees: roll)
    }

    func testHoldsWhenEverythingMatches() {
        XCTAssertEqual(instruction(for: reading()).kind, .hold)
    }

    func testHeightComesBeforeApproximateDistance() {
        let result = instruction(for: reading(height: 0.8, distance: 3.0))
        XCTAssertEqual(result.kind, .lowerPhone)
        XCTAssertEqual(result.text, "Lower the phone to knee height")
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
        var live = reading()
        live.visionPitchDegrees = 0
        let result = instruction(for: live, pitch: 0)
        XCTAssertEqual(result.kind, .tiltUp)
        XCTAssertEqual(result.text, "Tilt the phone up ≈10°")
    }

    func testMotionPitchDoesNotReplaceMissingVisionPitch() {
        var live = reading()
        live.visionPitchDegrees = nil
        let result = instruction(for: live, pitch: 0)
        XCTAssertEqual(result.kind, .checkSetup)
    }

    func testUnknownReferencePitchDoesNotInventLevelTarget() {
        let reference = ShotSpec(source: .pose2D, distanceMeters: 2, subjectBox: box)
        let result = LiveCoach(spec: reference).update(reading: reading(), pitchDegrees: 15, rollDegrees: 0)
        XCTAssertEqual(result.kind, .hold)
    }

    func testMissingLiveDistanceDoesNotClaimMatch() {
        let reference = ShotSpec(source: .pose3D, distanceMeters: 2, subjectBox: box)
        let result = LiveCoach(spec: reference).update(reading: LiveReading(subjectBox: box),
                                                        pitchDegrees: 0, rollDegrees: 0)
        XCTAssertEqual(result.kind, .checkSetup)
    }

    func testVisionPitchIsComparedWithVisionPitch() {
        let live = LiveReading(visionPitchDegrees: 10, subjectBox: box)
        let reference = ShotSpec(source: .pose3D, pitchDegrees: 10, subjectBox: box)
        let result = LiveCoach(spec: reference).update(reading: live, pitchDegrees: 25, rollDegrees: 0)
        XCTAssertEqual(result.kind, .hold)
    }

    func testLevelWhenRolled() {
        XCTAssertEqual(instruction(for: reading(), roll: 6).kind, .level)
    }

    func testPanLeftWhenSubjectSitsTooFarLeft() {
        let shifted = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.8)
        XCTAssertEqual(instruction(for: reading(box: shifted)).kind, .panLeft)
    }

    func testVerticalOffsetDoesNotClaimMatch() {
        let shifted = CGRect(x: 0.35, y: 0.2, width: 0.3, height: 0.8)
        let result = instruction(for: reading(box: shifted))
        XCTAssertEqual(result.kind, .tiltDown)
        XCTAssertEqual(result.text, "Aim the phone slightly down")
    }

    func testFineFramingStepsBackWhenSubjectLooksTooBig() {
        let bigger = CGRect(x: 0.3, y: 0.02, width: 0.4, height: 0.96)
        let result = instruction(for: reading(box: bigger))
        XCTAssertEqual(result.kind, .stepBack)
        XCTAssertEqual(result.text, "Step back a little")
    }

    func testFramingComesBeforeApproximateDistance() {
        let shifted = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.8)
        let result = instruction(for: reading(distance: 3, box: shifted))
        XCTAssertEqual(result.kind, .panLeft)
    }

    func testMismatchedOutlineComesBeforeApproximateHeight() {
        let pose = PoseSkeleton(points: [
            .nose: CGPoint(x: 0.5, y: 0.1),
            .leftShoulder: CGPoint(x: 0.4, y: 0.25), .rightShoulder: CGPoint(x: 0.6, y: 0.25),
            .leftHip: CGPoint(x: 0.45, y: 0.6), .rightHip: CGPoint(x: 0.55, y: 0.6)
        ])
        let wide = [CGPoint(x: 0.35, y: 0.1), CGPoint(x: 0.65, y: 0.1),
                    CGPoint(x: 0.65, y: 0.9), CGPoint(x: 0.35, y: 0.9)]
        let narrow = [CGPoint(x: 0.35, y: 0.1), CGPoint(x: 0.65, y: 0.1),
                      CGPoint(x: 0.38, y: 0.9), CGPoint(x: 0.35, y: 0.9)]
        let reference = ShotSpec(source: .pose3D, cameraHeightRatio: 0.3,
                                 subjectBox: box, silhouette: wide, imageAspect: 0.75)
        let coach = LiveCoach(spec: reference, referencePose: pose)
        var live = LiveReading(cameraHeightRatio: 0.7, subjectBox: box, pose: pose)
        live.silhouette = narrow
        XCTAssertEqual(coach.update(reading: live, pitchDegrees: 0, rollDegrees: 0).kind, .adjustPose)
    }

    func testOldReadingCannotKeepClaimingMatch() {
        let coach = LiveCoach(spec: spec, switchAfter: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(coach.update(reading: reading(), pitchDegrees: 10, rollDegrees: 0, now: start).kind, .hold)
        XCTAssertEqual(coach.update(reading: nil, pitchDegrees: 10, rollDegrees: 0,
                                    now: start.addingTimeInterval(2)).kind, .findSubject)
    }

    func testMissingLiveOutlineCannotClaimMatch() {
        let outline = [CGPoint(x: 0.35, y: 0.1), CGPoint(x: 0.65, y: 0.1),
                       CGPoint(x: 0.65, y: 0.9), CGPoint(x: 0.35, y: 0.9)]
        let reference = ShotSpec(source: .pose2D, subjectBox: box, silhouette: outline)
        let coach = LiveCoach(spec: reference)
        XCTAssertEqual(coach.update(reading: LiveReading(subjectBox: box),
                                    pitchDegrees: 0, rollDegrees: 0).kind, .checkSetup)
    }

    func testLowOverlayOverlapCannotClaimMatchWhenBoxesAreClose() {
        let referenceOutline = [CGPoint(x: 0.35, y: 0.1), CGPoint(x: 0.65, y: 0.1),
                                CGPoint(x: 0.65, y: 0.9), CGPoint(x: 0.35, y: 0.9)]
        let liveOutline = referenceOutline.map { CGPoint(x: $0.x + 0.07, y: $0.y) }
        let reference = ShotSpec(source: .pose2D, subjectBox: box,
                                 silhouette: referenceOutline, imageAspect: 0.75)
        let coach = LiveCoach(spec: reference)
        var live = LiveReading(frameAspect: 0.75, subjectBox: CGRect(x: 0.42, y: 0.1, width: 0.3, height: 0.8))
        live.silhouette = liveOutline
        let result = coach.update(reading: live, pitchDegrees: 0, rollDegrees: 0)
        XCTAssertEqual(result.kind, .adjustPose)
        XCTAssertEqual(result.text, "Adjust your position to match the reference")
    }

    func testReferenceFramingUsesVisibleOutlineBounds() {
        let outline = [CGPoint(x: 0.2, y: 0.15), CGPoint(x: 0.8, y: 0.15),
                       CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0.2, y: 0.85)]
        let reference = ShotSpec(source: .pose2D, subjectBox: box, silhouette: outline,
                                 imageAspect: 0.75)
        let coach = LiveCoach(spec: reference)
        XCTAssertEqual(coach.targetBox?.minX ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(coach.targetBox?.width ?? -1, 0.6, accuracy: 0.001)
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

    func testTelephotoReferenceMapsToSmallerPhonePreviewTarget() {
        let mapped = FrameMapping.map(box, fromAspect: 0.75, intoAspect: 0.75, focalRatio: 0.5)
        XCTAssertEqual(mapped.midX, box.midX, accuracy: 0.001)
        XCTAssertEqual(mapped.height, box.height * 0.5, accuracy: 0.001)
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

    /// A landscape reference with the subject sitting far left must still map to an on-screen guide.
    func testOffCenterLandscapeOutlineStaysInsideVisiblePreview() {
        let outline = [CGPoint(x: 0.04, y: 0.45), CGPoint(x: 0.22, y: 0.45),
                       CGPoint(x: 0.22, y: 0.95), CGPoint(x: 0.04, y: 0.95)]
        for focalRatio in [CGFloat(1), 2] {
            let mapped = FrameMapping.mapOutline(outline, fromAspect: 4.0 / 3.0, intoAspect: 0.75,
                                                 focalRatio: focalRatio)
            for point in mapped {
                XCTAssertTrue(FrameMapping.visibleRegion.insetBy(dx: -0.001, dy: -0.001).contains(point),
                              "\(point) is outside the visible preview at focal ratio \(focalRatio)")
            }
        }
        let viewSize = CGSize(width: 393, height: 852)
        let spec = ShotSpec(source: .pose2D, silhouette: outline, imageAspect: 4.0 / 3.0)
        for point in FrameMapping.cutout(for: spec, viewSize: viewSize) {
            XCTAssertTrue((0...viewSize.width).contains(point.x), "drawn x \(point.x) is off screen")
        }
    }
}
