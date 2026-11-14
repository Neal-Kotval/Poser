import XCTest
@testable import Poser

final class ReferenceSearchTests: XCTestCase {
    func testLocalTextFallbackFindsBeachWithoutTypesense() async {
        // With no Secrets/Typesense.plist, search stays on the local catalog.
        XCTAssertFalse(TypesenseConfig.isConfigured)
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
}
