import AVFoundation
import CoreGraphics
import Foundation
import Vision
import simd

/// What the live camera currently sees, in the same terms as `ShotSpec`.
struct LiveReading {
    /// Width divided by height after applying the video orientation.
    var frameAspect: CGFloat?
    var cameraHeightRatio: Double?
    var distanceMeters: Double?
    var subjectYawDegrees: Double?
    var visionPitchDegrees: Double?
    /// Normalized to the live frame, top-left origin.
    var subjectBox: CGRect?
    var pose: PoseSkeleton?
    var silhouette: [CGPoint] = []
    /// Present when LiDAR depth let Vision measure the subject instead of assuming 1.8 m.
    var measuredSubjectHeight: Double?
}

final class LiveFrameAnalyzer {
    #if DEBUG
    private static var lastFailureReport: String?
    #endif
    let subjectHeightMeters: Double
    let minimumInterval: TimeInterval
    private var lastRun = Date.distantPast

    init(subjectHeightMeters: Double = ShotSpecEstimator.defaultSubjectHeight, minimumInterval: TimeInterval = 0.25) {
        self.subjectHeightMeters = subjectHeightMeters
        self.minimumInterval = minimumInterval
    }

    /// Returns nil when throttled. Enable `isCameraIntrinsicMatrixDeliveryEnabled` on the video
    /// connection so distances use the real lens instead of an assumed one.
    func analyze(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation = .right) -> LiveReading? {
        let now = Date()
        guard now.timeIntervalSince(lastRun) >= minimumInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        lastRun = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frameSize = orientation.swapsDimensions ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let delivered = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                        attachmentModeOut: nil) as? Data
        let focalPixels = delivered.flatMap(LensModel.focalPixels(fromIntrinsics:))
            ?? LensModel.focalLengthPixels(imageSize: frameSize, equivalentMM: LensModel.phoneMainEquivalentMM)
        let intrinsics = LensModel.intrinsicsData(width: width, height: height, focalPixels: focalPixels)
        // Keep the sample buffer's camera metadata when the device supplies it. Vision can use
        // the delivered intrinsics and any depth attachment directly.
        let options: [VNImageOption: Any] = delivered == nil ? [.cameraIntrinsics: intrinsics as CFData] : [:]
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation, options: options)
        return Self.reading(using: handler, frameSize: frameSize, focalPixels: focalPixels,
                            subjectHeightMeters: subjectHeightMeters)
    }

    static func reading(using handler: VNImageRequestHandler, frameSize: CGSize, focalPixels: Double,
                        subjectHeightMeters: Double) -> LiveReading {
        let pose2D = VNDetectHumanBodyPoseRequest()
        let pose3D = VNDetectHumanBodyPose3DRequest()
        let failures = [("2D pose", VisionRunner.perform(pose2D, on: handler)),
                        ("3D pose", VisionRunner.perform(pose3D, on: handler))]
            .compactMap { name, error in error.map { "\(name): \($0)" } }
        #if DEBUG
        let report = failures.joined(separator: " | ")
        if report != lastFailureReport {
            lastFailureReport = report
            print(report.isEmpty ? "[LiveCoach] Vision requests ok" : "[LiveCoach] Vision failed: \(report)")
        }
        #endif

        var reading = LiveReading()
        reading.frameAspect = frameSize.width / max(frameSize.height, 1)
        let observation2D = pose2D.results?.first
        let points = observation2D.map(Pose2DReader.points) ?? [:]
        reading.subjectBox = Pose2DReader.box(points)
        reading.pose = observation2D.flatMap(PoseSkeleton.detected)
        if observation2D != nil {
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .balanced
            segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? handler.perform([segmentation])
            reading.silhouette = segmentation.results?.first.map {
                ShotSpecEstimator.silhouettePoints(mask: $0.pixelBuffer, personBox: reading.subjectBox)
            } ?? []
            // Both framing boxes now describe the visible outline when it is available.
            // Joint boxes omit hair, clothes, and hands outside the detected skeleton.
            reading.subjectBox = FrameMapping.boundingBox(of: reading.silhouette) ?? reading.subjectBox
        }
        if let span = Pose2DReader.noseToAnkle(points) {
            reading.distanceMeters = BodyFrameGeometry.pinholeDistance(
                focalPixels: focalPixels, subjectHeightMeters: subjectHeightMeters,
                visibleFraction: Pose2DReader.noseToAnkleFraction, spanPixels: Double(span * frameSize.height))
        }

        if let body = pose3D.results?.first, Pose2DReader.hasFullBodyEvidence(points),
           let personBox = Pose2DReader.box(points),
           let projected = Pose3DReader.subjectBox(body),
           Pose2DReader.boxesLikelySamePerson(personBox, projected.box),
           Pose3DReader.isUsable(body), let placement = Pose3DReader.placement(body),
           BodyFrameGeometry.isPlausible(placement),
           let scale = BodyFrameGeometry.scale(bodyHeight: Double(body.bodyHeight),
                                                heightIsMeasured: body.heightEstimation == .measured,
                                                assumedHeight: subjectHeightMeters) {
            let measured = body.heightEstimation == .measured
            let height = Double(body.bodyHeight)
            // Match the reference estimator: retain true meters when depth measured height,
            // otherwise scale Vision's arbitrary body frame to the assumed subject height.
            let distance = placement.horizontalDistance * scale
            if distance.isFinite, (0.3...20).contains(distance) {
                reading.cameraHeightRatio = placement.heightRatio
                reading.distanceMeters = distance
                reading.subjectYawDegrees = placement.subjectYawDegrees
                reading.visionPitchDegrees = placement.pitchDegrees
                if measured { reading.measuredSubjectHeight = height }
            }
        }
        return reading
    }
}

struct CoachInstruction: Equatable {
    enum Kind: String, Equatable {
        case findSubject, stepBack, stepCloser, raisePhone, lowerPhone, subjectTurnRight, subjectTurnLeft
        case tiltUp, tiltDown, level, panLeft, panRight, adjustPose, checkSetup, hold
    }

    let kind: Kind
    let text: String
    let symbol: String
    /// Meters for steps, degrees for turns and tilts, centimeters for height changes.
    let amount: Double?
    let targetHeight: CameraHeightBucket?

    init(_ kind: Kind, _ text: String, symbol: String, amount: Double? = nil, targetHeight: CameraHeightBucket? = nil) {
        self.kind = kind
        self.text = text
        self.symbol = symbol
        self.amount = amount
        self.targetHeight = targetHeight
    }

    static let findSubject = CoachInstruction(.findSubject, "Get your subject in the frame", symbol: "person.crop.rectangle")
    static let level = CoachInstruction(.level, "Straighten the phone", symbol: "level")
    static let panLeft = CoachInstruction(.panLeft, "Turn the phone slightly left", symbol: "arrow.left")
    static let panRight = CoachInstruction(.panRight, "Turn the phone slightly right", symbol: "arrow.right")
    static let aimUp = CoachInstruction(.tiltUp, "Aim the phone slightly up", symbol: "arrow.up")
    static let aimDown = CoachInstruction(.tiltDown, "Aim the phone slightly down", symbol: "arrow.down")
    static let checkSetup = CoachInstruction(.checkSetup, "Check the reference setup", symbol: "viewfinder")
    static let hold = CoachInstruction(.hold, "Looks right. Take the shot", symbol: "checkmark.circle.fill")

    static func stepBack(meters: Double?) -> CoachInstruction {
        CoachInstruction(.stepBack, meters.map { "Step back \(formatMeters($0))" } ?? "Step back a little",
                         symbol: "arrow.down", amount: meters)
    }

    static func stepCloser(meters: Double?) -> CoachInstruction {
        CoachInstruction(.stepCloser, meters.map { "Step \(formatMeters($0)) closer" } ?? "Step a little closer",
                         symbol: "arrow.up", amount: meters)
    }

    static func changeHeight(by centimeters: Double, to target: CameraHeightBucket, from current: CameraHeightBucket) -> CoachInstruction {
        let raise = centimeters > 0
        let verb = raise ? "Raise" : "Lower"
        let text = target != current
            ? "\(verb) the phone \(target.phrase)"
            : "\(verb) the phone ≈\(Int((abs(centimeters) / 10).rounded()) * 10) cm"
        return CoachInstruction(raise ? .raisePhone : .lowerPhone, text,
                                symbol: raise ? "arrow.up.to.line" : "arrow.down.to.line",
                                amount: abs(centimeters), targetHeight: target)
    }

    /// Positive degrees mean the subject should turn to their right.
    static func subjectTurn(degrees: Double) -> CoachInstruction {
        let rounded = max(5, Int((abs(degrees) / 5).rounded()) * 5)
        return degrees > 0
            ? CoachInstruction(.subjectTurnRight, "Ask them to turn ≈\(rounded)° to their right",
                               symbol: "arrow.turn.up.right", amount: Double(rounded))
            : CoachInstruction(.subjectTurnLeft, "Ask them to turn ≈\(rounded)° to their left",
                               symbol: "arrow.turn.up.left", amount: Double(rounded))
    }

    static func tilt(degrees: Double) -> CoachInstruction {
        let rounded = max(5, Int((abs(degrees) / 5).rounded()) * 5)
        return degrees > 0
            ? CoachInstruction(.tiltUp, "Tilt the phone up ≈\(rounded)°", symbol: "arrow.uturn.up", amount: Double(rounded))
            : CoachInstruction(.tiltDown, "Tilt the phone down ≈\(rounded)°", symbol: "arrow.uturn.down", amount: Double(rounded))
    }

    static func adjustPose(_ cue: String) -> CoachInstruction {
        CoachInstruction(.adjustPose, cue, symbol: "figure.stand")
    }

    private static func formatMeters(_ meters: Double) -> String {
        let rounded = max(0.5, (meters * 2).rounded() / 2)
        return "≈\(rounded.formatted(.number.precision(.fractionLength(0...1)))) m"
    }
}

extension CameraHeightBucket {
    var phrase: String {
        switch self {
        case .ground: "to the ground"
        case .knee: "to knee height"
        case .hip: "to hip height"
        case .chest: "to chest height"
        case .eye: "to eye level"
        case .overhead: "above your head"
        }
    }
}

struct CoachTolerances {
    /// Coarse distance steps in meters; finer framing is left to the subject-size check.
    var distanceFraction = 0.25
    var heightRatio = 0.10
    var yawDegrees = 20.0
    var pitchDegrees = 5.0
    var rollDegrees = 3.0
    var centerOffset = 0.08
    var sizeFraction = 0.12
    var poseScore = 85
}

/// Turns live readings into one instruction at a time, using visible framing and pose
/// before inferred 3D camera measurements.
final class LiveCoach {
    let spec: ShotSpec
    let tolerances: CoachTolerances
    let switchAfter: Int
    /// The reference subject's box in live-frame coordinates.
    private(set) var targetBox: CGRect?
    private(set) var instruction: CoachInstruction?
    private(set) var poseMatch: PoseMatch?

    private let referencePose: PoseSkeleton?
    private let referenceFocalRatio: CGFloat
    private let smoothing = 0.35
    private var smoothed = LiveReading()
    private var roll: Double?
    private var pendingKind: CoachInstruction.Kind?
    private var pendingCount = 0
    private var lastReadingAt: Date?
    private(set) var hasFreshReading = false

    init(spec: ShotSpec, referencePose: PoseSkeleton? = nil, liveAspect: CGFloat = 3.0 / 4.0,
         tolerances: CoachTolerances = CoachTolerances(), switchAfter: Int = 3) {
        self.spec = spec
        self.referencePose = referencePose
        self.tolerances = tolerances
        self.switchAfter = switchAfter
        let focalRatio: CGFloat
        switch spec.focalSource {
        case .exif(let millimeters) where millimeters > 0:
            focalRatio = CGFloat(LensModel.phoneMainEquivalentMM / millimeters)
        default:
            focalRatio = 1
        }
        referenceFocalRatio = focalRatio
        targetBox = (FrameMapping.boundingBox(of: spec.silhouette) ?? spec.subjectBox).map {
            FrameMapping.map($0, fromAspect: spec.imageAspect, intoAspect: liveAspect, focalRatio: focalRatio)
        }
    }

    /// Call on every motion update. Pass `reading` only when a new Vision result is available.
    /// Roll is zero when the phone is level. Vision pitch is compared only with Vision pitch.
    @discardableResult
    func update(reading: LiveReading?, pitchDegrees _: Double, rollDegrees: Double,
                now: Date = Date()) -> CoachInstruction {
        if let reading {
            absorb(reading)
            lastReadingAt = now
            hasFreshReading = true
        } else if let lastReadingAt, now.timeIntervalSince(lastReadingAt) > 1.5 {
            smoothed = LiveReading()
            poseMatch = nil
            hasFreshReading = false
        }
        roll = blend(roll, rollDegrees)
        return settle(evaluate())
    }

    func evaluate() -> CoachInstruction {
        guard let box = smoothed.subjectBox else { return .findSubject }
        let limits = tolerances

        if let roll, abs(roll) > limits.rollDegrees { return .level }
        if let target = targetBox {
            let offset = box.midX - target.midX
            if offset < -limits.centerOffset { return .panLeft }
            if offset > limits.centerOffset { return .panRight }
            let verticalOffset = box.midY - target.midY
            if verticalOffset < -limits.centerOffset { return .aimUp }
            if verticalOffset > limits.centerOffset { return .aimDown }
            let size = box.height / max(target.height, 0.01)
            if size > 1 + limits.sizeFraction { return .stepBack(meters: nil) }
            if size < 1 - limits.sizeFraction { return .stepCloser(meters: nil) }
        }
        poseMatch = nil
        if referencePose != nil || spec.silhouette.count >= 3 {
            poseMatch = PoseMatcher.compare(reference: referencePose, live: smoothed.pose,
                                            referenceOutline: spec.silhouette, liveOutline: smoothed.silhouette)
            if let poseMatch, poseMatch.score < limits.poseScore { return .adjustPose(poseMatch.cue) }
        }
        if spec.silhouette.count >= 3 && smoothed.silhouette.count < 3 { return .checkSetup }
        if spec.silhouette.count >= 3 {
            let aspect = smoothed.frameAspect ?? 3.0 / 4.0
            let mapped = spec.silhouette.map {
                FrameMapping.map($0, fromAspect: spec.imageAspect, intoAspect: aspect,
                                 focalRatio: referenceFocalRatio)
            }
            if let overlap = SilhouetteMatcher.frameOverlap(reference: mapped, live: smoothed.silhouette),
               overlap < 65 {
                return .adjustPose("Align your outline with the guide")
            }
        }
        if let target = spec.subjectYawDegrees, let live = smoothed.subjectYawDegrees {
            let delta = Self.angleDifference(target, live)
            if abs(delta) > limits.yawDegrees { return .subjectTurn(degrees: delta) }
        }
        if let target = spec.cameraHeightRatio, let live = smoothed.cameraHeightRatio,
           abs(target - live) > limits.heightRatio {
            return .changeHeight(by: (target - live) * spec.subjectHeightMeters * 100,
                                 to: CameraHeightBucket(ratio: target), from: CameraHeightBucket(ratio: live))
        }
        if let targetPitch = spec.pitchDegrees, let livePitch = smoothed.visionPitchDegrees {
            let delta = targetPitch - livePitch
            if abs(delta) > limits.pitchDegrees { return .tilt(degrees: delta) }
        }
        if let target = spec.distanceMeters, let live = smoothed.distanceMeters, target > 0 {
            let error = (live - target) / target
            if error > limits.distanceFraction { return .stepCloser(meters: live - target) }
            if error < -limits.distanceFraction { return .stepBack(meters: target - live) }
        }
        if (spec.distanceMeters != nil && smoothed.distanceMeters == nil)
            || (spec.cameraHeightRatio != nil && smoothed.cameraHeightRatio == nil)
            || (spec.subjectYawDegrees != nil && smoothed.subjectYawDegrees == nil)
            || (spec.pitchDegrees != nil && smoothed.visionPitchDegrees == nil)
            || ((referencePose != nil || spec.silhouette.count >= 3) && poseMatch == nil) {
            return .checkSetup
        }
        return .hold
    }

    private func settle(_ next: CoachInstruction) -> CoachInstruction {
        guard let current = instruction, current.kind != next.kind else {
            instruction = next
            pendingKind = nil
            pendingCount = 0
            return next
        }
        if pendingKind == next.kind {
            pendingCount += 1
        } else {
            pendingKind = next.kind
            pendingCount = 1
        }
        guard pendingCount >= switchAfter else { return current }
        instruction = next
        pendingKind = nil
        pendingCount = 0
        return next
    }

    private func absorb(_ reading: LiveReading) {
        if let aspect = reading.frameAspect, aspect.isFinite, aspect > 0 {
            targetBox = (FrameMapping.boundingBox(of: spec.silhouette) ?? spec.subjectBox).map {
                FrameMapping.map($0, fromAspect: spec.imageAspect, intoAspect: aspect,
                                 focalRatio: referenceFocalRatio)
            }
        }
        guard let box = reading.subjectBox else {
            smoothed = LiveReading()
            poseMatch = nil
            return
        }
        let previous = smoothed.subjectBox
        smoothed.subjectBox = previous.map { old in
            CGRect(x: blend(old.minX, box.minX), y: blend(old.minY, box.minY),
                   width: blend(old.width, box.width), height: blend(old.height, box.height))
        } ?? box
        smoothed.cameraHeightRatio = reading.cameraHeightRatio.map { blend(smoothed.cameraHeightRatio, $0) }
        smoothed.distanceMeters = reading.distanceMeters.map { blend(smoothed.distanceMeters, $0) }
        smoothed.subjectYawDegrees = reading.subjectYawDegrees.map { new in
            smoothed.subjectYawDegrees.map { $0 + smoothing * Self.angleDifference(new, $0) } ?? new
        }
        smoothed.visionPitchDegrees = reading.visionPitchDegrees
        smoothed.frameAspect = reading.frameAspect
        smoothed.pose = reading.pose
        smoothed.silhouette = reading.silhouette
        smoothed.measuredSubjectHeight = reading.measuredSubjectHeight
    }

    private func blend(_ old: Double?, _ new: Double) -> Double {
        old.map { $0 + smoothing * (new - $0) } ?? new
    }

    private func blend(_ old: CGFloat, _ new: CGFloat) -> CGFloat {
        old + CGFloat(smoothing) * (new - old)
    }

    /// `a - b` wrapped into -180...180.
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var delta = (a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

/// Maps reference-image coordinates into the live frame by angular size. The reference is
/// treated as a centered crop of a 3:4 capture; focalRatio accounts for a different lens.
enum FrameMapping {
    static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 0.03, maxY - minY > 0.03 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func map(_ point: CGPoint, fromAspect: CGFloat, intoAspect: CGFloat,
                    focalRatio: CGFloat = 1) -> CGPoint {
        let source = CGSize(width: fromAspect, height: 1)
        let destination = CGSize(width: intoAspect, height: 1)
        let sourceDiagonal = diagonal(LensModel.captureFrame(containing: source))
        let destinationDiagonal = diagonal(LensModel.captureFrame(containing: destination))
        let scale = destinationDiagonal / sourceDiagonal * focalRatio
        return CGPoint(x: 0.5 + (point.x - 0.5) * scale * source.width / destination.width,
                       y: 0.5 + (point.y - 0.5) * scale * source.height / destination.height)
    }

    static func map(_ rect: CGRect, fromAspect: CGFloat, intoAspect: CGFloat,
                    focalRatio: CGFloat = 1) -> CGRect {
        let topLeft = map(CGPoint(x: rect.minX, y: rect.minY), fromAspect: fromAspect,
                          intoAspect: intoAspect, focalRatio: focalRatio)
        let bottomRight = map(CGPoint(x: rect.maxX, y: rect.maxY), fromAspect: fromAspect,
                              intoAspect: intoAspect, focalRatio: focalRatio)
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// Where a normalized live-frame point appears in a preview that shows the frame with aspect fill.
    static func viewPoint(_ point: CGPoint, frameAspect: CGFloat, viewSize: CGSize) -> CGPoint {
        let scale = max(viewSize.width / frameAspect, viewSize.height)
        let shown = CGSize(width: frameAspect * scale, height: scale)
        return CGPoint(x: (viewSize.width - shown.width) / 2 + point.x * shown.width,
                       y: (viewSize.height - shown.height) / 2 + point.y * shown.height)
    }

    /// The reference silhouette in preview coordinates, for drawing the pose cutout.
    static func cutout(for spec: ShotSpec, frameAspect: CGFloat = 3.0 / 4.0, viewSize: CGSize) -> [CGPoint] {
        let focalRatio: CGFloat
        switch spec.focalSource {
        case .exif(let millimeters) where millimeters > 0:
            focalRatio = CGFloat(LensModel.phoneMainEquivalentMM / millimeters)
        default:
            focalRatio = 1
        }
        return spec.silhouette.map {
            viewPoint(map($0, fromAspect: spec.imageAspect, intoAspect: frameAspect,
                          focalRatio: focalRatio),
                      frameAspect: frameAspect, viewSize: viewSize)
        }
    }

    private static func diagonal(_ size: CGSize) -> CGFloat { hypot(size.width, size.height) }
}
