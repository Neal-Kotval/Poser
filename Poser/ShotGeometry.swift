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
        if let bucket = spec?.heightBucket { return bucket.label }
        switch cameraHeightMeters {
        case ..<0.8: return "Knee height"
        case ..<1.1: return "Waist height"
        case ..<1.4: return "Chest height"
        default: return "Eye height"
        }
    }

    var distanceLabel: String {
        if let label = spec?.distanceLabel { return "Stand \(label) away" }
        return inferredFromPose ? "Start ≈\(distanceMeters.formatted(.number.precision(.fractionLength(1)))) m away" : "Move until framing matches"
    }

    var adjustmentLabel: String {
        spec?.heightBucket.map { "Phone \($0.holdPhrase)" } ?? "Adjust camera height"
    }

    var angleLabel: String {
        guard spec?.pitchDegrees != nil else { return "Match background lines" }
        if tiltDegrees >= 5 { return "Tilt up ≈\(tiltDegrees)°" }
        if tiltDegrees <= -5 { return "Tilt down ≈\(-tiltDegrees)°" }
        return "Keep the phone level"
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

        let aimFraction = (0.5 - Double(top)) / visibleFraction
        let height: Double
        switch aimFraction {
        case ..<0.25: height = 1.55
        case ..<0.46: height = 1.25
        case ..<0.68: height = 0.95
        default: height = 0.65
        }
        return ShotGeometry(cameraHeightMeters: height, distanceMeters: distance,
                            tiltDegrees: 0, inferredFromPose: true)
    }

    static func fallback(for recipe: ShotRecipe) -> ShotGeometry {
        switch recipe.id {
        case "nature": .init(cameraHeightMeters: 0.95, distanceMeters: 3, tiltDegrees: 5, inferredFromPose: false)
        case "cafe": .init(cameraHeightMeters: 1.55, distanceMeters: 1.5, tiltDegrees: -5, inferredFromPose: false)
        case "sunset": .init(cameraHeightMeters: 0.65, distanceMeters: 3, tiltDegrees: 10, inferredFromPose: false)
        default: .init(cameraHeightMeters: 1.25, distanceMeters: 2.5, tiltDegrees: 0, inferredFromPose: false)
        }
    }
}
