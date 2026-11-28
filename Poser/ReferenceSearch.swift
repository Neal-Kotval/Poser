import Foundation
import UIKit
import Vision
import ImageIO

/// Typesense-backed reference retrieval with local catalog fallbacks.
enum ReferenceSearch {
    /// Text search for the For You bar. Falls back to local title/tag matching when Typesense is off or fails.
    static func text(_ query: String, tag: ReferenceTag?) async -> [ReferenceAsset] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ReferenceCatalog.items(matching: tag, query: "")
        }
        if TypesenseConfig.isConfigured {
            do {
                let hits = try await TypesenseClient.shared.searchText(
                    trimmed,
                    setting: tag?.kind == .setting ? tag?.value : nil,
                    pose: tag?.kind == .pose ? tag?.value : nil
                )
                let mapped = hits.compactMap(asset(for:))
                if !mapped.isEmpty { return mapped }
            } catch {
                #if DEBUG
                print("[ReferenceSearch] text search failed: \(error.localizedDescription)")
                #endif
            }
        }
        return ReferenceCatalog.items(matching: tag, query: trimmed)
    }

    /// Scene scans use image embeddings when the collection supports them. On a keyword-only
    /// cluster, Vision names objects and scenes and Typesense searches those terms.
    /// Saved inspiration is always ranked locally and merged in.
    static func sceneMatches(for image: UIImage, inspiration: [SceneCandidate], limit: Int = 24,
                             preferredSettings: [String: Double]? = nil,
                             preferredLabels: [String]? = nil) async -> [SceneMatch] {
        var remote: [SceneMatch] = []
        if TypesenseConfig.isConfigured &&
            (TypesenseConfig.visionVectorSearchEnabled || TypesenseConfig.imageSearchEnabled) {
            do {
                let hits: [TypesenseHit]
                if TypesenseConfig.visionVectorSearchEnabled {
                    hits = try await TypesenseClient.shared.searchVisionSimilar(image: image,
                                                                               limit: max(48, limit * 2))
                } else {
                    hits = try await TypesenseClient.shared.searchSimilar(image: image,
                                                                         limit: max(48, limit * 2))
                }
                let vectorSettings = SceneIntent.settings(for: await SceneIntent.labels(for: image))
                remote = hits.compactMap { hit in
                    guard ReferenceCatalog.asset(id: hit.id) != nil else { return nil }
                    let boost = vectorSettings[hit.setting ?? ""] ?? 0
                    return SceneMatch(id: hit.id, score: hit.score + 0.2 * boost,
                                      explanation: "Visually similar")
                }
            } catch {
                #if DEBUG
                print("[ReferenceSearch] image search failed: \(error.localizedDescription)")
                #endif
            }
        }

        if !remote.isEmpty {
            let inspirationMatches = inspiration.isEmpty ? [] : await SceneMatcher.rank(scene: image, candidates: inspiration)
            let merged = (remote + inspirationMatches)
                .reduce(into: [UUID: SceneMatch]()) { $0[$1.id] = $1 }
                .values
                .sorted { $0.score > $1.score }
            return Array(merged.prefix(limit))
        }

        let labels: [String]
        if let preferredLabels {
            labels = preferredLabels
        } else if let preferredSettings {
            labels = preferredSettings.keys.sorted()
        } else {
            labels = await SceneIntent.labels(for: image)
        }
        let settings = preferredSettings ?? SceneIntent.settings(for: labels)
        var references: [ReferenceAsset] = []
        var termWeights: [UUID: Double] = [:]
        var remoteSearchAvailable = true
        if TypesenseConfig.isConfigured {
            // Search the actual recognized objects, not only the catalog's fixed setting facets.
            // Existing clusters without image labels can still use the setting searches below.
            for (index, term) in SceneIntent.searchTerms(for: labels).prefix(6).enumerated() {
                do {
                    let hits = try await TypesenseClient.shared.searchText(term, limit: max(24, limit))
                    for hit in hits {
                        termWeights[hit.id] = max(termWeights[hit.id] ?? 0, 1 - Double(index) * 0.1)
                    }
                    references.append(contentsOf: hits.compactMap(asset(for:)))
                } catch {
                    #if DEBUG
                    print("[ReferenceSearch] scene term search failed: \(error.localizedDescription)")
                    #endif
                    remoteSearchAvailable = false
                    break
                }
            }
        }
        if !settings.isEmpty {
            let preferred = settings.sorted { $0.value > $1.value }.map(\.key)
            if TypesenseConfig.isConfigured && remoteSearchAvailable {
                for setting in preferred.prefix(3) {
                    do {
                        let hits = try await TypesenseClient.shared.searchText(
                            setting, setting: setting, limit: max(24, limit)
                        )
                        references.append(contentsOf: hits.compactMap(asset(for:)))
                    } catch {
                        #if DEBUG
                        print("[ReferenceSearch] scene keyword search failed: \(error.localizedDescription)")
                        #endif
                        break
                    }
                }
            }
            // Fill sparse or unavailable remote results from the bundled settings.
            if references.count < limit {
                references.append(contentsOf: ReferenceCatalog.items.filter {
                    settings[$0.setting ?? ""] != nil
                })
            }
        }
        if !references.isEmpty {
            let settingByID = Dictionary(references.map { ($0.id, $0.setting ?? "") },
                                         uniquingKeysWith: { first, _ in first })
            let ranked = await rankCatalogReferences(references, against: image, limit: limit) { match in
                let weight = max(settings[settingByID[match.id] ?? ""] ?? 0,
                                 termWeights[match.id] ?? 0)
                return SceneMatch(id: match.id, score: 0.4 * match.score + 0.6 * weight,
                                  explanation: "Related environment idea")
            }
            if !ranked.isEmpty {
                let saved = inspiration.isEmpty ? [] : await SceneMatcher.rank(scene: image, candidates: inspiration)
                return Array((ranked + saved).sorted { $0.score > $1.score }.prefix(limit))
            }
        }

        let fallback = await rankCatalogReferences(ReferenceCatalog.items, against: image, limit: limit)
        let saved = inspiration.isEmpty ? [] : await SceneMatcher.rank(scene: image, candidates: inspiration)
        return Array((fallback + saved).sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func rankCatalogReferences(
        _ references: [ReferenceAsset],
        against scene: UIImage,
        limit: Int,
        transform: (SceneMatch) -> SceneMatch = { $0 }
    ) async -> [SceneMatch] {
        var top: [SceneMatch] = []
        var seen = Set<UUID>()
        let batchSize = 24
        var index = 0
        while index < references.count {
            let end = min(index + batchSize, references.count)
            let slice = references[index..<end]
            index = end
            let batch: [SceneCandidate] = autoreleasepool {
                slice.compactMap { reference in
                    guard seen.insert(reference.id).inserted,
                          let preview = reference.preview else { return nil }
                    return SceneCandidate(id: reference.id, image: preview)
                }
            }
            guard !batch.isEmpty else { continue }
            let scored = await SceneMatcher.rank(scene: scene, candidates: batch, allowFeaturePrints: false)
                .map(transform)
            top.append(contentsOf: scored)
            top.sort { left, right in
                if abs(left.score - right.score) < 0.0001 {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.score > right.score
            }
            if top.count > limit {
                top.removeSubrange(limit...)
            }
        }
        return top
    }

    private static func asset(for hit: TypesenseHit) -> ReferenceAsset? {
        ReferenceCatalog.asset(id: hit.id)
    }
}

/// Vision's broad scene labels become search terms that exist in the reference catalog.
/// This is useful for object-only scans, where the catalog photos also include people.
enum SceneIntent {
    static func labels(for image: UIImage) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = image.cgImage else { return [] }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.sceneOrientation)
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).prefix(30)
                .filter { $0.confidence >= 0.12 }
                .map(\.identifier)
        }.value
    }

    static func searchTerms(for labels: [String]) -> [String] {
        let ignored: Set<String> = ["person", "people", "human", "adult", "child", "clothing",
                                    "fashion", "portrait", "face", "head", "body", "skin", "hair",
                                    "male", "female", "woman", "man", "boy", "girl", "structure",
                                    "image", "photo", "photograph", "indoor", "outdoor",
                                    "background", "scene", "object"]
        var seen = Set<String>()
        return labels.flatMap { $0.lowercased().split { !$0.isLetter }.map(String.init) }
            .filter { $0.count >= 3 && !ignored.contains($0) && seen.insert($0).inserted }
    }

    static func settings(for labels: [String]) -> [String: Double] {
        var scores: [String: Double] = [:]
        func prefer(_ setting: String, _ score: Double) {
            scores[setting] = max(scores[setting] ?? 0, score)
        }
        for raw in labels {
            let label = raw.lowercased().replacingOccurrences(of: "_", with: " ")
            let words = Set(label.split(whereSeparator: { !$0.isLetter }).map(String.init))
            func has(_ terms: [String]) -> Bool {
                terms.contains { $0.contains(" ") ? label.contains($0) : words.contains($0) }
            }
            if has(["chair", "stool", "table", "tableware", "furniture", "restaurant", "cafe", "coffee", "dining", "kitchen", "interior"]) {
                prefer("cafe", 1)
                prefer("window", 0.65)
            }
            if has(["window", "curtain", "sofa", "couch"]) {
                prefer("window", 1)
                prefer("cafe", 0.7)
            }
            if has(["bench"]) { prefer("park", 1); prefer("garden", 0.65) }
            if has(["beach", "ocean", "sea", "sand"]) { prefer("beach", 1); prefer("waterfront", 0.7) }
            if has(["lake", "river", "waterfront"]) { prefer("waterfront", 1); prefer("landscape", 0.6) }
            if has(["street", "road", "sidewalk", "city"]) { prefer("street", 1); prefer("wall", 0.5) }
            if has(["forest", "tree", "grass", "park"]) { prefer("park", 1); prefer("garden", 0.75) }
            if has(["stair", "step"]) { prefer("stairs", 1) }
            if has(["brick wall", "stone wall"]) { prefer("wall", 1) }
        }
        return scores
    }
}

extension UIImage {
    var sceneOrientation: CGImagePropertyOrientation {
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
