import Foundation
import UIKit
import Vision
import LinkPresentation
import ImageIO
import UniformTypeIdentifiers

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
        .init(id: "street", title: "Street portrait", subtitle: "Make the city your backdrop", symbol: "building.2.crop.circle", camera: "Hold the phone at chest height and step about 8 feet away.", pose: "Stand a step from the wall. Turn your shoulders 30° and look past the lens.", light: "Face toward open sky; keep bright windows to one side.", framing: "Place the face near an upper third. Leave space in the direction of the gaze.", tags: ["street", "building", "city", "outdoor"]),
        .init(id: "nature", title: "Among the trees", subtitle: "A portrait with natural depth", symbol: "tree", camera: "Hold the phone near waist height and move 10 feet back.", pose: "Walk slowly toward the camera or lean against a tree.", light: "Look for open shade. Keep patches of direct sun off the face.", framing: "Put the subject in the middle third with foliage on both sides.", tags: ["tree", "forest", "garden", "plant", "nature", "outdoor"]),
        .init(id: "cafe", title: "Window light", subtitle: "A relaxed indoor portrait", symbol: "cup.and.saucer", camera: "Sit across the table and hold the phone just above eye level.", pose: "Turn toward the window, rest one arm on the table, and relax your shoulders.", light: "Put the window 45° to the subject's face. Turn off overhead lights.", framing: "Include a little foreground table and keep the eyes on the upper third.", tags: ["indoor", "restaurant", "food", "room", "cafe"]),
        .init(id: "sunset", title: "Golden outline", subtitle: "Use the last light of the day", symbol: "sun.horizon", camera: "Hold the phone low and move back until the full silhouette fits.", pose: "Stand sideways with a clear gap between arms and body.", light: "Place the sun behind the subject, just outside the frame.", framing: "Keep the horizon level and near the lower third.", tags: ["sunset", "sky", "beach", "water", "landscape"])
    ]
}

struct PhotoAnalysis {
    let labels: [String]
    let subjectPoint: CGPoint?
    let hasPerson: Bool
    let poseSkeleton: PoseSkeleton?
    let geometry: ShotGeometry
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
        } else if recipe.id == "cafe" {
            points[.leftElbow] = CGPoint(x: 0.35, y: 0.47)
            points[.leftWrist] = CGPoint(x: 0.48, y: 0.47)
            points[.leftKnee] = CGPoint(x: 0.58, y: 0.76)
            points[.rightKnee] = CGPoint(x: 0.72, y: 0.76)
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
        let xs = raw.values.map(\.x)
        let ys = raw.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = max(maxX - minX, 0.1)
        let height = max(maxY - minY, 0.1)
        let normalized = raw.mapValues { point in
            CGPoint(x: 0.18 + 0.64 * (point.x - minX) / width,
                    y: 0.10 + 0.82 * (point.y - minY) / height)
        }
        return PoseSkeleton(points: normalized)
    }
}

enum AnalysisService {
    static func analyze(_ image: UIImage) async throws -> PhotoAnalysis {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            let classify = VNClassifyImageRequest()
            let person = VNDetectHumanBodyPoseRequest()
            let salient = VNGenerateAttentionBasedSaliencyImageRequest()
            // Vision models are not available in every simulator/runtime. Keep the
            // reference flow usable when one model cannot initialize.
            try? handler.perform([classify])
            try? handler.perform([person])
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
            let geometry = ShotGeometryEstimator.estimate(observation: pose, recipe: recipe)
            return PhotoAnalysis(labels: labels, subjectPoint: point, hasPerson: pose != nil,
                                 poseSkeleton: poseSkeleton, geometry: geometry, summary: summary, recipe: recipe)
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
    case missingPreview
    var errorDescription: String? {
        switch self {
        case .invalidImage: "This image could not be opened. Try another photo."
        case .missingPreview: "This link does not expose a public image preview. Save the photo and import it instead."
        }
    }
}

@MainActor
enum LinkImageLoader {
    static func image(from text: String) async throws -> UIImage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AnalysisError.missingPreview
        }
        if ["jpg", "jpeg", "png", "webp", "heic"].contains(url.pathExtension.lowercased()) {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AnalysisError.missingPreview }
            guard let image = UIImage(data: data) else { throw AnalysisError.invalidImage }
            return image
        }
        let metadata: LPLinkMetadata
        do { metadata = try await LPMetadataProvider().startFetchingMetadata(for: url) }
        catch { throw AnalysisError.missingPreview }
        guard let provider = metadata.imageProvider else { throw AnalysisError.missingPreview }
        return try await withCheckedThrowingContinuation { continuation in
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: AnalysisError.missingPreview) }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let image = UIImage(data: data) { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: AnalysisError.missingPreview) }
                }
            }
        }
    }
}
