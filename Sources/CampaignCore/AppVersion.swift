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

/// `">=3.3.0"` or `">=3.3.0 <4.0.0"`, and nothing else.
struct VersionRange: Sendable, Equatable {
    let lower: CampaignVersion
    let upper: CampaignVersion?

    init?(_ text: String) {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts[0].hasPrefix(">="),
              let lower = Self.strict(parts[0].dropFirst(2)) else { return nil }
        self.lower = lower
        if parts.count == 2 {
            guard parts[1].hasPrefix("<"), let upper = Self.strict(parts[1].dropFirst()) else { return nil }
            self.upper = upper
        } else {
            self.upper = nil
        }
    }

    func contains(_ version: CampaignVersion) -> Bool {
        version >= lower && (upper.map { version < $0 } ?? true)
    }

    private static func strict(_ text: Substring) -> CampaignVersion? {
        guard text.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { return nil }
        return CampaignVersion(String(text))
    }
}
