import Foundation
import UIKit
import Vision
import ImageIO

struct ShotRecipe: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let camera: String
    let pose: String
    let light: String
    let framing: String
    let tags: [String]

    static let presets: [ShotRecipe] = [
        .init(id: "street", title: "Street portrait", subtitle: "Make the city your backdrop", symbol: "building.2.crop.circle", camera: "Move until the subject fills the same part of the frame as the reference.", pose: "Stand a step from the wall. Turn your shoulders 30° and look past the lens.", light: "Face toward open sky; keep bright windows to one side.", framing: "Place the face near an upper third. Leave space in the direction of the gaze.", tags: ["street", "building", "city", "outdoor"]),
        .init(id: "nature", title: "Among the trees", subtitle: "A portrait with natural depth", symbol: "tree", camera: "Match the subject's size and the background lines in the reference.", pose: "Walk slowly toward the camera or lean against a tree.", light: "Look for open shade. Keep patches of direct sun off the face.", framing: "Put the subject in the middle third with foliage on both sides.", tags: ["tree", "forest", "garden", "plant", "nature", "outdoor"]),
        .init(id: "cafe", title: "Window light", subtitle: "A relaxed indoor portrait", symbol: "cup.and.saucer", camera: "Move until the table and subject match the reference framing.", pose: "Turn toward the window, rest one arm on the table, and relax your shoulders.", light: "Put the window 45° to the subject's face. Turn off overhead lights.", framing: "Include a little foreground table and keep the eyes on the upper third.", tags: ["indoor", "restaurant", "food", "room", "cafe"]),
        .init(id: "sunset", title: "Golden outline", subtitle: "Use the last light of the day", symbol: "sun.horizon", camera: "Move until the full silhouette and horizon match the reference.", pose: "Stand sideways with a clear gap between arms and body.", light: "Place the sun behind the subject, just outside the frame.", framing: "Keep the horizon level and near the lower third.", tags: ["sunset", "sky", "beach", "water", "landscape"])
    ]
}

struct PhotoAnalysis {
    let labels: [String]
    let subjectPoint: CGPoint?
    let hasPerson: Bool
    let poseSkeleton: PoseSkeleton?
    let geometry: ShotGeometry
    let shotSpec: ShotSpec
    let summary: String
    let recipe: ShotRecipe
}

enum PoseJoint: String, CaseIterable {
    case nose, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

struct PoseSkeleton {
    let points: [PoseJoint: CGPoint]

    subscript(_ joint: PoseJoint) -> CGPoint? { points[joint] }

    /// Supplies a complete outline for the illustrated guide without changing
    /// which joints Vision actually found for scoring or pose cues.
    func displayingMissingJoints() -> PoseSkeleton {
        guard let leftShoulder = points[.leftShoulder],
              let rightShoulder = points[.rightShoulder] else { return self }
        let example = Self.example(for: ShotRecipe.presets[1])
        let shoulderCenter = CGPoint(x: (leftShoulder.x + rightShoulder.x) / 2,
                                     y: (leftShoulder.y + rightShoulder.y) / 2)
        let exampleShoulderCenter = CGPoint(x: 0.5, y: 0.28)
        let signedWidth = rightShoulder.x - leftShoulder.x
        let scale = min(max(hypot(signedWidth, rightShoulder.y - leftShoulder.y) / 0.24, 0.7), 1.4)
        let horizontalScale = signedWidth < 0 ? -scale : scale
        var completed = points
        for joint in PoseJoint.allCases {
            guard let fallback = example[joint] else { continue }
            let guide = CGPoint(
                x: shoulderCenter.x + (fallback.x - exampleShoulderCenter.x) * horizontalScale,
                y: shoulderCenter.y + (fallback.y - exampleShoulderCenter.y) * scale
            )
            guard let detected = points[joint] else {
                completed[joint] = guide
                continue
            }
            // The drawing should stay legible if Vision puts a wrist or ankle far from
            // its body. Keep the unmodified detection in `points` for matching.
            let radius: CGFloat = switch joint {
            case .leftWrist, .rightWrist, .leftAnkle, .rightAnkle: 0.28
            case .leftElbow, .rightElbow, .leftKnee, .rightKnee: 0.20
            default: 1
            }
            let offset = CGVector(dx: detected.x - guide.x, dy: detected.y - guide.y)
            let length = hypot(offset.dx, offset.dy)
            if length > radius {
                completed[joint] = CGPoint(x: guide.x + offset.dx * radius / length,
                                           y: guide.y + offset.dy * radius / length)
            }
        }
        return PoseSkeleton(points: completed)
    }

    static func example(for recipe: ShotRecipe) -> PoseSkeleton {
        var points: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: 0.50, y: 0.12), .neck: CGPoint(x: 0.50, y: 0.23),
            .leftShoulder: CGPoint(x: 0.38, y: 0.28), .rightShoulder: CGPoint(x: 0.62, y: 0.28),
            .leftElbow: CGPoint(x: 0.30, y: 0.43), .rightElbow: CGPoint(x: 0.70, y: 0.43),
            .leftWrist: CGPoint(x: 0.27, y: 0.57), .rightWrist: CGPoint(x: 0.73, y: 0.57),
            .leftHip: CGPoint(x: 0.43, y: 0.55), .rightHip: CGPoint(x: 0.57, y: 0.55),
            .leftKnee: CGPoint(x: 0.42, y: 0.74), .rightKnee: CGPoint(x: 0.60, y: 0.74),
            .leftAnkle: CGPoint(x: 0.40, y: 0.94), .rightAnkle: CGPoint(x: 0.63, y: 0.94)
        ]
        if recipe.id == "street" {
            points[.rightElbow] = CGPoint(x: 0.69, y: 0.44)
            points[.rightWrist] = CGPoint(x: 0.75, y: 0.58)
            points[.leftKnee] = CGPoint(x: 0.38, y: 0.74)
        }
        return PoseSkeleton(points: points)
    }

    static func detected(from observation: VNHumanBodyPoseObservation) -> PoseSkeleton? {
        let names: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose), (.neck, .neck),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
        ]
        var raw: [PoseJoint: CGPoint] = [:]
        for (key, name) in names {
            if let point = try? observation.recognizedPoint(name), point.confidence > 0.28 {
                raw[key] = CGPoint(x: point.location.x, y: 1 - point.location.y)
            }
        }
        guard raw.count >= 6,
              raw[.leftShoulder] != nil, raw[.rightShoulder] != nil else { return nil }
        return normalized(raw)
    }

    static func normalized(_ raw: [PoseJoint: CGPoint]) -> PoseSkeleton? {
        guard raw.count >= 6, raw[.leftShoulder] != nil, raw[.rightShoulder] != nil else { return nil }
        let xs = raw.values.map(\.x)
        let ys = raw.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let height = max(maxY - minY, 0.1)
        let scale = min(0.82 / height, 0.64 / max(maxX - minX, 0.1))
        let centerX = (minX + maxX) / 2
        let normalized = raw.mapValues { point in
            CGPoint(x: 0.5 + (point.x - centerX) * scale,
                    y: 0.10 + (point.y - minY) * scale)
        }
        return PoseSkeleton(points: normalized)
    }

    var shortCue: String {
        for side in ["left", "right"] {
            let shoulder = side == "left" ? points[.leftShoulder] : points[.rightShoulder]
            let wrist = side == "left" ? points[.leftWrist] : points[.rightWrist]
            if let shoulder, let wrist, wrist.y < shoulder.y - 0.07 {
                return "Raise your \(side) arm"
            }
        }
        if let left = points[.leftAnkle], let right = points[.rightAnkle],
           abs(left.x - right.x) > 0.25 { return "Stand with feet apart" }
        if points[.leftWrist] != nil || points[.rightWrist] != nil { return "Match the arm positions" }
        return "Match the visible pose"
    }
}

enum AnalysisService {
    static func analyze(_ image: UIImage, imageData: Data? = nil) async throws -> PhotoAnalysis {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            // Decode the same original photo used by ShotSpecEstimator when available, so the
            // displayed skeleton and measured setup refer to the same oriented image.
            let handler = imageData.map { VNImageRequestHandler(data: $0, orientation: orientation) }
                ?? VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            let classify = VNClassifyImageRequest()
            let person = VNDetectHumanBodyPoseRequest()
            let salient = VNGenerateAttentionBasedSaliencyImageRequest()
            // Vision models are not available in every simulator/runtime. Keep the
            // reference flow usable when one model cannot initialize.
            try? handler.perform([classify])
            if let error = VisionRunner.perform(person, on: handler) {
                print("[AnalysisService] 2D pose failed: \(error)")
            }
            try? handler.perform([salient])

            let observations = Array((classify.results ?? []).prefix(15))
            let labels = observations.prefix(8).map(\.identifier)
            let pose = person.results?.first
            let poseSkeleton = pose.flatMap(PoseSkeleton.detected)
            let point: CGPoint?
            if let pose, let nose = try? pose.recognizedPoint(.nose), nose.confidence > 0.25 {
                point = CGPoint(x: nose.location.x, y: 1 - nose.location.y)
            } else if let box = salient.results?.first?.salientObjects?.first?.boundingBox {
                point = CGPoint(x: box.midX, y: 1 - box.midY)
            } else {
                point = nil
            }
            let scores = ShotRecipe.presets.map { recipe in
                observations.reduce(Float.zero) { score, observation in
                    let label = observation.identifier.lowercased()
                    let matches = recipe.tags.filter { label.contains($0) }.count
                    return score + Float(matches) * observation.confidence
                }
            }
            let bestIndex = scores.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            let recipe = scores[bestIndex] > 0.04 ? ShotRecipe.presets[bestIndex] : ShotRecipe.presets[0]
            let summary: String
            if observations.isEmpty && pose == nil && point == nil {
                summary = "Image analysis is unavailable on this device. Use this shot plan as a starting point."
            } else if pose == nil {
                summary = "We found the main focal area and scene cues. Use this setup as a starting point."
            } else {
                summary = "We found a person in the frame. Match their position, then refine your angle and light."
            }
            let estimate = ShotSpecEstimator.estimate(cgImage: cgImage, orientation: orientation, imageData: imageData,
                                                      subjectHeightMeters: ShotSpecEstimator.defaultSubjectHeight)
            #if DEBUG
            print("[ShotSpec] source \(estimate.spec.source.rawValue)\n\(estimate.diagnostics.text)")
            #endif
            let poseGeometry = ShotGeometryEstimator.estimate(observation: pose, recipe: recipe)
            let geometry = estimate.spec.shotGeometry(fallback: poseGeometry)
            return PhotoAnalysis(labels: labels, subjectPoint: point, hasPerson: pose != nil,
                                 poseSkeleton: poseSkeleton, geometry: geometry, shotSpec: estimate.spec,
                                 summary: summary, recipe: recipe)
        }.value
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

enum AnalysisError: LocalizedError {
    case invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidImage: "This image could not be opened. Try another photo."
        }
    }
}
