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

    /// `holdout` when `unit < holdout`. An internal device is always `treatment`.
    public static func side(project: String, person: String, campaign: String, holdout: Double,
                            internalDevice: Bool) -> CampaignSide {
        guard !internalDevice, holdout > 0 else { return .treatment }
        return unit(project: project, person: person, campaign: campaign) < holdout ? .holdout : .treatment
    }
}
