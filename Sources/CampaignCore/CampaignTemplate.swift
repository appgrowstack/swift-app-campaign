import Foundation

/// The default placements of the campaign types, the same as `schema/inapp/templates/<type>.json`.
/// A manifest placement that names a `template` must have the same kind and fields.
///
/// ```swift
/// CampaignEngine(
///     …,
///     placements: [CampaignTemplate.TrialOffer.self, CampaignTemplate.ReviewAsk.self],
///     actions: [
///         .startTrial { request in await trial.run(request) },
///         .requestReview { await review.request() },
///     ],
///     …
/// )
/// ```
public enum CampaignTemplate {
    /// `trial_offer` (modal): the app's own card that offers a trial. Action: `start_trial`.
    public struct TrialOffer: CampaignPlacement {
        public static let name = "trial_offer"
        public static let fields: [String: CampaignField] = [
            "headline": .text(maxChars: 24), "body": .text(maxChars: 120),
            "primary_label": .text(maxChars: 24), "secondary_label": .text(maxChars: 12),
            "image": .image(),
        ]

        public struct Values: Decodable, Sendable, Equatable {
            public let headline: String
            public let body: String
            public let primaryLabel: String
            public let secondaryLabel: String
            public let image: CampaignImage?
        }
    }

    /// `review_ask` (system): no look; showing it runs `request_review` (the system's rating prompt).
    public struct ReviewAsk: CampaignPlacement {
        public static let name = "review_ask"
        public static let kind: CampaignPlacementKind = .system
        public static let fields: [String: CampaignField] = [:]

        public struct Values: Decodable, Sendable, Equatable {}
    }

    /// `whats_new` (modal): what changed in this version. Tapping follows a link or an app action.
    public struct WhatsNew: CampaignPlacement {
        public static let name = "whats_new"
        public static let fields: [String: CampaignField] = [
            "headline": .text(maxChars: 20), "body": .text(maxChars: 60),
            "image": .image(), "primary_label": .text(required: false, maxChars: 16),
        ]

        public struct Values: Decodable, Sendable, Equatable {
            public let headline: String
            public let body: String
            public let image: CampaignImage?
            public let primaryLabel: String?
        }
    }

    /// `cross_promo` (modal): another product of the same owner. Action: `open_store_page`.
    public struct CrossPromo: CampaignPlacement {
        public static let name = "cross_promo"
        public static let fields: [String: CampaignField] = [
            "headline": .text(maxChars: 24), "body": .text(maxChars: 80),
            "icon": .image(required: true), "primary_label": .text(maxChars: 16),
            "secondary_label": .text(required: false, maxChars: 12),
        ]

        public struct Values: Decodable, Sendable, Equatable {
            public let headline: String
            public let body: String
            public let icon: CampaignImage
            public let primaryLabel: String
            public let secondaryLabel: String?
        }
    }

    /// The default placement of a type; `nil` for `custom`.
    public static func placement(for type: CampaignType) -> (any CampaignPlacement.Type)? {
        switch type {
        case .trialOffer: TrialOffer.self
        case .reviewAsk: ReviewAsk.self
        case .whatsNew: WhatsNew.self
        case .crossPromo: CrossPromo.self
        case .custom: nil
        }
    }

    /// The default action names and arguments of a type (`whats_new` and `custom` have none).
    public static func actions(for type: CampaignType) -> [String: [String: CampaignArgument]] {
        switch type {
        case .trialOffer: [CampaignAction.startTrialName: [:]]
        case .reviewAsk: [CampaignAction.requestReviewName: [:]]
        case .crossPromo: [CampaignAction.openStorePageName: ["target": CampaignArgument(.string, required: true)]]
        case .whatsNew, .custom: [:]
        }
    }
}

extension CampaignAction {
    public static let startTrialName = "start_trial"
    public static let requestReviewName = "request_review"
    public static let openStorePageName = "open_store_page"

    /// `start_trial` (trial_offer): the app starts the trial, shows what follows, and returns
    /// to what the person was doing. Returns how it ended.
    public static func startTrial(
        _ run: @escaping @MainActor @Sendable (CampaignActionRequest) async -> CampaignActionResult
    ) -> Self {
        CampaignAction(startTrialName, run: run)
    }

    /// `request_review` (review_ask): opens the system's rating prompt. Whether it appeared cannot
    /// be known, so the result is always `completed`.
    public static func requestReview(_ request: @escaping @MainActor @Sendable () async -> Void) -> Self {
        CampaignAction(requestReviewName) { _ in
            await request()
            return .completed
        }
    }

    /// `open_store_page` (cross_promo): opens the App Store page of the set's `targets[target]`, with
    /// the campaign's id as the campaign token (`ct`) and your provider token (`pt`). The engine
    /// records `link_opened(kind=store_page)` when it completed.
    public static func openStorePage(
        providerToken: String? = nil,
        open: @escaping @MainActor @Sendable (URL) async -> Bool
    ) -> Self {
        CampaignAction(openStorePageName, arguments: ["target": CampaignArgument(.string, required: true)]) { request in
            guard let target = request.target,
                  let url = storePageURL(for: target, campaign: request.campaign, providerToken: providerToken)
            else { return .failed }
            return await open(url) ? .completed : .failed
        }
    }

    /// `https://apps.apple.com/app/id<id>?pt=<provider>&ct=<campaign>&mt=8`; `nil` without an App Store id.
    public static func storePageURL(for target: CampaignTarget, campaign: String, providerToken: String?) -> URL? {
        guard let id = target.appStoreID else { return nil }
        var components = URLComponents(string: "https://apps.apple.com/app/id\(id)")
        var items: [URLQueryItem] = []
        if let providerToken { items.append(URLQueryItem(name: "pt", value: providerToken)) }
        items.append(URLQueryItem(name: "ct", value: campaign))
        items.append(URLQueryItem(name: "mt", value: "8"))
        components?.queryItems = items
        return components?.url
    }
}
