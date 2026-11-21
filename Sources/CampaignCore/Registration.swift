import Foundation

/// The type of a value a placement receives. Matches the manifest's `fields.*.type`.
public enum CampaignFieldType: String, Sendable, Codable, CaseIterable {
    /// Text per language. The SDK picks the language and hands the placement a `String`.
    case text
    /// ``CampaignImage``: an image in the app, or an HTTPS image fetched ahead of time.
    case image
    case int
    case bool
    /// A string that is the same in every language (an id, a colour name). Never shown as copy.
    case string
}

/// One value a placement receives.
public struct CampaignField: Sendable, Hashable {
    public var type: CampaignFieldType
    public var required: Bool
    /// Checked by `campaign check` before a set is sent; the SDK only carries it for
    /// ``CampaignManifest/verify(_:against:)``.
    public var maxChars: Int?

    public init(_ type: CampaignFieldType, required: Bool, maxChars: Int? = nil) {
        self.type = type
        self.required = required
        self.maxChars = maxChars
    }

    public static func text(required: Bool = true, maxChars: Int? = nil) -> Self { .init(.text, required: required, maxChars: maxChars) }
    public static func image(required: Bool = false) -> Self { .init(.image, required: required) }
    public static func int(required: Bool = false) -> Self { .init(.int, required: required) }
    public static func bool(required: Bool = false) -> Self { .init(.bool, required: required) }
    public static func string(required: Bool = false) -> Self { .init(.string, required: required) }
}

public enum CampaignPlacementKind: String, Sendable, Codable {
    /// The SDK says "show this now" and the app presents it in its own way.
    case modal
    /// No look of its own: showing it runs the campaign's `on_tap` action at once (the system's
    /// rating prompt). `campaign_tapped` is not recorded.
    case system
}

/// A place in the app that can show a campaign. The app owns its look; a campaign only fills it.
///
/// ```swift
/// struct BannerPlacement: CampaignPlacement {
///     static let name = "banner"
///     static let fields: [String: CampaignField] = [
///         "title": .text(maxChars: 30), "badge": .string(),
///     ]
///     struct Values: Decodable, Sendable {
///         let title: String
///         let badge: String?
///     }
/// }
/// ```
///
/// The types' placements are ready-made in ``CampaignTemplate``.
///
/// `Values` is decoded from the resolved values with snake_case keys turned into camelCase.
public protocol CampaignPlacement {
    associatedtype Values: Decodable & Sendable
    static var name: String { get }
    static var kind: CampaignPlacementKind { get }
    static var fields: [String: CampaignField] { get }
}

extension CampaignPlacement {
    public static var kind: CampaignPlacementKind { .modal }
}

/// A placement as the SDK checks it: a name, a kind and its fields.
public struct CampaignPlacementSpec: Sendable, Hashable {
    public var name: String
    public var kind: CampaignPlacementKind
    public var fields: [String: CampaignField]

    public init(name: String, kind: CampaignPlacementKind = .modal, fields: [String: CampaignField]) {
        self.name = name
        self.kind = kind
        self.fields = fields
    }

    public init<P: CampaignPlacement>(_ placement: P.Type) {
        self.init(name: P.name, kind: P.kind, fields: P.fields)
    }
}

public enum CampaignFactType: String, Sendable, Codable {
    case bool, int, number, string
}

public enum CampaignFactSource: String, Sendable, Codable {
    /// Read on the device. Cheap ones first: conditions are read left to right.
    case device
    /// Asked of the app's own server, only after every device condition has passed.
    case server
}

/// A value about the person that conditions can read.
public struct CampaignFact: Sendable {
    public let name: String
    public let type: CampaignFactType
    public let source: CampaignFactSource
    /// `nil` or a thrown error means "not available": the condition does not match.
    public let read: @Sendable () async throws -> CampaignValue?

    public init(name: String, type: CampaignFactType, source: CampaignFactSource,
                read: @escaping @Sendable () async throws -> CampaignValue?) {
        self.name = name
        self.type = type
        self.source = source
        self.read = read
    }

    public static func device(_ name: String, _ type: CampaignFactType,
                              _ read: @escaping @Sendable () async throws -> CampaignValue?) -> Self {
        .init(name: name, type: type, source: .device, read: read)
    }

    public static func server(_ name: String, _ type: CampaignFactType,
                              _ read: @escaping @Sendable () async throws -> CampaignValue?) -> Self {
        .init(name: name, type: type, source: .server, read: read)
    }
}

public enum CampaignArgumentType: String, Sendable, Codable {
    case string, int, number, bool
}

public struct CampaignArgument: Sendable, Hashable {
    public var type: CampaignArgumentType
    public var required: Bool

    public init(_ type: CampaignArgumentType, required: Bool) {
        self.type = type
        self.required = required
    }
}

/// What a registered action is handed when the primary button of a placement is tapped.
public struct CampaignActionRequest: Sendable {
    public let campaign: String
    public let setVersion: Int
    /// The trigger's id (`after_paywall`), so the action knows where the person came from.
    public let trigger: String
    public let event: CampaignObservedEvent
    public let arguments: [String: CampaignValue]
    /// The product an `open_store_page` names, from the set's `targets`.
    public let target: CampaignTarget?

    public init(campaign: String, setVersion: Int, trigger: String, event: CampaignObservedEvent,
                arguments: [String: CampaignValue], target: CampaignTarget? = nil) {
        self.campaign = campaign
        self.setVersion = setVersion
        self.trigger = trigger
        self.event = event
        self.arguments = arguments
        self.target = target
    }
}

public enum CampaignActionResult: String, Sendable {
    case completed, failed, cancelled
}

/// An action a campaign's `on_tap` can name. The types' actions are ready-made:
/// ``startTrial(_:)``, ``requestReview(_:)`` and ``openStorePage(providerToken:open:)``.
public struct CampaignAction: Sendable {
    public let name: String
    public let arguments: [String: CampaignArgument]
    public let run: @MainActor @Sendable (CampaignActionRequest) async -> CampaignActionResult

    public init(_ name: String, arguments: [String: CampaignArgument] = [:],
                run: @escaping @MainActor @Sendable (CampaignActionRequest) async -> CampaignActionResult) {
        self.name = name
        self.arguments = arguments
        self.run = run
    }
}

/// Everything the app registered, in the shape the checks read. Built by the engine from the
/// placements, facts, actions and assets it is given, or from a manifest (tests and tools).
public struct CampaignRegistry: Sendable, Equatable {
    public struct FactSpec: Sendable, Hashable {
        public var type: CampaignFactType
        public var source: CampaignFactSource
    }

    public var placements: [String: CampaignPlacementSpec]
    public var actions: [String: [String: CampaignArgument]]
    public var facts: [String: FactSpec]
    public var assets: Set<String>

    public init(placements: [CampaignPlacementSpec], actions: [String: [String: CampaignArgument]],
                facts: [String: FactSpec], assets: Set<String>) {
        self.placements = Dictionary(placements.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.actions = actions
        self.facts = facts
        self.assets = assets
    }

    /// Values the SDK knows without the app: they can be used in any audience.
    public static let sdkFacts: [String: FactSpec] = [
        "platform": .init(type: .string, source: .device),
        "app_version": .init(type: .string, source: .device),
        "build": .init(type: .string, source: .device),
        "channel": .init(type: .string, source: .device),
        "lang": .init(type: .string, source: .device),
        "region": .init(type: .string, source: .device),
        "days_since_first_seen": .init(type: .int, source: .device),
        "session_seconds": .init(type: .int, source: .device),
    ]

    func fact(_ name: String) -> FactSpec? { facts[name] ?? Self.sdkFacts[name] }
}
