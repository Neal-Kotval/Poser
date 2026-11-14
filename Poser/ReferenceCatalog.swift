import Foundation
import UIKit

struct ReferenceAsset: Identifiable {
    let id: UUID
    let title: String
    let assetName: String
    let credit: String
    let license: String
    let source: URL?

    var image: UIImage? { UIImage(named: assetName) }
}

enum ReferenceCatalog {
    static let items: [ReferenceAsset] = [
        .init(id: UUID(uuidString: "D9355526-A2BC-4941-9EB4-E3F60E85859D")!, title: "Street portrait", assetName: "InspirationPortrait", credit: "Poser sample", license: "Demo image", source: nil),
        .init(id: UUID(uuidString: "18E9BC57-10C6-41DB-83CE-C72AFFC6DFA1")!, title: "Against the wall", assetName: "ReferenceStreet", credit: "Aaron Burson", license: "CC0", source: URL(string: "https://commons.wikimedia.org/wiki/File:Upcycle_(Unsplash).jpg")),
        .init(id: UUID(uuidString: "55A65A18-2014-44F9-AD39-71B3E8227C03")!, title: "City light", assetName: "ReferenceWarm", credit: "Kat Hennessey", license: "CC BY-SA 4.0", source: URL(string: "https://commons.wikimedia.org/wiki/File:Sydney_Morton_Street_Portrait_in_camel_top_shot_in_Los_Angeles_by_Kat_Hennessey.jpg")),
        .init(id: UUID(uuidString: "BFC4B03B-41AD-4927-9FC0-A55CE7481A4A")!, title: "At the doorway", assetName: "ReferenceDoorway", credit: "Giuseppe Milo", license: "CC BY 2.0", source: URL(string: "https://commons.wikimedia.org/wiki/File:Elisa_-_Ostuni,_Italy_-_Portrait_photography_(29565184222).jpg")),
        .init(id: UUID(uuidString: "CEB015CF-D494-47E1-9F10-43AF89EBCE45")!, title: "Open air", assetName: "ReferenceOutdoor", credit: "Paramanu Sarkar", license: "CC BY-SA 4.0", source: URL(string: "https://commons.wikimedia.org/wiki/File:Shepherd_from_Rajasthan_03.jpg")),
        .init(id: UUID(uuidString: "256BA99A-7A19-4CA1-B4C3-B95D4B4BF783")!, title: "Market portrait", assetName: "ReferenceMarket", credit: "Wilfredor", license: "CC0", source: URL(string: "https://commons.wikimedia.org/wiki/File:Fishmonger_smiling,_Maracaibo_street_market,_Venezuela.jpg")),
        .init(id: UUID(uuidString: "CD16D76B-66B0-4D6F-A946-2EB0BB096190")!, title: "Side light", assetName: "ReferenceSide", credit: "Pedro Ribeiro Simões", license: "CC BY 2.0", source: URL(string: "https://commons.wikimedia.org/wiki/File:Girl_Portrait_Photography_(49833359227).jpg"))
    ]
}
