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

    func testCatalogAssetLookupByID() throws {
        let first = try XCTUnwrap(ReferenceCatalog.items.first)
        XCTAssertEqual(ReferenceCatalog.asset(id: first.id)?.assetName, first.assetName)
        XCTAssertNil(ReferenceCatalog.asset(id: UUID()))
    }

    func testTypesenseFilterEscapingAndRelativeTextScoring() async throws {
        let topID = UUID()
        let secondID = UUID()
        var capturedBody: Data?

        let session = makeMockSession { request in
            capturedBody = Self.requestBody(from: request)
            let payload: [String: Any] = [
                "results": [[
                    "hits": [
                        [
                            "document": ["id": topID.uuidString, "pinID": "pin-1", "title": "First", "setting": "cafe", "pose": "seated"],
                            "text_match": 578_730_123_365_711_993
                        ],
                        [
                            "document": ["id": secondID.uuidString, "pinID": "pin-2", "title": "Second", "setting": "cafe", "pose": "seated"],
                            "text_match": 289_365_061_682_855_996
                        ]
                    ]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let client = TypesenseClient(
            session: session,
            baseURL: URL(string: "https://typesense.example.test")!,
            apiKey: "test-key",
            collection: "references"
        )
        let hits = try await client.searchText("coffee", setting: "cafe`bar", pose: "seated & relaxed")

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let searches = try XCTUnwrap(json["searches"] as? [[String: Any]])
        XCTAssertEqual(searches.first?["filter_by"] as? String, "setting:=`cafe\\`bar` && pose:=`seated & relaxed`")

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].id, topID)
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 0.001)
        XCTAssertEqual(hits[1].id, secondID)
        XCTAssertEqual(hits[1].score, 0.5, accuracy: 0.01)
    }

    func testTypesenseHTTPErrorThrowsStatusAndBody() async {
        let session = makeMockSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("Forbidden".utf8))
        }
        let client = TypesenseClient(
            session: session,
            baseURL: URL(string: "https://typesense.example.test")!,
            apiKey: "bad-key",
            collection: "references"
        )
        do {
            _ = try await client.searchText("beach")
            XCTFail("Expected HTTP error")
        } catch let TypesenseError.http(code, body) {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(body, "Forbidden")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGeminiReferencePlanDecoding() throws {
        let json = """
        {
          "hasPerson": true,
          "summary": "Stand near the sunlit window.",
          "poseCue": "Turn shoulders slightly away.",
          "framingCue": "Place subject in the left third.",
          "lightCue": "Soft side light from the window.",
          "poseStyle": "leaning",
          "cameraLevel": "chest",
          "tilt": "level",
          "distance": "medium"
        }
        """
        let plan = try JSONDecoder().decode(GeminiReferencePlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.hasPerson)
        XCTAssertEqual(plan.summary, "Stand near the sunlit window.")
        XCTAssertEqual(plan.poseStyle, .leaning)
        XCTAssertEqual(plan.cameraLevel, .chest)
        XCTAssertEqual(plan.tilt, .level)
        XCTAssertEqual(plan.distance, .medium)

        let invalid = json.replacingOccurrences(of: "\"leaning\"", with: "\"flying\"")
        XCTAssertThrowsError(try JSONDecoder().decode(GeminiReferencePlan.self, from: Data(invalid.utf8)))
    }

    private func makeMockSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        MockTypesenseURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTypesenseURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}

private final class MockTypesenseURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
