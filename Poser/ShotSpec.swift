import CoreGraphics
import Foundation

enum CameraHeightBucket: String, CaseIterable {
    case ground, knee, hip, chest, eye, overhead

    init(ratio: Double) {
        switch ratio {
        case ..<0.15: self = .ground
        case ..<0.35: self = .knee
        case ..<0.6: self = .hip
        case ..<0.8: self = .chest
        case ..<1.0: self = .eye
        default: self = .overhead
        }
    }

    var label: String {
        switch self {
        case .ground: "Ground level"
        case .knee: "Knee height"
        case .hip: "Hip height"
        case .chest: "Chest height"
        case .eye: "Eye level"
        case .overhead: "Above head"
        }
    }

    var holdPhrase: String {
        switch self {
        case .ground: "near the ground"
        case .knee: "at knee height"
        case .hip: "at hip height"
        case .chest: "at chest height"
        case .eye: "at eye level"
        case .overhead: "above your head"
        }
    }
}

/// Where the reference photo was taken from. Camera height and angles are relative to the
/// subject's body; distance is absolute for a subject of `subjectHeightMeters`.
struct ShotSpec: Equatable {
    enum Source: String { case pose3D, pose2D, fallback }
    enum FocalSource: Equatable { case exif(millimeters: Double), assumedPhoneLens }

    let source: Source
    /// Camera height above the ground divided by the subject's height.
    let cameraHeightRatio: Double?
    /// Horizontal distance from the photographer to the subject, in meters.
    let distanceMeters: Double?
    let distanceIsApproximate: Bool
    /// Positive when the camera is tilted up.
    let pitchDegrees: Double?
    /// Positive when the camera sits toward the subject's left side.
    let subjectYawDegrees: Double?
    let horizonDegrees: Double?
    /// Normalized to the reference image, top-left origin.
    let subjectBox: CGRect?
    /// Normalized to the reference image, top-left origin.
    let silhouette: [CGPoint]
    let subjectHeightMeters: Double
    let focalSource: FocalSource
    /// Reference image width divided by height.
    let imageAspect: CGFloat

    init(source: Source, cameraHeightRatio: Double? = nil, distanceMeters: Double? = nil,
         distanceIsApproximate: Bool = true, pitchDegrees: Double? = nil, subjectYawDegrees: Double? = nil,
         horizonDegrees: Double? = nil, subjectBox: CGRect? = nil, silhouette: [CGPoint] = [],
         subjectHeightMeters: Double = ShotSpecEstimator.defaultSubjectHeight,
         focalSource: FocalSource = .assumedPhoneLens, imageAspect: CGFloat = 3.0 / 4.0) {
        self.source = source
        self.cameraHeightRatio = cameraHeightRatio
        self.distanceMeters = distanceMeters
        self.distanceIsApproximate = distanceIsApproximate
        self.pitchDegrees = pitchDegrees
        self.subjectYawDegrees = subjectYawDegrees
        self.horizonDegrees = horizonDegrees
        self.subjectBox = subjectBox
        self.silhouette = silhouette
        self.subjectHeightMeters = subjectHeightMeters
        self.focalSource = focalSource
        self.imageAspect = imageAspect
    }

    var heightBucket: CameraHeightBucket? { cameraHeightRatio.map(CameraHeightBucket.init(ratio:)) }

    var cameraHeightMeters: Double? { cameraHeightRatio.map { $0 * subjectHeightMeters } }

    var distanceLabel: String? { distanceMeters.map(Self.formatDistance) }

    /// Positive degrees mean the subject should turn to their right.
    var subjectTurnDegrees: Int? {
        guard let yaw = subjectYawDegrees, abs(yaw) >= 15 else { return nil }
        return Int((yaw / 5).rounded()) * 5
    }

    static func formatDistance(_ meters: Double) -> String {
        let roundedMeters = max(0.5, (meters * 2).rounded() / 2)
        let roundedFeet = max(1.5, (meters * 3.28084 * 2).rounded() / 2)
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        return "≈\(roundedMeters.formatted(style)) m (\(roundedFeet.formatted(style)) ft)"
    }

    func shotGeometry(fallback: ShotGeometry) -> ShotGeometry {
        ShotGeometry(
            cameraHeightMeters: cameraHeightMeters.map { max(0.15, $0) } ?? fallback.cameraHeightMeters,
            distanceMeters: distanceMeters.map { max(0.5, ($0 * 2).rounded() / 2) } ?? fallback.distanceMeters,
            tiltDegrees: pitchDegrees.map { Int(($0 / 5).rounded()) * 5 } ?? fallback.tiltDegrees,
            inferredFromPose: source != .fallback,
            spec: self
        )
    }
}
