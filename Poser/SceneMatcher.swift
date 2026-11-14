import Foundation
import UIKit
import Vision
import ImageIO

struct SceneCandidate {
    let id: UUID
    let image: UIImage
}

struct SceneMatch: Identifiable {
    let id: UUID
    let score: Double
    let explanation: String
}

/// Ranks locally saved inspiration against a camera scan. Vision compares broad
/// image structure; a spatial color and light signature keeps matching useful
/// when the feature-print model is unavailable (including some simulators).
enum SceneMatcher {
    static func rank(scene: UIImage, candidates: [SceneCandidate]) async -> [SceneMatch] {
        guard !candidates.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let sceneSignature = SceneSignature(image: scene)
            // Full Vision feature prints are too slow across a large bundled library.
            let scenePrint = candidates.count <= 100 ? featurePrint(for: scene) : nil
            return candidates.map { candidate in
                let signature = SceneSignature(image: candidate.image)
                let colorScore = sceneSignature.similarity(to: signature)
                let printScore: Double?
                if let scenePrint, let candidatePrint = featurePrint(for: candidate.image) {
                    var distance: Float = 0
                    if (try? scenePrint.computeDistance(&distance, to: candidatePrint)) != nil {
                        printScore = 1 / (1 + Double(max(0, distance)))
                    } else {
                        printScore = nil
                    }
                } else {
                    printScore = nil
                }
                let score = min(1, max(0, printScore.map { 0.55 * $0 + 0.45 * colorScore.total } ?? colorScore.total))
                let explanation: String
                if colorScore.light > 0.88 && colorScore.spatial > 0.7 {
                    explanation = "Similar backdrop and light"
                } else if colorScore.spatial > 0.75 {
                    explanation = "Similar scene colors"
                } else if colorScore.light > 0.88 {
                    explanation = "Similar light level"
                } else if printScore != nil {
                    explanation = "Similar overall scene"
                } else {
                    explanation = "Closest available inspiration"
                }
                return SceneMatch(id: candidate.id, score: score, explanation: explanation)
            }
            .sorted { left, right in
                if abs(left.score - right.score) < 0.0001 {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.score > right.score
            }
        }.value
    }

    private static func featurePrint(for image: UIImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgOrientation)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }
}

private struct SceneSignature {
    private let tiles: [SIMD3<Double>]
    private let meanLight: Double
    private let contrast: Double

    init(image: UIImage) {
        let side = 24
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            // UIImage.draw applies imageOrientation before the spatial tiles
            // are sampled. Camera photos commonly arrive as .right.
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let didDraw: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let cgImage = upright.cgImage,
                  let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard didDraw else {
            tiles = Array(repeating: SIMD3<Double>(0, 0, 0), count: 8)
            meanLight = 0
            contrast = 0
            return
        }

        var sums = Array(repeating: SIMD3<Double>(0, 0, 0), count: 9)
        var counts = Array(repeating: 0.0, count: 9)
        var lightSum = 0.0
        var lightSquared = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let alpha = max(Double(bytes[offset + 3]) / 255, 0.01)
                let rgb = SIMD3<Double>(Double(bytes[offset]) / 255 / alpha,
                                        Double(bytes[offset + 1]) / 255 / alpha,
                                        Double(bytes[offset + 2]) / 255 / alpha)
                let tile = (y / 8) * 3 + x / 8
                sums[tile] += rgb
                counts[tile] += 1
                let light = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                lightSum += light
                lightSquared += light * light
            }
        }
        // Keep the center tile out: it often contains a person, while the
        // surrounding tiles describe the location a user can recreate.
        tiles = (0..<9).filter { $0 != 4 }.map { sums[$0] / max(counts[$0], 1) }
        meanLight = lightSum / Double(side * side)
        contrast = sqrt(max(0, lightSquared / Double(side * side) - meanLight * meanLight))
    }

    func similarity(to other: SceneSignature) -> (total: Double, spatial: Double, light: Double) {
        let tileDistances = zip(tiles, other.tiles).map { left, right in
            simd_length(left - right) / sqrt(3)
        }
        let spatial = max(0, 1 - tileDistances.reduce(0, +) / Double(max(tileDistances.count, 1)))
        let light = max(0, 1 - abs(meanLight - other.meanLight))
        let contrastScore = max(0, 1 - abs(contrast - other.contrast))
        return (0.62 * spatial + 0.25 * light + 0.13 * contrastScore, spatial, light)
    }
}

private extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
