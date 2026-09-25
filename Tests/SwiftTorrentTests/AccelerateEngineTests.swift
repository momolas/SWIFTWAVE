import Testing
import Foundation
@testable import TorrentKit

@Suite("Apple Accelerate Engine Tests")
struct AccelerateEngineTests {

    @Test("Word-level SIMD candidate extraction matches scalar semantics")
    func candidateExtraction() {
        var have = Bitfield(count: 200)
        var peerHas = Bitfield(count: 200)

        // peerHas has pieces 5, 10, 64, 127, 199
        peerHas.set(5)
        peerHas.set(10)
        peerHas.set(64)
        peerHas.set(127)
        peerHas.set(199)

        // have has 10 and 64
        have.set(10)
        have.set(64)

        let candidates = AccelerateEngine.extractAvailableCandidates(have: have, peerHas: peerHas)
        #expect(candidates == [5, 127, 199])

        // Verify with limit
        let limited = AccelerateEngine.extractAvailableCandidates(have: have, peerHas: peerHas, maxPieces: 2)
        #expect(limited == [5, 127])
    }

    @Test("Vectorized rarest-first argmin reduction")
    func findRarestCandidates() {
        // Availability: piece 0->5, 1->2, 2->2, 3->7, 4->1, 5->1
        let availability = [5, 2, 2, 7, 1, 1]
        let candidates = [0, 1, 2, 3, 4, 5]

        let rarest = AccelerateEngine.findRarestCandidates(availability: availability, candidates: candidates)
        #expect(rarest == [4, 5])
    }

    @Test("Streaming piece scoring with SIMD multiply-add")
    func computeStreamingScores() {
        let candidates = [10, 20, 30]
        let availability = [Int](repeating: 2, count: 50)
        let priorities = [100, 200, 300] // piece 10 is higher priority (lower score)

        let scored = AccelerateEngine.computeStreamingPieceScores(
            candidateIndices: candidates,
            availability: availability,
            sequentialPriorities: priorities,
            alpha: 0.5,
            beta: 0.5
        )

        #expect(scored.count == 3)
        #expect(scored[0].index == 10)
        #expect(scored[1].index == 20)
        #expect(scored[2].index == 30)
        #expect(scored[0].score < scored[1].score)
        #expect(scored[1].score < scored[2].score)
    }

    @Test("Sliding window throughput rate smoother via vDSP")
    func rateSmoother() {
        var smoother = AccelerateEngine.RateSmoother(windowSize: 4)
        smoother.addSample(1000)
        smoother.addSample(2000)
        smoother.addSample(3000)
        smoother.addSample(4000)

        #expect(smoother.smoothedRate == 2500.0)
        #expect(smoother.peakRate == 4000.0)
        #expect(smoother.rateJitter > 0.0)
    }

    @Test("LEDBAT DelayFilter rolling minimum propagation delay via vDSP")
    func delayFilter() {
        var filter = AccelerateEngine.DelayFilter(windowSize: 8)
        filter.addDelaySample(25_000)
        filter.addDelaySample(20_000)
        filter.addDelaySample(35_000)
        filter.addDelaySample(40_000)

        #expect(filter.baseDelay == 20_000)
        #expect(filter.sampleCount == 4)
        #expect(filter.delayJitter > 0.0)
    }

    @Test("Bitfield vector subtraction and intersection")
    func bitfieldVectorOps() {
        var bfA = Bitfield(count: 128)
        var bfB = Bitfield(count: 128)

        bfA.set(10)
        bfA.set(70)
        bfB.set(70)
        bfB.set(100)

        let sub = bfA.subtracting(bfB)
        #expect(sub.get(10))
        #expect(!sub.get(70))
        #expect(!sub.get(100))

        let inter = bfA.intersecting(bfB)
        #expect(!inter.get(10))
        #expect(inter.get(70))
        #expect(!inter.get(100))
    }
}
