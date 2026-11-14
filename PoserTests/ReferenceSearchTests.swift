import XCTest
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
}
