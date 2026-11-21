import Foundation

/// A campaign the engine wants shown now, in the placement it names.
public struct CampaignPresentation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let campaign: String
    public let setVersion: Int
    public let trigger: String
    public let placement: String
    /// Text already in the device's language.
    public let values: [String: CampaignResolvedValue]
    let event: CampaignObservedEvent
    let onTap: CampaignTap

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The values as the placement's own type (snake_case keys become camelCase).
    public func values<Values: Decodable>(as type: Values.Type) throws -> Values {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Values.self, from: JSONEncoder().encode(values))
    }
}

/// What a placement's view is handed: its typed values, and what to call on tap and on close.
public struct CampaignOffer<Placement: CampaignPlacement>: Identifiable {
    public let presentation: CampaignPresentation
    public let values: Placement.Values
    /// The primary button: runs the campaign's action or opens its link.
    public let tap: @MainActor () -> Void
    /// A `survey` answer (``CampaignTemplate/Survey/Values/choices`` id). Records `survey_answered`, then
    /// closes like `tap`.
    public let answer: @MainActor (String) -> Void
    /// Any way of closing: the secondary button, a close button, a swipe, a tap outside.
    public let dismiss: @MainActor (CampaignDismissal) -> Void

    public var id: UUID { presentation.id }
}
