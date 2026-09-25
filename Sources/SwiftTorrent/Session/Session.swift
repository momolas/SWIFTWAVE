import Foundation
import Synchronization

final class AlertBroadcaster: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<any Alert>.Continuation]>([:])

    func post(_ alert: any Alert) {
        let subs = subscribers.withLock { Array($0.values) }
        for sub in subs {
            sub.yield(alert)
        }
    }

    func stream() -> AsyncStream<any Alert> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            subscribers.withLock {
                $0[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.subscribers.withLock {
                    $0.removeValue(forKey: id)
                }
            }
        }
    }

    func finish() {
        let subs = subscribers.withLock {
            let copy = Array($0.values)
            $0.removeAll()
            return copy
        }
        for sub in subs {
            sub.finish()
        }
    }
}

/// Top-level controller for managing torrents.
public actor Session {
    private var settings: SessionSettings
    private var torrents: [InfoHash: TorrentHandle] = [:]
    private var dhtNode: DHTNode?
    private let alertBroadcaster = AlertBroadcaster()
    public let alerts: AsyncStream<any Alert>

    public init(settings: SessionSettings = SessionSettings()) {
        self.settings = settings
        self.alerts = alertBroadcaster.stream()
    }

    /// Real-time multi-subscriber stream of session and torrent alerts.
    public nonisolated func alertStream() -> AsyncStream<any Alert> {
        alertBroadcaster.stream()
    }

    /// Add a torrent to the session.
    public func addTorrent(_ params: AddTorrentParams) async throws -> TorrentHandle {
        guard let hash = params.infoHash else {
            throw AddTorrentError.noInfoHash
        }
        if let existing = torrents[hash] {
            await resumeIfNeeded(existing, paused: params.paused)
            return existing
        }

        if settings.dhtEnabled && dhtNode == nil {
            try? await startDHT()
        }

        // Re-check after async suspension in startDHT()
        if let existing = torrents[hash] {
            await resumeIfNeeded(existing, paused: params.paused)
            return existing
        }

        let handle = try TorrentHandle(params: params, settings: settings, dhtNode: dhtNode)
        let broadcaster = self.alertBroadcaster
        await handle.setOnAlert { alert in
            broadcaster.post(alert)
        }
        await handle.finishInitialization()
        torrents[hash] = handle

        alertBroadcaster.post(TorrentAddedAlert(
            infoHash: hash,
            name: params.torrentInfo?.name ?? params.magnetLink?.displayName ?? "Unknown"
        ))

        if !params.paused {
            try await handle.start()
        }

        return handle
    }

    /// Remove a torrent from the session.
    public func removeTorrent(_ infoHash: InfoHash, deleteFiles: Bool = false) async {
        guard let handle = torrents.removeValue(forKey: infoHash) else { return }
        await handle.pause()

        if deleteFiles {
            let torrentName = await handle.getTorrentName()
            let savePath = await handle.getSavePath()
            // Only delete the torrent's specific file/directory, never the whole savePath folder
            if !torrentName.isEmpty && torrentName != "." && torrentName != ".." && torrentName != "/" {
                let targetURL = URL(filePath: savePath).appending(path: torrentName)
                try? FileManager.default.removeItem(at: targetURL)
                let partURL = URL(filePath: savePath).appending(path: torrentName + ".part")
                try? FileManager.default.removeItem(at: partURL)
            }
        }

        alertBroadcaster.post(TorrentRemovedAlert(infoHash: infoHash))
    }

    /// Get a torrent handle by info hash.
    public func torrent(for infoHash: InfoHash) -> TorrentHandle? {
        torrents[infoHash]
    }

    /// Get all torrent handles.
    public func allTorrents() -> [TorrentHandle] {
        Array(torrents.values)
    }

    /// Get status of all torrents.
    public func allStatus() async -> [TorrentStatus] {
        var statuses: [TorrentStatus] = []
        for handle in torrents.values {
            statuses.append(await handle.status())
        }
        return statuses
    }

    /// Update session settings.
    public func updateSettings(_ newSettings: SessionSettings) {
        self.settings = newSettings
    }

    /// Start DHT if enabled.
    public func startDHT() async throws {
        guard settings.dhtEnabled else { return }
        let node = DHTNode(port: settings.dhtPort)
        try await node.start()
        self.dhtNode = node
    }

    /// Pause all torrents.
    public func pauseAll() async {
        for handle in torrents.values {
            await handle.pause()
        }
    }

    /// Resume all torrents.
    public func resumeAll() async throws {
        for handle in torrents.values {
            try await handle.resume()
        }
    }

    /// Real-time stream of all torrent statuses for SwiftUI and reactive observers.
    public nonisolated func statusStream(interval: TimeInterval = 1.0) -> AsyncStream<[TorrentStatus]> {
        let clampedInterval = max(0.1, interval)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    let statuses = await self.allStatus()
                    continuation.yield(statuses)
                    try? await Task.sleep(for: .seconds(clampedInterval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Returns the trackers list for a given torrent infoHash.
    public func trackers(for infoHash: InfoHash) async -> [TrackerEntry] {
        guard let handle = torrents[infoHash] else { return [] }
        return await handle.getTrackers()
    }

    /// Add a tracker to an active torrent.
    public func addTracker(urlString: String, to infoHash: InfoHash) async {
        guard let handle = torrents[infoHash] else { return }
        await handle.addTracker(urlString: urlString)
    }

    /// Force reannounce an active torrent to all its trackers.
    public func forceReannounce(for infoHash: InfoHash) async {
        guard let handle = torrents[infoHash] else { return }
        await handle.forceReannounce()
    }

    /// Scrape swarm stats for an active torrent across its trackers.
    public func scrape(for infoHash: InfoHash) async -> [String: ScrapeInfo] {
        guard let handle = torrents[infoHash] else { return [:] }
        return await handle.scrape()
    }

    /// Force a full SHA-1 hash recheck of all files on disk for a given torrent.
    public func recheckFiles(for infoHash: InfoHash) async {
        guard let handle = torrents[infoHash] else { return }
        await handle.recheckFiles()
    }

    /// Shutdown the session.
    public func shutdown() async throws {
        await pauseAll()
        alertBroadcaster.finish()
    }

    private func resumeIfNeeded(_ handle: TorrentHandle, paused: Bool) async {
        if !paused {
            try? await handle.resume()
            try? await handle.start()
        }
    }
}

