import Foundation

/// Rarest-first piece selection strategy with sequential streaming priority.
public struct PiecePicker: Sendable {
    private let pieceCount: Int
    private var availability: [Int]  // how many peers have each piece
    public var sequentialEngine: SequentialStreamEngine?

    public init(pieceCount: Int, isStreaming: Bool = false) {
        self.pieceCount = pieceCount
        self.availability = [Int](repeating: 0, count: pieceCount)
        if isStreaming {
            self.sequentialEngine = SequentialStreamEngine(totalPieces: pieceCount)
        }
    }

    /// Configures or updates sequential streaming mode.
    public mutating func setSequentialStreaming(enabled: Bool, currentPlaybackPiece: Int = 0) {
        if enabled {
            self.sequentialEngine = SequentialStreamEngine(
                totalPieces: pieceCount,
                currentPlaybackPiece: currentPlaybackPiece
            )
        } else {
            self.sequentialEngine = nil
        }
    }

    /// Update the current playback piece index for streaming priority window.
    public mutating func setCurrentPlaybackPiece(_ piece: Int) {
        sequentialEngine?.currentPlaybackPiece = max(0, min(piece, pieceCount - 1))
    }

    /// Update availability from a peer's bitfield.
    public mutating func addPeerBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                availability[i] += 1
            }
        }
    }

    /// Remove a peer's bitfield from availability counts.
    public mutating func removePeerBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                availability[i] = max(0, availability[i] - 1)
            }
        }
    }

    /// Increment availability for a single piece (peer sent "have").
    public mutating func addHave(_ pieceIndex: Int) {
        guard pieceIndex >= 0 && pieceIndex < pieceCount else { return }
        availability[pieceIndex] += 1
    }

    /// Pick the next piece to request using rarest-first strategy (or sequential if streaming).
    /// `have` is our own bitfield; `peerHas` is the peer's bitfield.
    public func pick(have: Bitfield, peerHas: Bitfield) -> Int? {
        let candidates = AccelerateEngine.extractAvailableCandidates(have: have, peerHas: peerHas)
        guard !candidates.isEmpty else { return nil }

        if let engine = sequentialEngine {
            if candidates.count >= 64 {
                let priorities = candidates.map { engine.priority(for: $0) }
                let scored = AccelerateEngine.computeStreamingPieceScores(
                    candidateIndices: candidates,
                    availability: availability,
                    sequentialPriorities: priorities
                )
                return scored.min { $0.score < $1.score }?.index
            } else {
                return candidates.min { a, b in
                    let prioA = engine.priority(for: a)
                    let prioB = engine.priority(for: b)
                    if prioA == prioB {
                        return availability[a] < availability[b]
                    }
                    return prioA < prioB
                }
            }
        }

        if candidates.count >= 32 {
            let rarest = AccelerateEngine.findRarestCandidates(availability: availability, candidates: candidates)
            return rarest.randomElement()
        } else {
            var bestAvail = Int.max
            var rarestCandidates: [Int] = []
            for c in candidates {
                let avail = availability[c]
                if avail < bestAvail {
                    bestAvail = avail
                    rarestCandidates = [c]
                } else if avail == bestAvail {
                    rarestCandidates.append(c)
                }
            }
            return rarestCandidates.randomElement()
        }
    }

    /// Pick multiple pieces (for pipelining).
    public func pickMultiple(have: Bitfield, peerHas: Bitfield, count: Int) -> [Int] {
        let candidates = AccelerateEngine.extractAvailableCandidates(have: have, peerHas: peerHas)
        guard !candidates.isEmpty else { return [] }

        if let engine = sequentialEngine {
            if candidates.count >= 64 {
                let priorities = candidates.map { engine.priority(for: $0) }
                let scored = AccelerateEngine.computeStreamingPieceScores(
                    candidateIndices: candidates,
                    availability: availability,
                    sequentialPriorities: priorities
                )
                let sorted = scored.sorted { $0.score < $1.score }
                return Array(sorted.prefix(count).map(\.index))
            } else {
                var candidatePairs = candidates.map { (index: $0, avail: availability[$0]) }
                candidatePairs.sort { a, b in
                    let prioA = engine.priority(for: a.index)
                    let prioB = engine.priority(for: b.index)
                    if prioA == prioB {
                        return a.avail < b.avail
                    }
                    return prioA < prioB
                }
                return Array(candidatePairs.prefix(count).map(\.index))
            }
        } else {
            var candidatePairs = candidates.map { (index: $0, avail: availability[$0]) }
            candidatePairs.sort { $0.avail < $1.avail }
            return Array(candidatePairs.prefix(count).map(\.index))
        }
    }
}
