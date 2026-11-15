import Foundation
import Testing
@testable import CampaignCore

/// Runs every case in `schema/cases` (copied by `scripts/sync-cases.sh`). Kotlin and the server
/// read the same files, so a difference in the decision fails on every side.
struct SharedCasesTests {
    static let directory = Bundle.module.url(forResource: "Cases", withExtension: nil)!

    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }()

    @Test func thereAreCases() {
        #expect(Self.names.count >= 30)
    }

    @Test(arguments: names)
    func sharedCase(_ name: String) async throws {
        let json = try #require(JSONValue.parse(Data(contentsOf: Self.directory.appending(path: "\(name).json")))?.object)
        let result = try await Self.run(json)
        let expect = try #require(json["expect"]?.object)

        #expect(result.show.map(JSONValue.string) ?? .null == expect["show"], "show")
        #expect(result.trigger.map(JSONValue.string) ?? .null == expect["trigger"], "trigger")
        if let values = expect["values"] {
            #expect(result.values == values, "values")
        }
        #expect(JSONValue.object(result.outcomes.mapValues(JSONValue.string)) == expect["outcomes"], "outcomes")
        let expectedRecords = (expect["records"]?.array ?? []).map(Self.canonical).sorted()
        #expect(result.records.map(Self.canonical).sorted() == expectedRecords, "records")
        if let read = expect["server_facts_read"] {
            #expect(JSONValue.array(result.serverFactsRead.map(JSONValue.string)) == read, "server_facts_read")
        }
    }

    @Test func hashVectors() throws {
        let file = Self.directory.appending(path: "vectors/hash32.json")
        let vectors = try #require(JSONValue.parse(Data(contentsOf: file))?.object?["vectors"]?.array)
        for vector in vectors {
            let input = try #require(vector.object?["input"]?.string)
            let expected = try #require(vector.object?["hash32"]?.int)
            #expect(Int(CampaignHash.hash32(input)) == expected, "\(input)")
        }
    }

    // MARK: - Running one case

    struct Result {
        var show: String?
        var trigger: String?
        var values: JSONValue = .null
        var outcomes: [String: String] = [:]
        var records: [JSONValue] = []
        var serverFactsRead: [String] = []
    }

    static func run(_ json: [String: JSONValue]) async throws -> Result {
        let manifestName = try need(json["manifest"]?.string)
        let manifest = try CampaignManifest(contentsOf: directory.appending(path: "manifests/\(manifestName).json"))
        let registry = manifest.registry

        let data: Data
        if let raw = json["set_raw"]?.string { data = Data(raw.utf8) } else { data = try JSONEncoder().encode(try need(json["set"])) }

        var result = Result()
        let set: CampaignSet
        switch CampaignSetLoader.load(data, registry: registry) {
        case .unusable(let version, let reason):
            result.records = [event(.rejected("_set", version: version, reason: reason))]
            return result
        case .loaded(let loaded, let rejections):
            set = loaded
            for rejection in rejections {
                result.outcomes[rejection.campaign] = CampaignOutcome.rejected(rejection.reason).code
                result.records.append(event(.rejected(rejection.campaign, version: loaded.version, reason: rejection.reason)))
            }
        }

        let context = try need(json["context"]?.object)
        let history = try need(json["history"]?.object)
        let facts = (json["facts"]?.object ?? [:]).compactMapValues(\.scalar)
        let texts = (json["texts"]?.object ?? [:]).compactMapValues(\.string)
        let eventJSON = try need(json["event"]?.object)

        let input = CampaignDecisionInput(
            set: set,
            registry: registry,
            fetchedAt: try date(json["fetched_at"]),
            now: try date(json["now"]),
            context: CampaignContext(
                platform: try need(context["platform"]?.string),
                appVersion: try need(context["app_version"]?.string),
                build: try need(context["build"]?.string),
                channel: try need(context["channel"]?.string),
                lang: try need(context["lang"]?.string),
                region: try need(context["region"]?.string),
                timeZone: try need(context["time_zone"]?.string.flatMap(TimeZone.init(identifier:))),
                internalDevice: context["internal_device"]?.bool ?? false
            ),
            person: try need(json["person"]?.string),
            daysSinceFirstSeen: context["days_since_first_seen"]?.int ?? 0,
            history: CampaignHistory(
                shownAt: try (history["shown_at"]?.array ?? []).map { try date($0) },
                campaigns: try (history["campaigns"]?.object ?? [:]).mapValues { value in
                    let record = try need(value.object)
                    return CampaignRecord(
                        shownCount: record["shown_count"]?.int ?? 0,
                        lastShownAt: try optionalDate(record["last_shown_at"]),
                        dismissedAt: try optionalDate(record["dismissed_at"]),
                        actionCompletedAt: try optionalDate(record["action_completed_at"])
                    )
                }
            ),
            sessionShown: history["session_shown"]?.int ?? 0,
            event: CampaignTriggerEvent(
                name: try need(eventJSON["name"]?.string),
                properties: (eventJSON["props"]?.object ?? [:]).compactMapValues(\.scalar)
            ),
            texts: { texts[$0] },
            imagesReady: Set((json["images_ready"]?.array ?? []).compactMap { $0.string.flatMap(URL.init(string:)) })
        )

        let decision = await CampaignRules.decide(input) { facts[$0] }
        result.show = decision.shown?.campaign.id
        result.trigger = decision.shown?.trigger
        if let values = decision.shown?.values {
            result.values = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(values))
        }
        for (id, outcome) in decision.outcomes { result.outcomes[id] = outcome.code }
        result.records += decision.records.map(event)
        result.serverFactsRead = decision.serverFactsRead
        return result
    }

    struct Missing: Error {}

    static func need<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }

    static func event(_ event: CampaignEvent) -> JSONValue {
        .object(["name": .string(event.name), "params": .object(event.parameters.mapValues { value in
            switch value {
            case .string(let text): .string(text)
            case .int(let number): .int(number)
            case .double(let number): .double(number)
            case .bool(let flag): .bool(flag)
            }
        })])
    }

    static func canonical(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    static func date(_ value: JSONValue?) throws -> Date {
        try need(value?.string.flatMap(CampaignTime.parse))
    }

    static func optionalDate(_ value: JSONValue?) throws -> Date? {
        guard let value, !value.isNull else { return nil }
        return try date(value)
    }
}
