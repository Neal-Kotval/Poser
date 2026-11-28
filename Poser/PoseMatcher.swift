import CoreGraphics
import Foundation

struct PoseMatch {
    let score: Int
    let cue: String
    let comparedJoints: Int
}

enum PoseMatcher {
    static func compare(reference: PoseSkeleton?, live: PoseSkeleton?,
                        referenceOutline: [CGPoint] = [],
                        referenceMask: SilhouetteMatcher.Mask? = nil,
                        liveOutline: [CGPoint] = []) -> PoseMatch? {
        let priority: [PoseJoint] = [
            .nose, .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow, .leftWrist, .rightWrist,
            .leftHip, .rightHip, .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle
        ]
        let differences = priority.compactMap { joint -> (PoseJoint, CGFloat, CGFloat, CGFloat)? in
            guard let target = reference?[joint], let current = live?[joint] else { return nil }
            let dx = current.x - target.x
            let dy = current.y - target.y
            return (joint, hypot(dx, dy), dx, dy)
        }
        let compared = Set(differences.map(\.0))
        let hasArm = !compared.isDisjoint(with: [.leftElbow, .rightElbow, .leftWrist, .rightWrist])
        let hasLeg = !compared.isDisjoint(with: [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle])
        let jointEvidence = differences.count >= 5 && hasArm && hasLeg
        // A segmented shape alone is not evidence of a person or a measurable pose.
        guard jointEvidence else { return nil }

        let outlineScore = referenceMask.flatMap { SilhouetteMatcher.score(referenceMask: $0, live: liveOutline) }
            ?? SilhouetteMatcher.score(reference: referenceOutline, live: liveOutline)

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
        // Joints carry the pose; the outline adds shape detail when segmentation succeeds.
        let score = outlineScore.map {
            Int((0.40 * Double($0) + 0.60 * jointScore).rounded()) }
            ?? Int(jointScore.rounded())
        if score >= 85 {
            return PoseMatch(score: score, cue: "Pose is close to the reference", comparedJoints: differences.count)
        }
        if let outlineScore, outlineScore < 85, jointScore >= 85 {
            return PoseMatch(score: score, cue: "Adjust your body shape to match the reference", comparedJoints: differences.count)
        }
        if let worst = differences.max(by: { $0.1 < $1.1 }) {
            let facingCamera = isFacingCamera(live: live, reference: reference)
            return PoseMatch(score: score, cue: cue(for: worst.0, dx: worst.2, dy: worst.3, facingCamera: facingCamera),
                             comparedJoints: differences.count)
        }
        return PoseMatch(score: score, cue: "Match the reference pose", comparedJoints: 0)
    }

    private static func isFacingCamera(live: PoseSkeleton?, reference: PoseSkeleton?) -> Bool {
        for skeleton in [live, reference] {
            if let left = skeleton?[.leftShoulder], let right = skeleton?[.rightShoulder],
               abs(right.x - left.x) > 0.01 {
                return right.x - left.x < 0
            }
        }
        return false
    }

    private static func cue(for joint: PoseJoint, dx: CGFloat, dy: CGFloat, facingCamera: Bool) -> String {
        let signedDX = facingCamera ? -dx : dx
        switch joint {
        case .leftWrist, .leftElbow:
            if abs(dy) > abs(dx) { return dy > 0 ? "Raise your left arm" : "Lower your left arm" }
            return signedDX > 0 ? "Move your left arm outward" : "Bring your left arm inward"
        case .rightWrist, .rightElbow:
            if abs(dy) > abs(dx) { return dy > 0 ? "Raise your right arm" : "Lower your right arm" }
            return signedDX < 0 ? "Move your right arm outward" : "Bring your right arm inward"
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
    struct Mask {
        fileprivate let pixels: [Bool]
    }

    static func mask(for points: [CGPoint], normalizeBox: Bool) -> Mask? {
        raster(points, normalizeBox: normalizeBox)
    }

    /// Shape overlap after normalizing each person to its own bounding box.
    /// This leaves framing and camera distance to the separate setup checks.
    static func score(reference: [CGPoint], live: [CGPoint]) -> Int? {
        guard let target = raster(reference, normalizeBox: true) else { return nil }
        return score(referenceMask: target, live: live)
    }

    static func score(referenceMask target: Mask, live: [CGPoint]) -> Int? {
        guard let current = raster(live, normalizeBox: true) else { return nil }
        let overlap = intersectionOverUnion(target.pixels, current.pixels)
        let boundary = boundaryAgreement(target.pixels, current.pixels)
        return Int((100 * (0.65 * overlap + 0.35 * boundary)).rounded())
    }

    /// Screen-space overlap for outlines already mapped into the same frame.
    /// Unlike `score`, this penalizes position and scale differences.
    static func frameOverlap(reference: [CGPoint], live: [CGPoint]) -> Int? {
        guard let target = raster(reference, normalizeBox: false) else { return nil }
        return frameOverlap(referenceMask: target, live: live)
    }

    static func frameOverlap(referenceMask target: Mask, live: [CGPoint]) -> Int? {
        guard let current = raster(live, normalizeBox: false) else { return nil }
        return Int((100 * intersectionOverUnion(target.pixels, current.pixels)).rounded())
    }

    private static let grid = 48

    private static func raster(_ points: [CGPoint], normalizeBox: Bool) -> Mask? {
        guard points.count >= 3, points.allSatisfy({ point in
            point.x.isFinite && point.y.isFinite &&
            (-0.05...1.05).contains(point.x) && (-0.05...1.05).contains(point.y)
        }) else { return nil }
        let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard bounds.width > 0.03, bounds.height > 0.03 else { return nil }
        let polygon = CGMutablePath()
        for (index, point) in points.enumerated() {
            let mapped = normalizeBox
                ? CGPoint(x: (point.x - bounds.minX) / bounds.width,
                          y: (point.y - bounds.minY) / bounds.height) : point
            if index == 0 { polygon.move(to: mapped) } else { polygon.addLine(to: mapped) }
        }
        polygon.closeSubpath()
        var pixels = [Bool]()
        pixels.reserveCapacity(grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                pixels.append(polygon.contains(CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(grid),
                                                      y: (CGFloat(y) + 0.5) / CGFloat(grid))))
            }
        }
        guard pixels.filter({ $0 }).count >= 4 else { return nil }
        return Mask(pixels: pixels)
    }

    private static func intersectionOverUnion(_ a: [Bool], _ b: [Bool]) -> Double {
        var intersection = 0
        var union = 0
        for index in a.indices {
            if a[index] && b[index] { intersection += 1 }
            if a[index] || b[index] { union += 1 }
        }
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private static func boundaryAgreement(_ a: [Bool], _ b: [Bool]) -> Double {
        func edges(_ pixels: [Bool]) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            for y in 0..<grid {
                for x in 0..<grid where pixels[y * grid + x] {
                    if x == 0 || x == grid - 1 || y == 0 || y == grid - 1 ||
                        !pixels[y * grid + x - 1] || !pixels[y * grid + x + 1] ||
                        !pixels[(y - 1) * grid + x] || !pixels[(y + 1) * grid + x] {
                        result.append((x, y))
                    }
                }
            }
            return result
        }
        let first = edges(a)
        let second = edges(b)
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        func matched(_ source: [(Int, Int)], to target: [Bool]) -> Double {
            let count = source.reduce(0) { count, point in
                let found = (-2...2).contains { dy in
                    (-2...2).contains { dx in
                        let x = point.0 + dx
                        let y = point.1 + dy
                        return x >= 0 && x < grid && y >= 0 && y < grid && target[y * grid + x]
                    }
                }
                return count + (found ? 1 : 0)
            }
            return Double(count) / Double(source.count)
        }
        let aEdges = edgeMap(first)
        let bEdges = edgeMap(second)
        let precision = matched(first, to: bEdges)
        let recall = matched(second, to: aEdges)
        return precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    }

    private static func edgeMap(_ edges: [(Int, Int)]) -> [Bool] {
        var map = [Bool](repeating: false, count: grid * grid)
        for (x, y) in edges { map[y * grid + x] = true }
        return map
    }
}
