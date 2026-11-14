import Foundation
import UIKit

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

    /// Scene scan: Typesense image similarity first, then on-device SceneMatcher fallback.
    /// Saved inspiration is always ranked locally and merged in.
    static func sceneMatches(for image: UIImage, inspiration: [SceneCandidate], limit: Int = 24) async -> [SceneMatch] {
        var remote: [SceneMatch] = []
        if TypesenseConfig.isConfigured {
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
