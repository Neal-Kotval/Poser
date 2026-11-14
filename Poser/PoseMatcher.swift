import CoreGraphics
import Foundation

struct PoseMatch {
    let score: Int
    let cue: String
    let comparedJoints: Int
}

enum PoseMatcher {
    static func compare(reference: PoseSkeleton, live: PoseSkeleton) -> PoseMatch? {
        let priority: [PoseJoint] = [
            .nose, .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow, .leftWrist, .rightWrist,
            .leftHip, .rightHip, .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle
        ]
        let differences = priority.compactMap { joint -> (PoseJoint, CGFloat, CGFloat, CGFloat)? in
            guard let target = reference[joint], let current = live[joint] else { return nil }
            let dx = current.x - target.x
            let dy = current.y - target.y
            return (joint, hypot(dx, dy), dx, dy)
        }
        guard differences.count >= 5 else { return nil }

        // Body-box normalized coordinates make this independent of camera distance.
        // Give arm and leg endpoints extra weight because they carry the pose.
        let weighted = differences.map { item -> (Double, Double) in
            let weight: Double = switch item.0 {
            case .leftWrist, .rightWrist, .leftAnkle, .rightAnkle: 1.5
            case .leftElbow, .rightElbow, .leftKnee, .rightKnee: 1.2
            default: 1.0
            }
            return (Double(item.1) * weight, weight)
        }
        let meanError = weighted.reduce(0.0) { $0 + $1.0 } / weighted.reduce(0.0) { $0 + $1.1 }
        let score = Int((100 * max(0, min(1, 1 - meanError / 0.30))).rounded())
        if score >= 85 {
            return PoseMatch(score: score, cue: "Pose is close to the reference", comparedJoints: differences.count)
        }
        let worst = differences.max { $0.1 < $1.1 }!
        return PoseMatch(score: score, cue: cue(for: worst.0, dx: worst.2, dy: worst.3), comparedJoints: differences.count)
    }

    private static func cue(for joint: PoseJoint, dx: CGFloat, dy: CGFloat) -> String {
        switch joint {
        case .leftWrist, .leftElbow:
            if abs(dy) > abs(dx) { return dy > 0 ? "Raise your left arm" : "Lower your left arm" }
            return dx > 0 ? "Move your left arm outward" : "Bring your left arm inward"
        case .rightWrist, .rightElbow:
            if abs(dy) > abs(dx) { return dy > 0 ? "Raise your right arm" : "Lower your right arm" }
            return dx < 0 ? "Move your right arm outward" : "Bring your right arm inward"
        case .leftKnee, .leftAnkle:
            return "Adjust your left leg to match the guide"
        case .rightKnee, .rightAnkle:
            return "Adjust your right leg to match the guide"
        case .nose:
            return dx > 0 ? "Turn your head slightly left" : "Turn your head slightly right"
        case .leftShoulder, .rightShoulder, .neck:
            return "Shift your shoulders to match the guide"
        case .leftHip, .rightHip:
            return "Shift your stance to match the guide"
        }
    }
}
