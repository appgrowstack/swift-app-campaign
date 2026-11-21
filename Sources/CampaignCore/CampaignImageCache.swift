import Foundation

/// The campaign images fetched ahead in this launch. A campaign whose image is not here is not shown
/// (`image_not_ready`), so a placement never opens with a blank image.
@MainActor
final class CampaignImageCache {
    private let images: any CampaignImagePrefetching
    /// The image URLs that were fetched in this launch.
    private(set) var ready: Set<URL> = []

    init(images: any CampaignImagePrefetching) {
        self.images = images
    }

    /// Fetches every `url` image of the set that is not ready yet, one at a time.
    func prefetch(_ set: CampaignSet) async {
        for campaign in set.campaigns {
            for value in campaign.values.values {
                guard let image = CampaignImage(json: value), case .url(let url, _, _) = image,
                      !ready.contains(url) else { continue }
                if await images.prefetch(url) { ready.insert(url) }
            }
        }
    }
}
