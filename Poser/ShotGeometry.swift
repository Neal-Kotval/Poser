import CoreGraphics
import Foundation
import Vision

struct ShotGeometry {
    let cameraHeightMeters: Double
    let distanceMeters: Double
    let tiltDegrees: Int
    let inferredFromPose: Bool

    var heightLabel: String {
        switch cameraHeightMeters {
        case ..<0.8: "Knee height"
        case ..<1.1: "Waist height"
        case ..<1.4: "Chest height"
        default: "Eye height"
        }
    }

    var distanceLabel: String { "≈\(distanceMeters.formatted(.number.precision(.fractionLength(1)))) m away" }

    var adjustmentLabel: String {
        let lowerFeet = Int(((1.55 - cameraHeightMeters) * 3.28084).rounded())
        return lowerFeet > 0 ? "Lower ≈\(lowerFeet) ft" : "Eye level"
    }

    var angleLabel: String {
        if tiltDegrees >= 5 { return "Tilt up ≈\(tiltDegrees)°" }
        if tiltDegrees <= -5 { return "Tilt down ≈\(-tiltDegrees)°" }
        return "Keep level"
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
        guard points.count >= 5,
              let top = points.values.map(\.y).min(),
              let bottom = points.values.map(\.y).max(),
              bottom - top > 0.12 else { return base }

        let visibleFraction = Double(bottom - top)
        let fullBody = points[.leftAnkle] != nil || points[.rightAnkle] != nil
        let torso = points[.leftHip] != nil || points[.rightHip] != nil
        // Pinhole-camera approximation using a typical phone-wide vertical FOV.
        // A partial-body crop uses an approximate visible body span instead.
        let visibleMeters = fullBody ? 1.7 : (torso ? 0.9 : 0.5)
        let rawDistance = visibleMeters / (2 * tan(63.0 * .pi / 360) * visibleFraction)
        let distance = min(8, max(0.5, (rawDistance * 2).rounded() / 2))

        let aimFraction = (0.5 - Double(top)) / visibleFraction
        let height: Double
        if fullBody {
            switch aimFraction {
            case ..<0.25: height = 1.55
            case ..<0.46: height = 1.25
            case ..<0.68: height = 0.95
            default: height = 0.65
            }
        } else {
            height = base.cameraHeightMeters
        }
        let bodyCenter = Double((top + bottom) / 2)
        let tilt = Int((max(-15, min(15, (0.5 - bodyCenter) * 30)) / 5).rounded()) * 5
        return ShotGeometry(cameraHeightMeters: height, distanceMeters: distance,
                            tiltDegrees: tilt, inferredFromPose: true)
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
