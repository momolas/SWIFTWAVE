import Foundation
import CryptoKit
import Synchronization

/// Smart Ban algorithm matching libtorrent's smart_ban.cpp.
/// Instead of banning all peers that contributed to a failed piece, records block hashes
/// and only bans the specific peer whose block failed verification once the piece passes.
public final class SmartBan: Sendable {
    public struct BlockRecord: Sendable, Hashable {
        public let blockHash: Data
        public let peerKey: String

        public init(blockHash: Data, peerKey: String) {
            self.blockHash = blockHash
            self.peerKey = peerKey
        }
    }

    private struct State {
        // pieceIndex -> [blockOffset: BlockRecord]
        var suspectBlocks: [Int: [Int: BlockRecord]] = [:]
        // Banned peer keys / IP addresses
        var bannedPeers: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Record a received block and its SHA-1 hash for smart ban attribution.
    public func recordBlock(pieceIndex: Int, offset: Int, data: Data, peerKey: String) {
        let digest = Insecure.SHA1.hash(data: data)
        let hash = Data(digest)
        state.withLock { s in
            if s.suspectBlocks[pieceIndex] == nil {
                s.suspectBlocks[pieceIndex] = [:]
            }
            s.suspectBlocks[pieceIndex]?[offset] = BlockRecord(blockHash: hash, peerKey: peerKey)
        }
    }

    /// Called when a piece fails hash verification.
    /// Preserves the suspect blocks so they can be compared against the good piece later.
    public func onPieceFailed(pieceIndex: Int) {
        // Suspect blocks are retained in state for subsequent comparison
    }

    /// Called when a piece passes hash verification.
    /// Compares the verified blocks against any previously recorded suspect blocks.
    /// Bans any peer who sent a mismatched block.
    @discardableResult
    public func onPieceVerified(pieceIndex: Int, verifiedData: Data, blockSize: Int = 16384) -> [String] {
        var peersToBan: [String] = []

        state.withLock { s in
            guard let suspects = s.suspectBlocks.removeValue(forKey: pieceIndex) else {
                return
            }

            var offset = 0
            while offset < verifiedData.count {
                let length = min(blockSize, verifiedData.count - offset)
                let chunk = verifiedData.subdata(in: offset..<(offset + length))
                let goodHash = Data(Insecure.SHA1.hash(data: chunk))

                if let suspect = suspects[offset] {
                    if suspect.blockHash != goodHash {
                        // Proven corrupt block sender
                        s.bannedPeers.insert(suspect.peerKey)
                        peersToBan.append(suspect.peerKey)
                    }
                }
                offset += length
            }
        }

        return peersToBan
    }

    /// Check if a peer key is banned.
    public func isBanned(peerKey: String) -> Bool {
        state.withLock { $0.bannedPeers.contains(peerKey) }
    }

    /// Check if a peer IP is banned (supports "address:port" or "address").
    public func isAddressBanned(address: String) -> Bool {
        state.withLock { s in
            s.bannedPeers.contains { banned in
                banned == address || banned.hasPrefix("\(address):")
            }
        }
    }

    /// Clear records for a piece.
    public func clearPiece(pieceIndex: Int) {
        _ = state.withLock { $0.suspectBlocks.removeValue(forKey: pieceIndex) }
    }

    public var bannedCount: Int {
        state.withLock { $0.bannedPeers.count }
    }
}
