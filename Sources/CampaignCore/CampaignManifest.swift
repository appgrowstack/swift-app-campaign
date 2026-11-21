import Foundation

/// The app's `campaigns/manifest.json`: what it registered, for the checks before a set is sent.
public struct CampaignManifest: Sendable, Codable, Equatable {
    public struct Since: Sendable, Codable, Equatable {
        public var ios: String?
        public var android: String?
    }

    public struct Field: Sendable, Codable, Equatable {
        public var type: CampaignFieldType
        public var required: Bool
        public var maxChars: Int?

        enum CodingKeys: String, CodingKey { case type, required, maxChars = "max_chars" }
    }

    public struct Placement: Sendable, Codable, Equatable {
        /// `modal` or `system`. `inline` and `web` are not shown by this SDK.
        public var kind: String
        public var since: Since
        /// The type whose default placement this is (``CampaignTemplate``).
        public var template: CampaignType?
        public var fields: [String: Field]
    }

    public struct Asset: Sendable, Codable, Equatable {
        public var since: Since
    }

    public struct Argument: Sendable, Codable, Equatable {
        public var type: CampaignArgumentType
        public var required: Bool
    }

    public struct Action: Sendable, Codable, Equatable {
        public var since: Since
        /// The type whose default action this is.
        public var template: CampaignType?
        public var args: [String: Argument]
    }

    public struct Fact: Sendable, Codable, Equatable {
        public var type: CampaignFactType
        public var source: CampaignFactSource
        public var since: Since
    }

    /// The project's id (`gamification-app`).
    public var project: String
    public var placements: [String: Placement]
    public var assets: [String: Asset]
    public var actions: [String: Action]
    public var facts: [String: Fact]
    public var linkHosts: [String]

    enum CodingKeys: String, CodingKey {
        case project, placements, assets, actions, facts, linkHosts = "link_hosts"
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// The registry the manifest describes. Placements of a kind the SDK does not show are left out.
    public var registry: CampaignRegistry {
        CampaignRegistry(
            placements: placements.compactMap { name, placement in
                guard let kind = CampaignPlacementKind(rawValue: placement.kind) else { return nil }
                return CampaignPlacementSpec(name: name, kind: kind, fields: placement.fields.mapValues {
                    CampaignField($0.type, required: $0.required, maxChars: $0.maxChars)
                })
            },
            actions: actions.mapValues { $0.args.mapValues { CampaignArgument($0.type, required: $0.required) } },
            facts: facts.mapValues { .init(type: $0.type, source: $0.source) },
            assets: Set(assets.keys)
        )
    }

    /// Throws when what the app registered differs from its manifest. Call it from the app's tests.
    public static func verify(_ registry: CampaignRegistry, against url: URL) throws {
        try verify(registry, against: CampaignManifest(contentsOf: url))
    }

    public static func verify(_ registry: CampaignRegistry, against manifest: CampaignManifest) throws {
        let expected = manifest.registry
        var differences: [String] = []
        func compare<T: Equatable>(_ area: String, _ registered: [String: T], _ declared: [String: T]) {
            for name in Set(registered.keys).union(declared.keys).sorted() {
                switch (registered[name], declared[name]) {
                case (nil, _?): differences.append("\(area) \(name): in the manifest, not registered")
                case (_?, nil): differences.append("\(area) \(name): registered, not in the manifest")
                case let (lhs?, rhs?) where lhs != rhs: differences.append("\(area) \(name): registered differently from the manifest")
                default: break
                }
            }
        }
        compare("placement", registry.placements, expected.placements)
        compare("action", registry.actions, expected.actions)
        compare("fact", registry.facts, expected.facts)
        compare("asset", Dictionary(uniqueKeysWithValues: registry.assets.map { ($0, true) }),
                Dictionary(uniqueKeysWithValues: expected.assets.map { ($0, true) }))
        differences += manifest.templateDifferences
        if !differences.isEmpty { throw CampaignManifestMismatch(differences: differences) }
    }
}

extension CampaignManifest {
    /// Placements and actions that name a `template` but differ from the type's default.
    public var templateDifferences: [String] {
        var differences: [String] = []
        for name in placements.keys.sorted() {
            guard let placement = placements[name], let type = placement.template else { continue }
            guard let template = CampaignTemplate.placement(for: type) else {
                differences.append("placement \(name): \(type.rawValue) has no default placement")
                continue
            }
            let spec = CampaignPlacementSpec(template)
            let fields = placement.fields.mapValues { CampaignField($0.type, required: $0.required, maxChars: $0.maxChars) }
            if name != spec.name || placement.kind != spec.kind.rawValue || fields != spec.fields {
                differences.append("placement \(name): differs from the \(type.rawValue) template")
            }
        }
        for name in actions.keys.sorted() {
            guard let action = actions[name], let type = action.template else { continue }
            let args = action.args.mapValues { CampaignArgument($0.type, required: $0.required) }
            if CampaignTemplate.actions(for: type)[name] != args {
                differences.append("action \(name): differs from the \(type.rawValue) template")
            }
        }
        return differences
    }
}

public struct CampaignManifestMismatch: Error, CustomStringConvertible, Equatable {
    public let differences: [String]
    public var description: String { differences.joined(separator: "\n") }
}
