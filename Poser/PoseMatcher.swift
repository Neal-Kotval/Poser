import CoreGraphics
import Foundation

struct PoseMatch {
    let score: Int
    let cue: String
    let comparedJoints: Int
}

enum PoseMatcher {
    static func compare(reference: PoseSkeleton, live: PoseSkeleton,
                        referenceOutline: [CGPoint] = [], liveOutline: [CGPoint] = []) -> PoseMatch? {
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
        let outlineScore = SilhouetteMatcher.score(reference: referenceOutline, live: liveOutline)
        guard differences.count >= 5 || outlineScore != nil else { return nil }

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
        let meanError = weighted.reduce(0.0) { $0 + $1.0 } / max(weighted.reduce(0.0) { $0 + $1.1 }, 1)
        let jointScore = 100 * max(0, min(1, 1 - meanError / 0.30))
        // The visible shape is the primary objective. Joints are most useful for
        // explaining which limb to move when the shape differs.
        let score = outlineScore.map { differences.count >= 5
            ? Int((0.75 * Double($0) + 0.25 * jointScore).rounded()) : $0 }
            ?? Int(jointScore.rounded())
        if score >= 85 {
            return PoseMatch(score: score, cue: "Pose is close to the reference", comparedJoints: differences.count)
        }
        if let worst = differences.max(by: { $0.1 < $1.1 }) {
            return PoseMatch(score: score, cue: cue(for: worst.0, dx: worst.2, dy: worst.3), comparedJoints: differences.count)
        }
        return PoseMatch(score: score, cue: "Match your outline to the guide", comparedJoints: 0)
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

enum SilhouetteMatcher {
    /// Shape overlap after normalizing each person to its own bounding box.
    /// This leaves framing and camera distance to the separate setup checks.
    static func score(reference: [CGPoint], live: [CGPoint]) -> Int? {
        guard reference.count >= 3, live.count >= 3 else { return nil }
        func path(_ points: [CGPoint]) -> CGPath? {
            let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            guard bounds.width > 0.03, bounds.height > 0.03 else { return nil }
            let polygon = CGMutablePath()
            for (index, point) in points.enumerated() {
                let normalized = CGPoint(x: (point.x - bounds.minX) / bounds.width,
                                         y: (point.y - bounds.minY) / bounds.height)
                if index == 0 { polygon.move(to: normalized) } else { polygon.addLine(to: normalized) }
            }
            polygon.closeSubpath()
            return polygon
        }
        guard let target = path(reference), let current = path(live) else { return nil }
        var intersection = 0
        var union = 0
        for y in 0..<40 {
            for x in 0..<40 {
                let sample = CGPoint(x: (CGFloat(x) + 0.5) / 40, y: (CGFloat(y) + 0.5) / 40)
                let a = target.contains(sample)
                let b = current.contains(sample)
                if a && b { intersection += 1 }
                if a || b { union += 1 }
            }
        }
        guard union > 0 else { return nil }
        return Int((100 * Double(intersection) / Double(union)).rounded())
    }
}
