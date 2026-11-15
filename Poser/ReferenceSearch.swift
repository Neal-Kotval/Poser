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
    /// cluster, Vision names the environment and Typesense retrieves matching settings.
    /// Saved inspiration is always ranked locally and merged in.
    static func sceneMatches(for image: UIImage, inspiration: [SceneCandidate], limit: Int = 24,
                             preferredSettings: [String: Double]? = nil) async -> [SceneMatch] {
        var remote: [SceneMatch] = []
        if TypesenseConfig.isConfigured && TypesenseConfig.imageSearchEnabled {
            do {
                let hits = try await TypesenseClient.shared.searchSimilar(image: image, limit: limit)
                remote = hits.compactMap { hit in
                    guard ReferenceCatalog.items.contains(where: { $0.id == hit.id }) else { return nil }
                    return SceneMatch(id: hit.id, score: hit.score, explanation: "Visually similar")
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

        let settings: [String: Double]
        if let preferredSettings {
            settings = preferredSettings
        } else {
            settings = await SceneIntent.preferredSettings(for: image)
        }
        if !settings.isEmpty {
            let preferred = settings.sorted { $0.value > $1.value }.map(\.key)
            var references: [ReferenceAsset] = []
            if TypesenseConfig.isConfigured {
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
                    }
                }
            }
            // Fill sparse or unavailable remote results from the same bundled settings.
            if references.count < limit {
                references.append(contentsOf: ReferenceCatalog.items.filter {
                    settings[$0.setting ?? ""] != nil
                })
            }
            var seen = Set<UUID>()
            let candidates = references.compactMap { reference -> SceneCandidate? in
                guard seen.insert(reference.id).inserted, let preview = reference.preview else { return nil }
                return SceneCandidate(id: reference.id, image: preview)
            }
            if !candidates.isEmpty {
                let visual = await SceneMatcher.rank(scene: image, candidates: candidates,
                                                     allowFeaturePrints: false)
                let settingByID = Dictionary(references.map { ($0.id, $0.setting ?? "") },
                                             uniquingKeysWith: { first, _ in first })
                let ranked = visual.map { match in
                    let weight = settings[settingByID[match.id] ?? ""] ?? 0
                    return SceneMatch(id: match.id, score: 0.4 * match.score + 0.6 * weight,
                                      explanation: "Related environment idea")
                }
                let saved = inspiration.isEmpty ? [] : await SceneMatcher.rank(scene: image, candidates: inspiration)
                return Array((ranked + saved).sorted { $0.score > $1.score }.prefix(limit))
            }
        }

        var candidates = ReferenceCatalog.items.compactMap { reference -> SceneCandidate? in
            guard let preview = reference.preview else { return nil }
            return SceneCandidate(id: reference.id, image: preview)
        }
        candidates.append(contentsOf: inspiration)
        return await SceneMatcher.rank(scene: image, candidates: candidates)
    }

    private static func asset(for hit: TypesenseHit) -> ReferenceAsset? {
        if let existing = ReferenceCatalog.items.first(where: { $0.id == hit.id }) {
            return existing
        }
        // Indexed pin may not be in the current catalog build; synthesize a catalog-compatible asset.
        return ReferenceAsset(
            id: hit.id,
            title: hit.title,
            assetName: hit.pinID,
            credit: "Creator unverified",
            license: "Rights unverified",
            source: URL(string: "https://www.pinterest.com/pin/\(hit.pinID.replacingOccurrences(of: "pin-", with: ""))/"),
            setting: hit.setting,
            pose: hit.pose
        )
    }
}

/// Vision's broad scene labels become search terms that exist in the reference catalog.
/// This is useful for object-only scans, where the catalog photos also include people.
enum SceneIntent {
    static func preferredSettings(for image: UIImage) async -> [String: Double] {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = image.cgImage else { return [:] }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.sceneOrientation)
            guard (try? handler.perform([request])) != nil else { return [:] }
            let labels = (request.results ?? []).prefix(20)
                .filter { $0.confidence >= 0.2 }
                .map(\.identifier)
            return settings(for: labels)
        }.value
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

private extension UIImage {
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
