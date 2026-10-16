import Foundation

/// Tracks per-peer protocol state for download orchestration.
public actor PeerState {
    public var amChoking: Bool = true
    public var amInterested: Bool = false
    public var peerChoking: Bool = true
    public var peerInterested: Bool = false
    public var peerBitfield: Bitfield
    public var supportsExtensions: Bool = false
    public var supportsFastExtension: Bool = false
    public var supportsDHT: Bool = false
    public private(set) var allowedFastPieces: Set<Int> = []
    public private(set) var myAllowedFastPiecesSent: Set<Int> = []
    public private(set) var suggestedPieces: Set<Int> = []

    /// Pending block requests: (pieceIndex, offset, length) → timestamp
    public struct BlockRequest: Hashable, Sendable {
        public let pieceIndex: Int
        public let offset: Int
        public let length: Int
    }
    private var pendingRequests: [BlockRequest: Date] = [:]
    public let maxPipelineDepth: Int

    public private(set) var isSnubbed: Bool = false
    public private(set) var lastBlockReceivedAt: Date = Date()
    public private(set) var downloadRate: Double = 0.0
    public private(set) var uploadRate: Double = 0.0
    public private(set) var desiredQueueSize: Int = 4
    private var bytesReceivedInWindow: Int = 0
    private var bytesSentInWindow: Int = 0

    public init(pieceCount: Int, maxPipelineDepth: Int = 64) {
        self.peerBitfield = Bitfield(count: pieceCount)
        self.maxPipelineDepth = maxPipelineDepth
    }

    public func getPeerBitfield() -> Bitfield {
        peerBitfield
    }

    public func getPeerChoking() -> Bool {
        peerChoking
    }

    public func getAmInterested() -> Bool {
        amInterested
    }

    public var pendingCount: Int {
        pendingRequests.count
    }

    public var effectiveQueueLimit: Int {
        if isSnubbed {
            return 1
        }
        return min(maxPipelineDepth, max(2, desiredQueueSize))
    }

    public var canRequest: Bool {
        pendingRequests.count < effectiveQueueLimit
    }

    public func recordBlockReceived(bytes: Int) {
        lastBlockReceivedAt = Date()
        isSnubbed = false
        bytesReceivedInWindow += bytes
        // Slow-start ramp-up: grow pipeline capacity as blocks arrive
        if desiredQueueSize < maxPipelineDepth {
            desiredQueueSize += 1
        }
    }

    public func recordBlockSent(bytes: Int) {
        bytesSentInWindow += bytes
    }

    public func updateRates(elapsed: Double) {
        guard elapsed > 0 else { return }
        downloadRate = Double(bytesReceivedInWindow) / elapsed
        uploadRate = Double(bytesSentInWindow) / elapsed
        bytesReceivedInWindow = 0
        bytesSentInWindow = 0

        // Bandwidth-Delay Product (BDP) queue sizing with 2.5s target queue time
        if downloadRate > 0 {
            let targetBlocks = Int((downloadRate * 2.5) / 16384.0)
            let clampedTarget = max(2, min(maxPipelineDepth, targetBlocks))
            if desiredQueueSize < clampedTarget {
                desiredQueueSize = min(clampedTarget, desiredQueueSize + 2)
            } else if desiredQueueSize > clampedTarget {
                desiredQueueSize = max(clampedTarget, desiredQueueSize - 1)
            }
        }
    }

    public func checkSnubbing(now: Date = Date(), timeout: TimeInterval = 12.0) -> Bool {
        guard !peerChoking, amInterested, !pendingRequests.isEmpty else { return false }
        if now.timeIntervalSince(lastBlockReceivedAt) > timeout {
            let newlySnubbed = !isSnubbed
            isSnubbed = true
            desiredQueueSize = 1
            return newlySnubbed
        }
        return false
    }

    public func resetSnubbing() {
        isSnubbed = false
        lastBlockReceivedAt = Date()
    }

    public func getPendingRequests() -> [BlockRequest: Date] {
        pendingRequests
    }

    public func hasPending(_ request: BlockRequest) -> Bool {
        pendingRequests[request] != nil
    }

    public func setPeerBitfield(_ bf: Bitfield) {
        peerBitfield = bf
    }

    public func setHave(_ index: Int) {
        peerBitfield.set(index)
    }

    public func setPeerChoking(_ choking: Bool) {
        peerChoking = choking
    }

    public func setPeerInterested(_ interested: Bool) {
        peerInterested = interested
    }

    public func setAmChoking(_ choking: Bool) {
        amChoking = choking
    }

    public func setAmInterested(_ interested: Bool) {
        amInterested = interested
    }

    public func setCapabilities(extensions: Bool, fastExtension: Bool, dht: Bool) {
        self.supportsExtensions = extensions
        self.supportsFastExtension = fastExtension
        self.supportsDHT = dht
    }

    public func addPendingRequest(_ request: BlockRequest) {
        pendingRequests[request] = Date()
    }

    public func removePendingRequest(_ request: BlockRequest) {
        pendingRequests.removeValue(forKey: request)
    }

    public func addAllowedFastPiece(_ pieceIndex: Int) {
        allowedFastPieces.insert(pieceIndex)
    }

    public func isAllowedFast(_ pieceIndex: Int) -> Bool {
        allowedFastPieces.contains(pieceIndex)
    }

    public func addMyAllowedFastPieceSent(_ pieceIndex: Int) {
        myAllowedFastPiecesSent.insert(pieceIndex)
    }

    public func isMyAllowedFastPieceSent(_ pieceIndex: Int) -> Bool {
        myAllowedFastPiecesSent.contains(pieceIndex)
    }

    public func addSuggestedPiece(_ pieceIndex: Int) {
        suggestedPieces.insert(pieceIndex)
    }

    @discardableResult
    public func clearPendingRequests() -> [BlockRequest] {
        let dropped = Array(pendingRequests.keys)
        pendingRequests.removeAll()
        return dropped
    }

    /// Clear pending requests whose piece is NOT in allowedFastPieces, returning the dropped requests.
    public func clearPendingRequestsExceptAllowedFast() -> [BlockRequest] {
        var dropped: [BlockRequest] = []
        var remaining: [BlockRequest: Date] = [:]
        for (req, date) in pendingRequests {
            if allowedFastPieces.contains(req.pieceIndex) {
                remaining[req] = date
            } else {
                dropped.append(req)
            }
        }
        pendingRequests = remaining
        return dropped
    }

    /// Returns requests older than the given timeout interval.
    public func timedOutRequests(timeout: TimeInterval = 6.0) -> [BlockRequest] {
        let cutoff = Date().addingTimeInterval(-timeout)
        return pendingRequests.filter { $0.value < cutoff }.map(\.key)
    }
}
