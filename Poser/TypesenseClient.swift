import Foundation
import UIKit
import Vision

struct TypesenseHit: Equatable {
    let id: UUID
    let title: String
    let pinID: String
    let setting: String?
    let pose: String?
    let score: Double
}

enum TypesenseError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Typesense is not configured. Add Secrets/Typesense.plist."
        case .badURL: "Typesense host URL is invalid."
        case .http(let code, let body): "Typesense HTTP \(code): \(body)"
        case .decoding: "Typesense returned an unexpected response."
        }
    }
}

/// Thin REST client for Typesense image/text search. Uses the search-only API key.
actor TypesenseClient {
    static let shared = TypesenseClient()

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Text search over titles/tags. Free-tier clusters use keyword search; CLIP image
    /// embeddings need a larger Typesense plan (the model does not fit in 0.5 GB RAM).
    func searchText(_ query: String, setting: String? = nil, pose: String? = nil, limit: Int = 40) async throws -> [TypesenseHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var search: [String: Any] = [
            "collection": TypesenseConfig.collection,
            "q": trimmed,
            "query_by": "search_text,title,tags,setting,pose",
            "query_by_weights": "4,3,2,2,2",
            "per_page": limit
        ]
        if let filter = filterBy(setting: setting, pose: pose) {
            search["filter_by"] = filter
        }
        return try await multiSearch(search)
    }

    /// Image → image similarity when a CLIP embedding field exists on the collection.
    /// On free tier this will fail; callers should fall back to on-device SceneMatcher.
    func searchSimilar(image: UIImage, setting: String? = nil, pose: String? = nil, limit: Int = 24) async throws -> [TypesenseHit] {
        let base64 = try jpegBase64(image, maxDimension: 512)
        var search: [String: Any] = [
            "collection": TypesenseConfig.collection,
            "q": "*",
            "vector_query": "embedding:([], image:\(base64))",
            "exclude_fields": "embedding,image",
            "per_page": limit
        ]
        if let filter = filterBy(setting: setting, pose: pose) {
            search["filter_by"] = filter
        }
        return try await multiSearch(search)
    }

    /// Query a manually indexed Vision revision 1 feature vector. No server-side model is loaded.
    func searchVisionSimilar(image: UIImage, limit: Int = 24) async throws -> [TypesenseHit] {
        guard let cgImage = image.cgImage else { throw TypesenseError.decoding }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.sceneOrientation)
        try handler.perform([request])
        guard let feature = request.results?.first,
              feature.elementType == .float, feature.elementCount == 2048 else {
            throw TypesenseError.decoding
        }
        let values = feature.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let vector = values.map { String($0) }.joined(separator: ",")
        let search: [String: Any] = [
            "collection": TypesenseConfig.collection,
            "q": "*",
            "vector_query": "vision_embedding:([\(vector)], k:\(limit))",
            "exclude_fields": "vision_embedding",
            "per_page": limit
        ]
        return try await multiSearch(search)
    }

    private func filterBy(setting: String?, pose: String?) -> String? {
        var parts: [String] = []
        if let setting, !setting.isEmpty { parts.append("setting:=\(setting)") }
        if let pose, !pose.isEmpty { parts.append("pose:=\(pose)") }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    private func multiSearch(_ search: [String: Any]) async throws -> [TypesenseHit] {
        guard TypesenseConfig.isConfigured else { throw TypesenseError.notConfigured }
        guard let base = TypesenseConfig.baseURL else { throw TypesenseError.badURL }
        let url = base.appendingPathComponent("multi_search")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TypesenseConfig.searchAPIKey, forHTTPHeaderField: "X-TYPESENSE-API-KEY")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: ["searches": [search]])

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TypesenseError.http(code, String(body.prefix(280)))
        }
        return try parseHits(data)
    }

    private func parseHits(_ data: Data) throws -> [TypesenseHit] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let hits = first["hits"] as? [[String: Any]] else { throw TypesenseError.decoding }

        return hits.compactMap { hit in
            guard let document = hit["document"] as? [String: Any],
                  let idString = document["id"] as? String, let id = UUID(uuidString: idString),
                  let pinID = document["pinID"] as? String else { return nil }
            let title = document["title"] as? String ?? pinID
            let setting = document["setting"] as? String
            let pose = document["pose"] as? String
            let distance = (hit["vector_distance"] as? Double)
                ?? (hit["text_match"] as? Double).map { 1 / (1 + $0) }
                ?? 0.5
            // Typesense vector_distance is smaller when closer; text match is larger when closer.
            let score: Double
            if hit["vector_distance"] is Double {
                score = 1 / (1 + max(0, distance))
            } else if let textMatch = hit["text_match"] as? Double {
                score = min(1, textMatch / 1_000_000)
            } else {
                score = 0.5
            }
            return TypesenseHit(id: id, title: title, pinID: pinID, setting: setting, pose: pose, score: score)
        }
    }

    private func jpegBase64(_ image: UIImage, maxDimension: CGFloat) throws -> String {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.72) else { throw TypesenseError.decoding }
        return data.base64EncodedString()
    }
}
