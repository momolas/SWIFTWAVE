import Foundation
import Accelerate

/// High-performance SIMD & DSP vector mathematics for TorrentKit using Apple Accelerate.
public enum AccelerateEngine: Sendable {

    // MARK: - 1. Bitfield Fast Candidate Extraction (Word-Level SIMD Acceleration)

    /// Rapidly extracts indices of pieces that `peerHas` but we do not (`!have && peerHas`).
    /// Operates at 64-bit word level, skipping entire 64-piece blocks in a single CPU instruction when diff == 0.
    public static func extractAvailableCandidates(have: Bitfield, peerHas: Bitfield, maxPieces: Int? = nil) -> [Int] {
        let pieceCount = min(have.count, peerHas.count)
        guard pieceCount > 0 else { return [] }

        let wordCount = min(have.storage.count, peerHas.storage.count)
        var candidates: [Int] = []
        candidates.reserveCapacity(min(pieceCount, maxPieces ?? 1024))

        for w in 0..<wordCount {
            var diff = peerHas.storage[w] & ~have.storage[w]
            guard diff != 0 else { continue }

            let baseIndex = w * 64
            while diff != 0 {
                let tz = diff.trailingZeroBitCount
                let pieceIndex = baseIndex + tz
                if pieceIndex < pieceCount {
                    candidates.append(pieceIndex)
                    if let maxPieces, candidates.count >= maxPieces {
                        return candidates
                    }
                }
                diff &= diff - 1 // clear lowest set bit (BLSR instruction)
            }
        }

        return candidates
    }

    // MARK: - 2. Vectorized Piece Scoring & Rarest-First Argmin

    /// Finds candidate piece indices that have the absolute minimum availability using Accelerate SIMD vector reductions.
    public static func findRarestCandidates(availability: [Int], candidates: [Int]) -> [Int] {
        guard !candidates.isEmpty else { return [] }
        if candidates.count == 1 { return candidates }

        // For large candidate sets, vectorize with Accelerate vDSP
        let floatAvail = candidates.map { Float(availability[$0]) }

        var minVal: Float = 0
        vDSP_minv(floatAvail, 1, &minVal, vDSP_Length(floatAvail.count))

        // Collect all candidates matching the minimum availability for fair tie-breaking
        var rarest: [Int] = []
        rarest.reserveCapacity(candidates.count)
        for (idx, cand) in candidates.enumerated() {
            if floatAvail[idx] <= minVal {
                rarest.append(cand)
            }
        }
        return rarest
    }

    /// Computes combined streaming & availability priority scores using Accelerate SIMD multiply-add.
    /// Lower score = higher priority.
    public static func computeStreamingPieceScores(
        candidateIndices: [Int],
        availability: [Int],
        sequentialPriorities: [Int],
        alpha: Float = 0.3,
        beta: Float = 0.7
    ) -> [(index: Int, score: Float)] {
        guard !candidateIndices.isEmpty else { return [] }
        let count = candidateIndices.count

        var availFloats = [Float](repeating: 0, count: count)
        var prioFloats = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let piece = candidateIndices[i]
            availFloats[i] = Float(availability[piece])
            prioFloats[i] = Float(sequentialPriorities[i])
        }

        var weightedAvail = [Float](repeating: 0, count: count)
        var weightedPrio = [Float](repeating: 0, count: count)
        var finalScores = [Float](repeating: 0, count: count)

        // weightedAvail = availFloats * alpha
        var alphaVal = alpha
        vDSP_vsmul(availFloats, 1, &alphaVal, &weightedAvail, 1, vDSP_Length(count))

        // weightedPrio = prioFloats * beta
        var betaVal = beta
        vDSP_vsmul(prioFloats, 1, &betaVal, &weightedPrio, 1, vDSP_Length(count))

        // finalScores = weightedAvail + weightedPrio
        vDSP_vadd(weightedAvail, 1, weightedPrio, 1, &finalScores, 1, vDSP_Length(count))

        var result = [(index: Int, score: Float)]()
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append((index: candidateIndices[i], score: finalScores[i]))
        }
        return result
    }

    // MARK: - 3. Network Telemetry & Throughput DSP Filter

    /// Sliding window rate smoother and jitter estimator backed by vDSP.
    public struct RateSmoother: Sendable {
        private var samples: [Double]
        private let capacity: Int
        private var index: Int = 0
        private var count: Int = 0

        public init(windowSize: Int = 16) {
            self.capacity = max(4, windowSize)
            self.samples = [Double](repeating: 0.0, count: capacity)
        }

        public mutating func addSample(_ rate: Double) {
            samples[index] = max(0.0, rate)
            index = (index + 1) % capacity
            if count < capacity { count += 1 }
        }

        /// Computes smoothed arithmetic mean throughput via vDSP.
        public var smoothedRate: Double {
            guard count > 0 else { return 0.0 }
            var mean: Double = 0.0
            vDSP_meanvD(samples, 1, &mean, vDSP_Length(count))
            return mean
        }

        /// Computes throughput jitter (variance / RMS of rate deviation) via vDSP.
        public var rateJitter: Double {
            guard count > 1 else { return 0.0 }
            let mean = self.smoothedRate
            var diff = [Double](repeating: 0.0, count: count)
            var meanNeg = -mean
            vDSP_vsaddD(samples, 1, &meanNeg, &diff, 1, vDSP_Length(count))

            var rms: Double = 0.0
            vDSP_rmsqvD(diff, 1, &rms, vDSP_Length(count))
            return rms
        }

        /// Computes peak rate in current sliding window.
        public var peakRate: Double {
            guard count > 0 else { return 0.0 }
            var maxVal: Double = 0.0
            vDSP_maxvD(samples, 1, &maxVal, vDSP_Length(count))
            return maxVal
        }
    }

    // MARK: - 4. LEDBAT Rolling Base Delay & Queuing Filter (RFC 6817)

    /// Sliding window base delay filter for LEDBAT congestion control.
    /// Tracks rolling minimum one-way delay and delay jitter via Accelerate vDSP.
    public struct DelayFilter: Sendable {
        private var samples: [Double]
        private let capacity: Int
        private var index: Int = 0
        private var count: Int = 0

        public init(windowSize: Int = 64) {
            self.capacity = max(8, windowSize)
            self.samples = [Double](repeating: 0.0, count: capacity)
        }

        public mutating func addDelaySample(_ delayMicroseconds: Int64) {
            samples[index] = Double(max(0, delayMicroseconds))
            index = (index + 1) % capacity
            if count < capacity { count += 1 }
        }

        /// Rolling minimum propagation delay (microseconds) via vDSP.
        public var baseDelay: Int64 {
            guard count > 0 else { return Int64.max }
            var minVal: Double = 0.0
            vDSP_minvD(samples, 1, &minVal, vDSP_Length(count))
            return Int64(minVal)
        }

        /// Jitter (RMS deviation of queuing delay) via vDSP.
        public var delayJitter: Double {
            guard count > 1 else { return 0.0 }
            var meanVal: Double = 0.0
            vDSP_meanvD(samples, 1, &meanVal, vDSP_Length(count))

            var diff = [Double](repeating: 0.0, count: count)
            var meanNeg = -meanVal
            vDSP_vsaddD(samples, 1, &meanNeg, &diff, 1, vDSP_Length(count))

            var rmsVal: Double = 0.0
            vDSP_rmsqvD(diff, 1, &rmsVal, vDSP_Length(count))
            return rmsVal
        }

        public var sampleCount: Int {
            count
        }
    }
}
