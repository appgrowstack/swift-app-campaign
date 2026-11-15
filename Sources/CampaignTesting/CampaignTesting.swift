import CampaignCore
import Foundation

/// Answers fetches from a queue. With nothing queued it fails like a device with no network.
public actor FakeCampaignSetFetcher: CampaignSetFetching {
    public enum Response: Sendable {
        case set(Data, etag: String?)
        case notModified
        case offline
        case status(Int)
    }

    public struct Offline: Error {}

    private var queue: [Response]
    public private(set) var requestedETags: [String?] = []

    public init(_ responses: [Response] = []) { self.queue = responses }

    public func enqueue(_ response: Response) { queue.append(response) }

    /// Queues a set given as JSON text.
    public func enqueue(json: String, etag: String? = nil) { queue.append(.set(Data(json.utf8), etag: etag)) }

    public func fetch(etag: String?) async throws -> CampaignFetchResult {
        requestedETags.append(etag)
        guard !queue.isEmpty else { throw Offline() }
        switch queue.removeFirst() {
        case .set(let data, let etag): return .fetched(data, etag: etag)
        case .notModified: return .notModified
        case .offline: throw Offline()
        case .status(let status): throw HTTPCampaignSetFetcher.Failure(status: status)
        }
    }
}

/// A clock that moves only when told. `sleep` moves it forward instead of waiting.
public final class FakeCampaignClock: CampaignClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ now: Date = Date(timeIntervalSince1970: 1_765_000_000)) { current = now }

    public var now: Date { lock.withLock { current } }

    public func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    public func set(_ date: Date) { lock.withLock { current = date } }

    public func sleep(seconds: Double) async throws {
        advance(by: seconds)
        await Task.yield()
    }
}

/// Storage in memory. Keep one instance to act as the next launch of the same app.
public actor InMemoryCampaignStorage: CampaignStorage {
    public private(set) var setData: Data?
    public private(set) var state: CampaignStoredState?

    public init(setData: Data? = nil, state: CampaignStoredState? = nil) {
        self.setData = setData
        self.state = state
    }

    public func loadSet() async -> Data? { setData }
    public func saveSet(_ data: Data) async { setData = data }
    public func loadState() async -> CampaignStoredState? { state }
    public func saveState(_ state: CampaignStoredState) async { self.state = state }
}

/// Collects what the engine hands to `record`.
public final class CampaignEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CampaignEvent] = []

    public init() {}

    public var events: [CampaignEvent] { lock.withLock { stored } }
    public var names: [String] { events.map(\.name) }

    public func events(named name: String) -> [CampaignEvent] { events.filter { $0.name == name } }

    public func clear() { lock.withLock { stored.removeAll() } }

    /// Pass as the engine's `record`.
    public var record: @Sendable (CampaignEvent) -> Void {
        { [weak self] event in self?.lock.withLock { self?.stored.append(event) } }
    }
}

/// Images that are ready (or not) without the network.
public struct FakeImagePrefetcher: CampaignImagePrefetching {
    public let available: Set<URL>?

    /// `nil`: every image is ready.
    public init(available: Set<URL>? = nil) { self.available = available }

    public func prefetch(_ url: URL) async -> Bool { available?.contains(url) ?? true }
}
