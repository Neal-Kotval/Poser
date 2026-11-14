// swift Tools/ReferenceLibrary/analyze.swift .reference-work/images > .reference-work/vision.json
// Suggestions only: reviewers confirm people, tags, poses, and instructions.
import Foundation
import Vision
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".reference-work/images")
let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
var output: [String: Any] = [:]
for url in files.sorted(by: { $0.path < $1.path }) where ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) {
    autoreleasepool {
        let classify = VNClassifyImageRequest()
        let body = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(url: url)
        var errors: [String] = []
        do { try handler.perform([classify]) } catch { errors.append("Classification unavailable") }
        do { try handler.perform([body]) } catch { errors.append("Body detection unavailable") }
        let labels = (classify.results ?? []).prefix(15).map { ["label": $0.identifier, "confidence": $0.confidence] as [String: Any] }
        let people = (body.results ?? []).map { observation -> [String: Any] in
            guard let points = try? observation.recognizedPoints(.all) else { return [:] }
            return Dictionary(uniqueKeysWithValues: points.filter { $0.value.confidence > 0.28 }.map {
                ($0.key.rawValue.rawValue, ["x": $0.value.location.x, "y": 1 - $0.value.location.y, "confidence": CGFloat($0.value.confidence)])
            })
        }
        let vocabulary: [String: [String]] = [
            "street": ["street", "building", "city"], "wall": ["wall", "brick"],
            "stairs": ["stairs", "staircase", "steps"], "cafe": ["cafe", "restaurant", "coffee"],
            "window": ["window", "interior"], "park": ["park", "tree", "forest"],
            "garden": ["garden", "flower", "plant"], "beach": ["beach", "sand", "coast"],
            "waterfront": ["water", "lake", "river", "ocean"], "landscape": ["field", "mountain", "landscape"]
        ]
        var settingSuggestions: [String: Float] = [:]
        for observation in (classify.results ?? []).prefix(15) where observation.confidence >= 0.1 {
            let words = observation.identifier.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            for (setting, aliases) in vocabulary where aliases.contains(where: { words.contains($0) || words.contains($0 + "s") }) {
                settingSuggestions[setting] = max(settingSuggestions[setting] ?? 0, observation.confidence)
            }
        }
        output[url.deletingPathExtension().lastPathComponent] = ["labels": labels, "detectedPeople": people.count, "landmarks": people, "settingSuggestions": settingSuggestions, "errors": errors]
    }
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
