import AVFoundation
import CoreGraphics
import Foundation
import Vision
import simd

/// What the live camera currently sees, in the same terms as `ShotSpec`.
struct LiveReading {
    var cameraHeightRatio: Double?
    var distanceMeters: Double?
    var subjectYawDegrees: Double?
    var visionPitchDegrees: Double?
    /// Normalized to the live frame, top-left origin.
    var subjectBox: CGRect?
    var pose: PoseSkeleton?
    /// Present when LiDAR depth let Vision measure the subject instead of assuming 1.8 m.
    var measuredSubjectHeight: Double?
}

final class LiveFrameAnalyzer {
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
        let intrinsics = delivered ?? LensModel.intrinsicsData(width: width, height: height, focalPixels: focalPixels)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation,
                                            options: [.cameraIntrinsics: intrinsics as CFData])
        return Self.reading(using: handler, frameSize: frameSize, focalPixels: focalPixels,
                            subjectHeightMeters: subjectHeightMeters)
    }

    static func reading(using handler: VNImageRequestHandler, frameSize: CGSize, focalPixels: Double,
                        subjectHeightMeters: Double) -> LiveReading {
        let pose2D = VNDetectHumanBodyPoseRequest()
        let pose3D = VNDetectHumanBodyPose3DRequest()
        try? handler.perform([pose2D])
        try? handler.perform([pose3D])

        var reading = LiveReading()
        let observation2D = pose2D.results?.first
        let points = observation2D.map(Pose2DReader.points) ?? [:]
        reading.subjectBox = Pose2DReader.box(points)
        reading.pose = observation2D.flatMap(PoseSkeleton.detected)

        if let body = pose3D.results?.first, Pose3DReader.isUsable(body), let placement = Pose3DReader.placement(body) {
            let measured = body.heightEstimation == .measured
            let scale = measured ? 1 : subjectHeightMeters / Double(body.bodyHeight)
            reading.cameraHeightRatio = placement.heightRatio
            reading.distanceMeters = placement.horizontalDistance * scale
            reading.subjectYawDegrees = placement.subjectYawDegrees
            reading.visionPitchDegrees = placement.pitchDegrees
            if measured { reading.measuredSubjectHeight = Double(body.bodyHeight) }
            if reading.subjectBox == nil { reading.subjectBox = Pose3DReader.subjectBox(body)?.box }
        } else if let span = Pose2DReader.noseToAnkle(points) {
            reading.distanceMeters = BodyFrameGeometry.pinholeDistance(
                focalPixels: focalPixels, subjectHeightMeters: subjectHeightMeters,
                visibleFraction: Pose2DReader.noseToAnkleFraction, spanPixels: Double(span * frameSize.height))
        }
        return reading
    }
}

struct CoachInstruction: Equatable {
    enum Kind: String, Equatable {
        case findSubject, stepBack, stepCloser, raisePhone, lowerPhone, subjectTurnRight, subjectTurnLeft
        case tiltUp, tiltDown, level, panLeft, panRight, adjustPose, hold
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

/// Turns live readings into one instruction at a time: distance, height, subject turn, tilt,
/// level, framing, then pose.
final class LiveCoach {
    let spec: ShotSpec
    let tolerances: CoachTolerances
    let switchAfter: Int
    /// The reference subject's box in live-frame coordinates.
    let targetBox: CGRect?
    private(set) var instruction: CoachInstruction?
    private(set) var poseMatch: PoseMatch?

    private let referencePose: PoseSkeleton?
    private let smoothing = 0.35
    private var smoothed = LiveReading()
    private var pitch: Double?
    private var roll: Double?
    private var pendingKind: CoachInstruction.Kind?
    private var pendingCount = 0

    init(spec: ShotSpec, referencePose: PoseSkeleton? = nil, liveAspect: CGFloat = 3.0 / 4.0,
         tolerances: CoachTolerances = CoachTolerances(), switchAfter: Int = 3) {
        self.spec = spec
        self.referencePose = referencePose
        self.tolerances = tolerances
        self.switchAfter = switchAfter
        targetBox = spec.subjectBox.map { FrameMapping.map($0, fromAspect: spec.imageAspect, intoAspect: liveAspect) }
    }

    /// Call on every motion update. Pass `reading` only when a new Vision result is available.
    /// Pitch is positive when the camera tilts up; roll is zero when the phone is level.
    @discardableResult
    func update(reading: LiveReading?, pitchDegrees: Double, rollDegrees: Double) -> CoachInstruction {
        if let reading { absorb(reading) }
        pitch = blend(pitch, pitchDegrees)
        roll = blend(roll, rollDegrees)
        return settle(evaluate())
    }

    func evaluate() -> CoachInstruction {
        guard let box = smoothed.subjectBox else { return .findSubject }
        let limits = tolerances

        if let target = spec.distanceMeters, let live = smoothed.distanceMeters, target > 0 {
            let error = (live - target) / target
            if error > limits.distanceFraction { return .stepCloser(meters: live - target) }
            if error < -limits.distanceFraction { return .stepBack(meters: target - live) }
        }
        if let target = spec.cameraHeightRatio, let live = smoothed.cameraHeightRatio,
           abs(target - live) > limits.heightRatio {
            return .changeHeight(by: (target - live) * spec.subjectHeightMeters * 100,
                                 to: CameraHeightBucket(ratio: target), from: CameraHeightBucket(ratio: live))
        }
        if let target = spec.subjectYawDegrees, let live = smoothed.subjectYawDegrees {
            let delta = Self.angleDifference(target, live)
            if abs(delta) > limits.yawDegrees { return .subjectTurn(degrees: delta) }
        }
        if let pitch {
            let delta = (spec.pitchDegrees ?? 0) - pitch
            if abs(delta) > limits.pitchDegrees { return .tilt(degrees: delta) }
        }
        if let roll, abs(roll) > limits.rollDegrees { return .level }
        if let target = targetBox {
            let offset = box.midX - target.midX
            if offset < -limits.centerOffset { return .panLeft }
            if offset > limits.centerOffset { return .panRight }
            let size = box.height / max(target.height, 0.01)
            if size > 1 + limits.sizeFraction { return .stepBack(meters: nil) }
            if size < 1 - limits.sizeFraction { return .stepCloser(meters: nil) }
        }
        if let referencePose, let pose = smoothed.pose {
            poseMatch = PoseMatcher.compare(reference: referencePose, live: pose)
            if let poseMatch, poseMatch.score < limits.poseScore { return .adjustPose(poseMatch.cue) }
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
        guard let box = reading.subjectBox else {
            smoothed = LiveReading()
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
        smoothed.pose = reading.pose
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

/// Maps reference-image coordinates into the live frame by angular size, assuming both were taken
/// with the same phone lens and the reference is a centered crop of a 3:4 capture.
enum FrameMapping {
    static func map(_ point: CGPoint, fromAspect: CGFloat, intoAspect: CGFloat) -> CGPoint {
        let source = CGSize(width: fromAspect, height: 1)
        let destination = CGSize(width: intoAspect, height: 1)
        let sourceDiagonal = diagonal(LensModel.captureFrame(containing: source))
        let destinationDiagonal = diagonal(LensModel.captureFrame(containing: destination))
        let scale = destinationDiagonal / sourceDiagonal
        return CGPoint(x: 0.5 + (point.x - 0.5) * scale * source.width / destination.width,
                       y: 0.5 + (point.y - 0.5) * scale * source.height / destination.height)
    }

    static func map(_ rect: CGRect, fromAspect: CGFloat, intoAspect: CGFloat) -> CGRect {
        let topLeft = map(CGPoint(x: rect.minX, y: rect.minY), fromAspect: fromAspect, intoAspect: intoAspect)
        let bottomRight = map(CGPoint(x: rect.maxX, y: rect.maxY), fromAspect: fromAspect, intoAspect: intoAspect)
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
        spec.silhouette.map {
            viewPoint(map($0, fromAspect: spec.imageAspect, intoAspect: frameAspect),
                      frameAspect: frameAspect, viewSize: viewSize)
        }
    }

    private static func diagonal(_ size: CGSize) -> CGFloat { hypot(size.width, size.height) }
}
