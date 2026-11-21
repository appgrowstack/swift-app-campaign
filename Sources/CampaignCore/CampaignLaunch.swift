import Foundation

/// What a launch starts from: the stored state with the app's own first-launch date and this launch's
/// app version, and the version the app was updated from (when this is the first launch of a newer one).
enum CampaignLaunch {
    struct Start {
        var state: CampaignStoredState
        /// The app version of the previous launch, when this launch runs a newer one.
        var updatedFrom: String?
    }

    static func start(stored: CampaignStoredState?, context: CampaignContext, now: Date) -> Start {
        var state = stored ?? CampaignStoredState(firstSeenAt: now)
        // The app's own first-launch date counts when it is earlier than the one stored here.
        if let given = context.firstSeenAt, given < state.firstSeenAt { state.firstSeenAt = given }
        let current = context.appVersion
        var updatedFrom: String?
        if let last = state.lastAppVersion, let from = CampaignVersion(last), let to = CampaignVersion(current), to > from {
            updatedFrom = last
        }
        state.lastAppVersion = current
        return Start(state: state, updatedFrom: updatedFrom)
    }
}
