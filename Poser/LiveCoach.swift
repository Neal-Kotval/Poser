import AVFoundation
import CoreGraphics
import Foundation
import Vision
import simd

/// User placement in normalized live-frame coordinates, after reference fitting.
struct PoseGuidePlacement: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    static let identity = PoseGuidePlacement()

    func applying(to points: [CGPoint]) -> [CGPoint] {
        guard let bounds = FrameMapping.boundingBox(of: points) else { return points }
        return points.map {
            CGPoint(x: bounds.midX + ($0.x - bounds.midX) * scale + offset.width,
                    y: bounds.midY + ($0.y - bounds.midY) * scale + offset.height)
        }
    }

    func applying(to bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX + offset.width - bounds.width * scale / 2,
               y: bounds.midY + offset.height - bounds.height * scale / 2,
               width: bounds.width * scale, height: bounds.height * scale)
    }

    func constrained(baseBounds: CGRect, visibleBounds: CGRect) -> PoseGuidePlacement {
        let safeScale = scale.isFinite ? min(2.5, max(0.5, scale)) : 1
        let x = offset.width.isFinite ? baseBounds.midX + offset.width : baseBounds.midX
        let y = offset.height.isFinite ? baseBounds.midY + offset.height : baseBounds.midY
        return PoseGuidePlacement(scale: safeScale, offset: CGSize(
            width: min(visibleBounds.maxX, max(visibleBounds.minX, x)) - baseBounds.midX,
            height: min(visibleBounds.maxY, max(visibleBounds.minY, y)) - baseBounds.midY))
    }
}

/// Magnetic alignment uses preview-sized thresholds, independent of camera cropping.
enum PoseGuideSnapping {
    struct Lines: Equatable {
        var vertical: CGFloat?
        var horizontal: CGFloat?
    }
    struct Result {
        var placement: PoseGuidePlacement
        var lines: Lines
    }

    static func snap(_ placement: PoseGuidePlacement, base: CGRect, viewport: CGRect,
                     threshold: CGSize, retaining previous: Lines = Lines()) -> Result {
        let box = placement.applying(to: base)
        func alignment(minimum: CGFloat, middle: CGFloat, maximum: CGFloat,
                       low: CGFloat, center: CGFloat, high: CGFloat,
                       threshold: CGFloat, previous: CGFloat?) -> (delta: CGFloat, line: CGFloat)? {
            var candidates = [(delta: center - middle, line: center)]
            if maximum - minimum <= high - low {
                candidates += [(low - minimum, low), (high - maximum, high)]
            }
            // A wider release zone prevents flickering when a finger pauses at a guide.
            if let previous, let retained = candidates.first(where: { $0.line == previous }),
               abs(retained.delta) <= threshold * 1.7 { return retained }
            return candidates.filter { abs($0.delta) <= threshold }
                .min { abs($0.delta) < abs($1.delta) }
        }
        let x = alignment(minimum: box.minX, middle: box.midX, maximum: box.maxX,
                          low: viewport.minX, center: viewport.midX, high: viewport.maxX,
                          threshold: threshold.width, previous: previous.vertical)
        let y = alignment(minimum: box.minY, middle: box.midY, maximum: box.maxY,
                          low: viewport.minY, center: viewport.midY, high: viewport.maxY,
                          threshold: threshold.height, previous: previous.horizontal)
        var result = placement
        result.offset.width += x?.delta ?? 0
        result.offset.height += y?.delta ?? 0
        return Result(placement: result, lines: Lines(vertical: x?.line, horizontal: y?.line))
    }
}

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

/// Chooses one person to follow when Vision finds several. The reference position
/// starts the selection; proximity to the previous frame prevents score hopping.
enum LiveSubjectSelector {
    static func select(boxes: [CGRect], targetX: CGFloat, previousBox: CGRect?) -> Int? {
        boxes.indices.filter { index in
            let box = boxes[index]
            return box.width > 0.03 && box.height > 0.06 && box.midX.isFinite && box.midY.isFinite
        }.min { lhs, rhs in
            cost(boxes[lhs], targetX: targetX, previousBox: previousBox) <
                cost(boxes[rhs], targetX: targetX, previousBox: previousBox)
        }
    }

    private static func cost(_ box: CGRect, targetX: CGFloat, previousBox: CGRect?) -> CGFloat {
        let referenceOffset = abs(box.midX - targetX)
        let prominence = min(box.width * box.height, 1)
        guard let previousBox else { return referenceOffset - prominence * 0.2 }
        let movement = hypot(box.midX - previousBox.midX, box.midY - previousBox.midY)
        let sizeChange = abs(box.height - previousBox.height)
        return movement * 3 + sizeChange + referenceOffset * 0.3 - prominence * 0.1
    }
}

final class LiveFrameAnalyzer {
    #if DEBUG
    private static let failureReportLock = NSLock()
    private static var lastFailureReport: String?
    #endif
    let subjectHeightMeters: Double
    let minimumInterval: TimeInterval
    private var lastRun = Date.distantPast
    private var previousSubjectBox: CGRect?

    init(subjectHeightMeters: Double = ShotSpecEstimator.defaultSubjectHeight, minimumInterval: TimeInterval = 0.25) {
        self.subjectHeightMeters = subjectHeightMeters
        self.minimumInterval = minimumInterval
    }

    /// Returns nil when throttled. Enable `isCameraIntrinsicMatrixDeliveryEnabled` on the video
    /// connection so distances use the real lens instead of an assumed one.
    func analyze(_ sampleBuffer: CMSampleBuffer, targetX: CGFloat = 0.5,
                 orientation: CGImagePropertyOrientation = .right) -> LiveReading? {
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
        let reading = Self.reading(using: handler, frameSize: frameSize, focalPixels: focalPixels,
                                   subjectHeightMeters: subjectHeightMeters, targetX: targetX,
                                   previousSubjectBox: previousSubjectBox)
        previousSubjectBox = reading.subjectBox
        return reading
    }

    static func reading(using handler: VNImageRequestHandler, frameSize: CGSize, focalPixels: Double,
                        subjectHeightMeters: Double, targetX: CGFloat = 0.5,
                        previousSubjectBox: CGRect? = nil) -> LiveReading {
        let pose2D = VNDetectHumanBodyPoseRequest()
        let pose3D = VNDetectHumanBodyPose3DRequest()
        let failures = [("2D pose", VisionRunner.perform(pose2D, on: handler)),
                        ("3D pose", VisionRunner.perform(pose3D, on: handler))]
            .compactMap { name, error in error.map { "\(name): \($0)" } }
        #if DEBUG
        let report = failures.joined(separator: " | ")
        let shouldLog: Bool = {
            failureReportLock.lock()
            defer { failureReportLock.unlock() }
            guard report != lastFailureReport else { return false }
            lastFailureReport = report
            return true
        }()
        if shouldLog {
            print(report.isEmpty ? "[LiveCoach] Vision requests ok" : "[LiveCoach] Vision failed: \(report)")
        }
        #endif

        var reading = LiveReading()
        reading.frameAspect = frameSize.width / max(frameSize.height, 1)
        let observations = pose2D.results ?? []
        let boxes = observations.map { Pose2DReader.box(Pose2DReader.points($0)) ?? .null }
        let selectedIndex = LiveSubjectSelector.select(boxes: boxes, targetX: targetX,
                                                        previousBox: previousSubjectBox)
        let observation2D = selectedIndex.map { observations[$0] }
        let points = observation2D.map(Pose2DReader.points) ?? [:]
        reading.subjectBox = Pose2DReader.box(points)
        reading.pose = observation2D.flatMap(PoseSkeleton.detected)
        if observation2D != nil && observations.count == 1 {
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
        if observation2D == nil {
            let faces = VNDetectFaceRectanglesRequest()
            try? handler.perform([faces])
            let faceBoxes = (faces.results ?? []).map {
                CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                       width: $0.boundingBox.width, height: $0.boundingBox.height)
            }
            if let index = LiveSubjectSelector.select(boxes: faceBoxes, targetX: targetX,
                                                       previousBox: previousSubjectBox) {
                reading.subjectBox = faceBoxes[index]
            }
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
    private let guidePlacement: PoseGuidePlacement
    private let referenceNormalizedMask: SilhouetteMatcher.Mask?
    private let smoothing = 0.35
    private var smoothed = LiveReading()
    private var roll: Double?
    private var pendingKind: CoachInstruction.Kind?
    private var pendingCount = 0
    private var lastReadingAt: Date?
    private var poseEvaluated = false
    private var overlapEvaluated = false
    private var cachedFrameOverlap: Int?
    private var cachedFrameMaskAspect: CGFloat?
    private var cachedFrameMask: SilhouetteMatcher.Mask?
    private(set) var hasFreshReading = false

    init(spec: ShotSpec, referencePose: PoseSkeleton? = nil, liveAspect: CGFloat = 3.0 / 4.0,
         tolerances: CoachTolerances = CoachTolerances(), switchAfter: Int = 3,
         guidePlacement: PoseGuidePlacement = .identity) {
        self.spec = spec
        self.guidePlacement = guidePlacement
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
        referenceNormalizedMask = SilhouetteMatcher.mask(for: spec.silhouette, normalizeBox: true)
        targetBox = FrameMapping.mapTarget(silhouette: spec.silhouette, fallback: spec.subjectBox,
                                           fromAspect: spec.imageAspect, intoAspect: liveAspect,
                                           focalRatio: focalRatio).map { guidePlacement.applying(to: $0) }
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
            poseEvaluated = false
            overlapEvaluated = false
            cachedFrameOverlap = nil
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
        if !poseEvaluated {
            poseEvaluated = true
            if referencePose != nil || spec.silhouette.count >= 3 {
                poseMatch = PoseMatcher.compare(reference: referencePose, live: smoothed.pose,
                                                referenceOutline: spec.silhouette,
                                                referenceMask: referenceNormalizedMask,
                                                liveOutline: smoothed.silhouette)
            } else {
                poseMatch = nil
            }
        }
        if let poseMatch, poseMatch.score < limits.poseScore { return .adjustPose(poseMatch.cue) }
        if spec.silhouette.count >= 3 && smoothed.silhouette.count < 3 && poseMatch == nil { return .checkSetup }
        if spec.silhouette.count >= 3 && smoothed.silhouette.count >= 3 {
            if !overlapEvaluated {
                overlapEvaluated = true
                let aspect = smoothed.frameAspect ?? 3.0 / 4.0
                cachedFrameOverlap = frameMask(for: aspect).flatMap {
                    SilhouetteMatcher.frameOverlap(referenceMask: $0, live: smoothed.silhouette)
                }
            }
            if let overlap = cachedFrameOverlap, overlap < 65 {
                return .adjustPose("Adjust your position to match the reference")
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
        if let measured = spec.distanceMeters, let live = smoothed.distanceMeters, measured > 0 {
            let target = measured / Double(guidePlacement.scale)
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

    private func frameMask(for aspect: CGFloat) -> SilhouetteMatcher.Mask? {
        if cachedFrameMaskAspect == aspect { return cachedFrameMask }
        let mapped = guidePlacement.applying(to: FrameMapping.mapOutline(spec.silhouette, fromAspect: spec.imageAspect,
                                             intoAspect: aspect, focalRatio: referenceFocalRatio))
        let mask = SilhouetteMatcher.mask(for: mapped, normalizeBox: false)
        cachedFrameMaskAspect = aspect
        cachedFrameMask = mask
        return mask
    }

    private func absorb(_ reading: LiveReading) {
        poseEvaluated = false
        overlapEvaluated = false
        cachedFrameOverlap = nil
        if let aspect = reading.frameAspect, aspect.isFinite, aspect > 0 {
            targetBox = FrameMapping.mapTarget(silhouette: spec.silhouette, fallback: spec.subjectBox,
                                               fromAspect: spec.imageAspect, intoAspect: aspect,
                                               focalRatio: referenceFocalRatio).map { guidePlacement.applying(to: $0) }
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

    /// The part of a live frame that a tall phone preview actually shows. Aspect fill crops
    /// the sides of a 3:4 frame to roughly the middle 60%.
    static let visibleRegion = CGRect(x: 0.2, y: 0.04, width: 0.6, height: 0.92)

    /// Maps a reference outline into the live frame, then keeps it inside `visibleRegion`.
    /// A landscape or wide-lens reference with an off-center subject otherwise maps past the
    /// edge of a portrait preview, leaving a guide nobody can line up with.
    static func mapOutline(_ points: [CGPoint], fromAspect: CGFloat, intoAspect: CGFloat,
                           focalRatio: CGFloat = 1) -> [CGPoint] {
        let mapped = points.map { map($0, fromAspect: fromAspect, intoAspect: intoAspect, focalRatio: focalRatio) }
        guard let box = boundingBox(of: mapped) else { return mapped }
        let fit = fitting(box)
        return mapped.map(fit)
    }

    /// The live-frame target box, placed exactly where `mapOutline` draws the guide.
    static func mapTarget(silhouette: [CGPoint], fallback: CGRect?, fromAspect: CGFloat,
                          intoAspect: CGFloat, focalRatio: CGFloat = 1) -> CGRect? {
        if let box = boundingBox(of: mapOutline(silhouette, fromAspect: fromAspect,
                                                intoAspect: intoAspect, focalRatio: focalRatio)) {
            return box
        }
        guard let fallback else { return nil }
        let mapped = map(fallback, fromAspect: fromAspect, intoAspect: intoAspect, focalRatio: focalRatio)
        let fit = fitting(mapped)
        let topLeft = fit(CGPoint(x: mapped.minX, y: mapped.minY))
        let bottomRight = fit(CGPoint(x: mapped.maxX, y: mapped.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// Shrinks a box only if it is larger than the visible region, then slides it inside.
    private static func fitting(_ box: CGRect) -> (CGPoint) -> CGPoint {
        let region = visibleRegion
        guard box.width > 0, box.height > 0 else { return { $0 } }
        let scale = min(1, region.width / box.width, region.height / box.height)
        let halfWidth = box.width * scale / 2
        let halfHeight = box.height * scale / 2
        let centerX = min(max(box.midX, region.minX + halfWidth), region.maxX - halfWidth)
        let centerY = min(max(box.midY, region.minY + halfHeight), region.maxY - halfHeight)
        return { point in
            CGPoint(x: centerX + (point.x - box.midX) * scale,
                    y: centerY + (point.y - box.midY) * scale)
        }
    }

    /// Where a normalized live-frame point appears in a preview that shows the frame with aspect fill.
    static func viewPoint(_ point: CGPoint, frameAspect: CGFloat, viewSize: CGSize) -> CGPoint {
        let scale = max(viewSize.width / frameAspect, viewSize.height)
        let shown = CGSize(width: frameAspect * scale, height: scale)
        return CGPoint(x: (viewSize.width - shown.width) / 2 + point.x * shown.width,
                       y: (viewSize.height - shown.height) / 2 + point.y * shown.height)
    }

    static func framePoint(_ point: CGPoint, frameAspect: CGFloat, viewSize: CGSize) -> CGPoint {
        guard viewSize.width.isFinite, viewSize.height.isFinite, frameAspect.isFinite,
              viewSize.width > 0, viewSize.height > 0, frameAspect > 0 else { return .zero }
        let scale = max(viewSize.width / frameAspect, viewSize.height)
        return CGPoint(x: (point.x - (viewSize.width - frameAspect * scale) / 2) / (frameAspect * scale),
                       y: (point.y - (viewSize.height - scale) / 2) / scale)
    }

    static func frameTranslation(_ translation: CGSize, frameAspect: CGFloat, viewSize: CGSize) -> CGSize {
        guard viewSize.width.isFinite, viewSize.height.isFinite, frameAspect.isFinite,
              viewSize.width > 0, viewSize.height > 0, frameAspect > 0 else { return .zero }
        let scale = max(viewSize.width / frameAspect, viewSize.height)
        return CGSize(width: translation.width / (frameAspect * scale), height: translation.height / scale)
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
        return mapOutline(spec.silhouette, fromAspect: spec.imageAspect, intoAspect: frameAspect,
                          focalRatio: focalRatio)
            .map { viewPoint($0, frameAspect: frameAspect, viewSize: viewSize) }
    }

    private static func diagonal(_ size: CGSize) -> CGFloat { hypot(size.width, size.height) }
}
