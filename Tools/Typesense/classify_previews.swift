// Run on macOS: swift Tools/Typesense/classify_previews.swift catalog.json previews/ labels.json [vectors.json]
// Produces searchable labels and optional Vision revision 1 feature vectors.
import Foundation
import Vision

guard CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5 else {
    fputs("Usage: classify_previews.swift CATALOG_JSON PREVIEWS_DIR LABELS_JSON [VECTORS_JSON]\n", stderr)
    exit(2)
}

let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
let previewsURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let vectorsURL = CommandLine.arguments.count == 5 ? URL(fileURLWithPath: CommandLine.arguments[4]) : nil
let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
let entries = catalog["references"] as! [[String: Any]]
var labelsByPin: [String: [String]] = [:]
var vectorsByPin: [String: [Float]] = [:]
for (index, entry) in entries.enumerated() {
    guard let pinID = entry["pinID"] as? String else { continue }
    let imageURL = previewsURL.appendingPathComponent("\(pinID).jpg")
    guard FileManager.default.fileExists(atPath: imageURL.path) else { continue }
    let request = VNClassifyImageRequest()
    let featureRequest = VNGenerateImageFeaturePrintRequest()
    featureRequest.revision = VNGenerateImageFeaturePrintRequestRevision1
    let handler = VNImageRequestHandler(url: imageURL)
    do {
        try handler.perform(vectorsURL == nil ? [request] : [request, featureRequest])
        labelsByPin[pinID] = (request.results ?? [])
            .prefix(30)
            .filter { $0.confidence >= 0.12 }
            .map { $0.identifier.lowercased().replacingOccurrences(of: "_", with: " ") }
        if vectorsURL != nil, let feature = featureRequest.results?.first,
           feature.elementType == .float, feature.elementCount == 2048 {
            let vector = feature.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            vectorsByPin[pinID] = vector
        }
    } catch {
        fputs("Could not classify \(pinID): \(error)\n", stderr)
    }
    if (index + 1) % 100 == 0 { fputs("Classified \(index + 1)/\(entries.count)\n", stderr) }
}
let data = try JSONSerialization.data(withJSONObject: labelsByPin, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outputURL, options: .atomic)
print("Wrote \(labelsByPin.count) reference labels to \(outputURL.path)")
if let vectorsURL {
    let vectorsData = try JSONSerialization.data(withJSONObject: vectorsByPin, options: [.sortedKeys])
    try vectorsData.write(to: vectorsURL, options: .atomic)
    print("Wrote \(vectorsByPin.count) feature vectors to \(vectorsURL.path)")
}
