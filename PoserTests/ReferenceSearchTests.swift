import XCTest
import UIKit
@testable import Poser

final class ReferenceSearchTests: XCTestCase {
    func testBeachTextSearchReturnsMatches() async {
        // Uses Typesense when Secrets/Typesense.plist is present; otherwise local catalog fallback.
        let results = await ReferenceSearch.text("beach", tag: nil)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { asset in
            let haystack = [asset.title, asset.setting ?? "", asset.pose ?? ""].joined(separator: " ").lowercased()
            return haystack.contains("beach")
        })
    }

    func testEmptyQueryReturnsCatalogOrTagFilter() async {
        let all = await ReferenceSearch.text("", tag: nil)
        XCTAssertEqual(all.count, ReferenceCatalog.items.count)
    }

    func testChairAndTableScanSurfacesIndoorIdeas() async throws {
        let reference = try XCTUnwrap(ReferenceCatalog.items.first {
            $0.assetName == "pin-1101552390110841312"
        })
        let original = try XCTUnwrap(reference.image?.cgImage)
        let furniture = try XCTUnwrap(original.cropping(to: CGRect(x: 545, y: 400, width: 190, height: 500)))
        let matches = await ReferenceSearch.sceneMatches(
            for: UIImage(cgImage: furniture), inspiration: [], limit: 12,
            preferredSettings: SceneIntent.settings(for: ["furniture", "table", "interior_room", "window"])
        )
        let settings = matches.prefix(8).compactMap { match in
            ReferenceCatalog.items.first(where: { $0.id == match.id })?.setting
        }
        let relevant = settings.filter { $0 == "cafe" || $0 == "window" }.count
        XCTAssertGreaterThanOrEqual(relevant, 6, "Top settings: \(settings)")
    }

    func testChairLabelsChooseCafeAndWindowWithoutMistakingSeatingForSea() {
        let settings = SceneIntent.settings(for: ["chair", "furniture", "interior_room", "seating"])
        XCTAssertEqual(settings["cafe"], 1)
        XCTAssertNotNil(settings["window"])
        XCTAssertNil(settings["beach"])
    }

    func testSceneTermsKeepObjectsOutsideFixedSettings() {
        let terms = SceneIntent.searchTerms(for: ["person", "flower", "red_flower", "museum", "chair"])
        XCTAssertEqual(terms, ["flower", "red", "museum", "chair"])
    }
}
