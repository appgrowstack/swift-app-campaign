import Foundation

// MARK: - Storage

/// What the engine keeps between launches, besides the set itself.
public struct CampaignStoredState: Sendable, Equatable, Codable {
    /// When the set was last fetched or confirmed unchanged (304). Drives `cache_hours`.
    public var fetchedAt: Date?
    public var etag: String?
    public var firstSeenAt: Date
    public var history: CampaignHistory
    /// `campaign|set_version|reason` already sent as `campaign_rejected`, so each is sent once.
    public var reportedRejections: Set<String>
    /// The set version already reported as `campaigns_stale`.
    public var staleReportedVersion: Int?
    /// The app version of the last launch, for `app_updated`.
    public var lastAppVersion: String?
    /// Holdout sides decided on this device. Once decided, a side does not change.
    public var sides: [String: CampaignSide]

    public init(fetchedAt: Date? = nil, etag: String? = nil, firstSeenAt: Date, history: CampaignHistory = .init(),
                reportedRejections: Set<String> = [], staleReportedVersion: Int? = nil,
                lastAppVersion: String? = nil, sides: [String: CampaignSide] = [:]) {
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.firstSeenAt = firstSeenAt
        self.history = history
        self.reportedRejections = reportedRejections
        self.staleReportedVersion = staleReportedVersion
        self.lastAppVersion = lastAppVersion
        self.sides = sides
    }

    enum CodingKeys: String, CodingKey {
        case fetchedAt, etag, firstSeenAt, history, reportedRejections, staleReportedVersion, lastAppVersion, sides
    }

    /// Fields a state saved by an earlier SDK does not have start empty; the history carries over.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        firstSeenAt = try container.decode(Date.self, forKey: .firstSeenAt)
        history = try container.decodeIfPresent(CampaignHistory.self, forKey: .history) ?? .init()
        reportedRejections = try container.decodeIfPresent(Set<String>.self, forKey: .reportedRejections) ?? []
        staleReportedVersion = try container.decodeIfPresent(Int.self, forKey: .staleReportedVersion)
        lastAppVersion = try container.decodeIfPresent(String.self, forKey: .lastAppVersion)
        sides = try container.decodeIfPresent([String: CampaignSide].self, forKey: .sides) ?? [:]
    }
}

public protocol CampaignStorage: Sendable {
    func loadSet() async -> Data?
    func saveSet(_ data: Data) async
    func loadState() async -> CampaignStoredState?
    func saveState(_ state: CampaignStoredState) async
}

/// Files under `<directory>/campaigns/`: `set.json` (the set as fetched) and `state.json`.
public struct FileCampaignStorage: CampaignStorage {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appending(path: "campaigns", directoryHint: .isDirectory)
    }

    public func loadSet() async -> Data? { try? Data(contentsOf: file("set.json")) }
    public func saveSet(_ data: Data) async { write(data, to: "set.json") }

    public func loadState() async -> CampaignStoredState? {
        guard let data = try? Data(contentsOf: file("state.json")) else { return nil }
        return try? Self.decoder.decode(CampaignStoredState.self, from: data)
    }

    public func saveState(_ state: CampaignStoredState) async {
        guard let data = try? Self.encoder.encode(state) else { return }
        write(data, to: "state.json")
    }

    private func file(_ name: String) -> URL { directory.appending(path: name) }

    private func write(_ data: Data, to name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(name), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

extension CampaignStorage where Self == FileCampaignStorage {
    /// `Application Support/campaigns/`.
    public static var applicationSupport: FileCampaignStorage {
        FileCampaignStorage(directory: URL.applicationSupportDirectory)
    }
}

// MARK: - Fetching

public enum CampaignFetchResult: Sendable, Equatable {
    case notModified
    case fetched(Data, etag: String?)
}

public protocol CampaignSetFetching: Sendable {
    /// Throws when the network or the server failed; the engine keeps the set on hand.
    func fetch(etag: String?) async throws -> CampaignFetchResult
}

/// `GET <endpoint>/<public key>` with `If-None-Match` (ETag `"v<version>"`) and the
/// `AppGrowStack-Client` header (``CampaignSDK/client(platform:appVersion:)``).
public struct HTTPCampaignSetFetcher: CampaignSetFetching {
    /// `https://api.appgrowstack.com/v1/campaigns/sets/`.
    public static let defaultEndpoint = URL(string: "https://api.appgrowstack.com/v1/campaigns/sets/")!
    /// `https://api-staging.appgrowstack.com/v1/campaigns/sets/` (debug builds).
    public static let stagingEndpoint = URL(string: "https://api-staging.appgrowstack.com/v1/campaigns/sets/")!

    public struct Failure: Error, Equatable {
        public let status: Int
        public init(status: Int) { self.status = status }
    }

    public let url: URL
    /// The `AppGrowStack-Client` header value.
    public let client: String
    private let session: URLSession

    /// - Parameter client: the `AppGrowStack-Client` header, from ``CampaignSDK/client(platform:appVersion:)``.
    public init(publicKey: String, endpoint: URL = defaultEndpoint, client: String, session: URLSession = .shared) {
        self.url = endpoint.appending(path: publicKey)
        self.client = client
        self.session = session
    }

    public func fetch(etag: String?) async throws -> CampaignFetchResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.setValue(client, forHTTPHeaderField: CampaignSDK.clientHeader)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return .fetched(data, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
        case 304: return .notModified
        default: throw Failure(status: status)
        }
    }
}

// MARK: - Clock

public protocol CampaignClock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async throws
}

public struct SystemCampaignClock: CampaignClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

// MARK: - Images

/// Fetches HTTPS images when a set arrives, so a campaign is never shown with its image missing.
public protocol CampaignImagePrefetching: Sendable {
    /// `true` when the image is ready to show.
    func prefetch(_ url: URL) async -> Bool
}

/// Loads into `URLCache.shared`, where `AsyncImage` and `URLSession` find it.
public struct URLSessionImagePrefetcher: CampaignImagePrefetching {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func prefetch(_ url: URL) async -> Bool {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - Events in

/// The port the app's analytics feeds. Wrap it as one more destination of the analytics client;
/// the SDK depends on no analytics package.
public protocol CampaignEventObserving: Sendable {
    /// Returns at once. The decision runs in the background and never affects the caller.
    /// Pass the values with their types (``CampaignValue/init(any:)`` reads `[String: Any]`).
    func observe(_ name: String, _ props: [String: CampaignValue])
}
