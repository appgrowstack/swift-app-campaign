/// A version as up to three numbers. Missing parts count as zero (`3.10` is `3.10.0`).
public struct CampaignVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts.prefix(3) {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

extension CampaignVersion {
    /// The form a set writes (`appVersion` in the schema): two or three groups of ASCII digits,
    /// such as `3.3` or `3.3.0`. Stricter than ``init(_:)``, which reads the device's version.
    init?(appVersion text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        self.init(text)
    }
}

/// One platform's range in a set's `app_version`, resolved by core from the campaign's `requires`:
/// every version from `min` up, except the ones in `exclude`.
struct ResolvedVersionRange: Sendable, Equatable {
    let min: CampaignVersion
    let exclude: [CampaignVersion]

    /// `{ "min": "3.3.0", "exclude": ["3.4.0"] }`. Other keys are ignored.
    init?(_ json: JSONValue) {
        guard let object = json.object,
              let min = object["min"]?.string.flatMap(CampaignVersion.init(appVersion:)),
              let items = object["exclude"]?.array else { return nil }
        var exclude: [CampaignVersion] = []
        for item in items {
            guard let version = item.string.flatMap(CampaignVersion.init(appVersion:)) else { return nil }
            exclude.append(version)
        }
        self.init(min: min, exclude: exclude)
    }

    init(min: CampaignVersion, exclude: [CampaignVersion] = []) {
        self.min = min
        self.exclude = exclude
    }

    /// `min` or newer, and not one of `exclude` (missing parts count as zero, so `3.4` is `3.4.0`).
    func contains(_ version: CampaignVersion) -> Bool {
        version >= min && !exclude.contains(version)
    }

    /// The whole `app_version` (platform → range). `nil` unless every value is a readable range;
    /// an empty object is valid and matches no platform.
    static func platforms(_ json: JSONValue?) -> [String: ResolvedVersionRange]? {
        guard let object = json?.object else { return nil }
        var ranges: [String: ResolvedVersionRange] = [:]
        for (platform, value) in object {
            guard let range = ResolvedVersionRange(value) else { return nil }
            ranges[platform] = range
        }
        return ranges
    }
}
