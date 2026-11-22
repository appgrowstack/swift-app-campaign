/// The holdout assignment (R3). The same formula as notify's `hash32`: FNV-1a over UTF-16 code
/// units, followed by murmur3's final mix, so the server and both SDKs put a person on the same side.
public enum CampaignHash {
    public static func hash32(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for unit in input.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
        }
        hash ^= hash >> 16
        hash = hash &* 0x85ebca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2ae35
        hash ^= hash >> 16
        return hash
    }

    /// `hash32("<project>:<person>:<campaign>:holdout") / 2^32`, in `[0, 1)`.
    public static func unit(project: String, person: String, campaign: String) -> Double {
        Double(hash32("\(project):\(person):\(campaign):holdout")) / 4_294_967_296
    }

    /// The variant of a campaign with variants (R10 P5), for a person on the shown side: the first
    /// index `i` with `weights[i] > 0` and `h × Σweights < Σweights[0...i] × 2^32`, where
    /// `h = hash32("<project>:<person>:<campaign>:variant")`. An internal device gets the first
    /// variant whose weight is above 0.
    public static func variantIndex(project: String, person: String, campaign: String, weights: [Int],
                                    internalDevice: Bool) -> Int {
        if internalDevice { return weights.firstIndex { $0 > 0 } ?? 0 }
        return weightedIndex(hash32("\(project):\(person):\(campaign):variant"), weights: weights)
    }

    /// Integer math, so the server and both SDKs pick the same index. A weight of 0 is never picked.
    static func weightedIndex(_ h: UInt32, weights: [Int]) -> Int {
        let total = UInt64(weights.reduce(0, +))
        var cumulative: UInt64 = 0
        for (index, weight) in weights.enumerated() {
            cumulative += UInt64(weight)
            if weight > 0, UInt64(h) * total < cumulative << 32 { return index }
        }
        return weights.lastIndex { $0 > 0 } ?? 0
    }

    /// The share of people in the product-wide holdout (R10).
    public static let globalHoldout = 0.05

    /// `hash32("<project>:<person>:global_holdout") / 2^32`, in `[0, 1)`.
    public static func globalUnit(project: String, person: String) -> Double {
        Double(hash32("\(project):\(person):global_holdout")) / 4_294_967_296
    }

    /// Rounds to 6 decimal places, the precision the shared cases and the server compare.
    static func round6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    /// `holdout` when `unit < holdout`. An internal device is always `treatment`.
    public static func side(project: String, person: String, campaign: String, holdout: Double,
                            internalDevice: Bool) -> CampaignSide {
        guard !internalDevice, holdout > 0 else { return .treatment }
        return unit(project: project, person: person, campaign: campaign) < holdout ? .holdout : .treatment
    }
}
