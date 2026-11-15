/// The holdout assignment. The same formula as notify's `hash32`: FNV-1a over UTF-16 code units,
/// followed by murmur3's final mix, so the server and both SDKs put a person on the same side.
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

    /// `true` when the person is on the held-out side of a campaign.
    public static func isHeldOut(project: String, person: String, campaign: String, share: Double) -> Bool {
        guard share > 0 else { return false }
        let unit = Double(hash32("\(project):\(person):\(campaign):holdout")) / 4_294_967_296
        return unit < share
    }
}
