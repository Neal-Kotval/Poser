import CoreGraphics
import Foundation
import Vision

struct ShotGeometry {
    let cameraHeightMeters: Double
    let distanceMeters: Double
    let tiltDegrees: Int
    let inferredFromPose: Bool
    /// Present when the setup was measured from a 3D body pose rather than estimated from 2D framing.
    var spec: ShotSpec? = nil

    var heightLabel: String {
        spec?.heightBucket?.label ?? "Camera height unknown"
    }

    var distanceLabel: String {
        if let label = spec?.distanceLabel { return "Stand \(label) away" }
        return inferredFromPose ? "Start ≈\(distanceMeters.formatted(.number.precision(.fractionLength(1)))) m away" : "Move until framing matches"
    }

    var adjustmentLabel: String {
        if let height = spec?.cameraHeightMeters, let bucket = spec?.heightBucket {
            let rounded = (height * 10).rounded() / 10
            let value = rounded.formatted(.number.precision(.fractionLength(1)))
            return "Phone ≈\(value) m high\n(\(bucket.label.lowercased()))"
        }
        return "Height not measured"
    }

    var angleLabel: String {
        guard spec?.pitchDegrees != nil else { return "Match background lines" }
        if tiltDegrees >= 5 { return "Tilt up ≈\(tiltDegrees)°" }
        if tiltDegrees <= -5 { return "Tilt down ≈\(-tiltDegrees)°" }
        return "Keep the phone level"
    }
}

/// A compact side view of the measured setup. The available screen width limits
/// the drawing, so distance uses a monotonic scale while the label keeps the
/// measured value. Heights and pitch use the same vertical screen coordinates.
struct ShotDiagramLayout {
    let floor: CGFloat
    let figureWidth: CGFloat
    let figureHeight: CGFloat
    let photographerX: CGFloat
    let subjectX: CGFloat
    let phonePoint: CGPoint
    let aimPoint: CGPoint

    static func distanceFraction(_ meters: Double) -> CGFloat {
        let distance = min(8, max(0.5, meters))
        return CGFloat((log(1 + distance) - log(1.5)) / (log(9) - log(1.5)))
    }

    init(size: CGSize, geometry: ShotGeometry) {
        floor = size.height * 0.79
        figureWidth = min(128, size.width * 0.30)
        figureHeight = min(206, size.height * 0.57)

        let maximumSeparation = max(0, min(360, size.width - figureWidth - 20))
        let minimumSeparation = min(figureWidth * 1.55, maximumSeparation)
        let fraction = Self.distanceFraction(geometry.distanceMeters)
        let separation = minimumSeparation + (maximumSeparation - minimumSeparation) * fraction
        photographerX = (size.width - separation) / 2
        subjectX = (size.width + separation) / 2

        let subjectHeight = max(1.2, geometry.spec?.subjectHeightMeters ?? ShotSpecEstimator.defaultSubjectHeight)
        let pointsPerMeter = figureHeight * 0.75 / CGFloat(subjectHeight)
        let phoneY = min(floor - figureHeight * 0.06,
                         max(floor - figureHeight * 0.9,
                             floor - CGFloat(geometry.cameraHeightMeters) * pointsPerMeter))
        phonePoint = CGPoint(x: photographerX + figureWidth * 0.36, y: phoneY)
        let pitch = CGFloat(geometry.tiltDegrees) * .pi / 180
        let aimX = subjectX - figureWidth * 0.20
        aimPoint = CGPoint(x: aimX,
                           y: phoneY - tan(pitch) * (aimX - phonePoint.x))
    }
}

enum ShotGeometryEstimator {
    static func estimate(observation: VNHumanBodyPoseObservation?, recipe: ShotRecipe) -> ShotGeometry {
        guard let observation else { return fallback(for: recipe) }
        let joints: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
        ]
        var points: [PoseJoint: CGPoint] = [:]
        for (joint, name) in joints {
            if let point = try? observation.recognizedPoint(name), point.confidence > 0.3 {
                points[joint] = CGPoint(x: point.location.x, y: 1 - point.location.y)
            }
        }
        return estimate(points: points, recipe: recipe)
    }

    static func estimate(points: [PoseJoint: CGPoint], recipe: ShotRecipe) -> ShotGeometry {
        let base = fallback(for: recipe)
        guard points.count >= 7,
              points[.nose] != nil,
              points[.leftShoulder] != nil, points[.rightShoulder] != nil,
              points[.leftHip] != nil, points[.rightHip] != nil,
              points[.leftAnkle] != nil, points[.rightAnkle] != nil,
              let top = points.values.map(\.y).min(),
              let bottom = points.values.map(\.y).max(),
              bottom - top > 0.12 else { return base }

        let visibleFraction = Double(bottom - top)
        // A starting distance for a fully visible adult on a typical phone-wide lens.
        // Cropped bodies and unknown zoom levels cannot support a distance estimate.
        let visibleMeters = 1.7
        let rawDistance = visibleMeters / (2 * tan(63.0 * .pi / 360) * visibleFraction)
        let distance = min(8, max(0.5, (rawDistance * 2).rounded() / 2))

        return ShotGeometry(cameraHeightMeters: 1.5, distanceMeters: distance,
                            tiltDegrees: 0, inferredFromPose: true)
    }

    static func fallback(for recipe: ShotRecipe) -> ShotGeometry {
        .init(cameraHeightMeters: 1.5, distanceMeters: 2.5, tiltDegrees: 0, inferredFromPose: false)
    }
}
