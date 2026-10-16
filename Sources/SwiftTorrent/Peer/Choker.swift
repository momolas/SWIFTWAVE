import Foundation
import Synchronization

/// Tit-for-Tat Choking Algorithm matching libtorrent's choker.cpp (BEP-3).
/// Dynamically allocates upload slots based on download throughput received from peers
/// (or upload throughput when seeding) and rotates an optimistic unchoke slot every 30 seconds.
public final class Choker: Sendable {
    public struct PeerCandidate: Sendable {
        public let key: String
        public let isInterested: Bool
        public let amChoking: Bool
        public let downloadRate: Double
        public let uploadRate: Double
        public let isSeed: Bool

        public init(
            key: String,
            isInterested: Bool,
            amChoking: Bool,
            downloadRate: Double,
            uploadRate: Double,
            isSeed: Bool
        ) {
            self.key = key
            self.isInterested = isInterested
            self.amChoking = amChoking
            self.downloadRate = downloadRate
            self.uploadRate = uploadRate
            self.isSeed = isSeed
        }
    }

    public struct Decision: Sendable {
        public let peersToUnchoke: [String]
        public let peersToChoke: [String]

        public init(peersToUnchoke: [String], peersToChoke: [String]) {
            self.peersToUnchoke = peersToUnchoke
            self.peersToChoke = peersToChoke
        }
    }

    public let maxUploadSlots: Int

    private struct State {
        var optimisticPeerKey: String?
        var lastOptimisticRotation: Date = .distantPast
    }
    private let state = Mutex(State())

    public init(maxUploadSlots: Int = 4) {
        self.maxUploadSlots = max(2, maxUploadSlots)
    }

    public func evaluate(
        candidates: [PeerCandidate],
        isSeeding: Bool,
        now: Date = Date()
    ) -> Decision {
        // Only consider peers that are interested in downloading from us
        let interested = candidates.filter { $0.isInterested }
        if interested.isEmpty {
            // No one is interested: choke all unchoked peers to conserve bandwidth
            let toChoke = candidates.filter { !$0.amChoking }.map(\.key)
            return Decision(peersToUnchoke: [], peersToChoke: toChoke)
        }

        // Rank peers
        let ranked: [PeerCandidate]
        if isSeeding {
            // When seeding, unchoke peers that can download fastest from us (highest uploadRate)
            ranked = interested.sorted { $0.uploadRate > $1.uploadRate }
        } else {
            // When downloading, Tit-for-Tat: unchoke peers that give us highest download rate
            ranked = interested.sorted { $0.downloadRate > $1.downloadRate }
        }

        let regularSlots = max(1, maxUploadSlots - 1)
        let regularUnchoked = Array(ranked.prefix(regularSlots))
        let regularKeys = Set(regularUnchoked.map(\.key))

        // Optimistic unchoke slot management (rotate every 30 seconds)
        var chosenOptimisticKey: String?
        state.withLock { s in
            let remainingCandidates = interested.filter { !regularKeys.contains($0.key) }
            if !remainingCandidates.isEmpty {
                let shouldRotate = now.timeIntervalSince(s.lastOptimisticRotation) >= 30.0 ||
                                   s.optimisticPeerKey == nil ||
                                   !remainingCandidates.contains(where: { $0.key == s.optimisticPeerKey })
                if shouldRotate {
                    s.optimisticPeerKey = remainingCandidates.randomElement()?.key
                    s.lastOptimisticRotation = now
                }
                chosenOptimisticKey = s.optimisticPeerKey
            } else {
                s.optimisticPeerKey = nil
            }
        }

        var unchokeSet = regularKeys
        if let chosenOptimisticKey {
            unchokeSet.insert(chosenOptimisticKey)
        }

        var peersToUnchoke: [String] = []
        var peersToChoke: [String] = []

        for candidate in candidates {
            if unchokeSet.contains(candidate.key) {
                if candidate.amChoking {
                    peersToUnchoke.append(candidate.key)
                }
            } else {
                if !candidate.amChoking {
                    peersToChoke.append(candidate.key)
                }
            }
        }

        return Decision(peersToUnchoke: peersToUnchoke, peersToChoke: peersToChoke)
    }
}
