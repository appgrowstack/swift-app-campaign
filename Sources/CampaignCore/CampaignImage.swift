import Foundation

/// An image a placement shows: one bundled in the app, or an HTTPS image fetched ahead of time.
public enum CampaignImage: Sendable, Hashable, Codable {
    case asset(String)
    case url(URL, width: Int, height: Int)

    init?(json: JSONValue) {
        guard let object = json.object else { return nil }
        if object.count == 1, let name = object["asset"]?.string, CampaignSetLoader.isName(name) {
            self = .asset(name)
        } else if object.count == 3, let text = object["url"]?.string, let url = URL(string: text),
                  url.scheme == "https", url.host != nil,
                  let width = object["width"]?.int, width > 0, let height = object["height"]?.int, height > 0 {
            self = .url(url, width: width, height: height)
        } else {
            return nil
        }
    }

    enum CodingKeys: String, CodingKey { case asset, url, width, height }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .asset) {
            self = .asset(name)
        } else {
            self = .url(try container.decode(URL.self, forKey: .url),
                        width: try container.decode(Int.self, forKey: .width),
                        height: try container.decode(Int.self, forKey: .height))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .asset(let name):
            try container.encode(name, forKey: .asset)
        case .url(let url, let width, let height):
            try container.encode(url, forKey: .url)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }
}
