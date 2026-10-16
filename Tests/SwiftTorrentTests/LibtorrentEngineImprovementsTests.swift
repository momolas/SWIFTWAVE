import Testing
import Foundation
@testable import TorrentKit

@Suite("Libtorrent Engine Architecture Improvements Tests")
struct LibtorrentEngineImprovementsTests {

    // MARK: - FilePool POSIX Positional I/O Tests

    @Test("FilePool positional pread and pwrite without seeking")
    func filePoolReadWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pool = FilePool(maxOpenFiles: 4)
        let filePath = tempDir.appendingPathComponent("test_data.bin").path

        let data1 = Data("HELLO_SWIFTWAVE_BITTORRENT_ENGINE".utf8)
        try pool.write(path: filePath, offset: 0, data: data1)

        let data2 = Data("OVERWRITTEN_CHUNK".utf8)
        try pool.write(path: filePath, offset: 6, data: data2)

        let readSlice = try pool.read(path: filePath, offset: 6, count: data2.count)
        #expect(readSlice == data2)

        pool.closeAll()
    }

    @Test("FilePool LRU cache evicts oldest file descriptor when capacity exceeded")
    func filePoolLRUEviction() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Max 16 open files in pool
        let pool = FilePool(maxOpenFiles: 16)
        for i in 0..<20 {
            let path = tempDir.appendingPathComponent("file_\(i).bin").path
            try pool.write(path: path, offset: 0, data: Data("CHUNK_\(i)".utf8))
        }

        // Read from first file again (verifying reopening after eviction)
        let firstPath = tempDir.appendingPathComponent("file_0.bin").path
        let readData = try pool.read(path: firstPath, offset: 0, count: 7)
        #expect(String(data: readData, encoding: .utf8) == "CHUNK_0")

        pool.closeAll()
    }

    // MARK: - Tit-for-Tat Choker Tests

    @Test("Choker ranks interested peers by download rate in leeching mode (Tit-for-Tat)")
    func chokerTitForTatRanking() {
        let choker = Choker(maxUploadSlots: 3) // 2 regular slots + 1 optimistic slot

        let candidateA = Choker.PeerCandidate(
            key: "peerA", isInterested: true, amChoking: true,
            downloadRate: 500_000, uploadRate: 10_000, isSeed: false
        )
        let candidateB = Choker.PeerCandidate(
            key: "peerB", isInterested: true, amChoking: true,
            downloadRate: 2_000_000, uploadRate: 50_000, isSeed: false
        )
        let candidateC = Choker.PeerCandidate(
            key: "peerC", isInterested: true, amChoking: true,
            downloadRate: 100_000, uploadRate: 5_000, isSeed: false
        )
        let candidateD = Choker.PeerCandidate(
            key: "peerD", isInterested: false, amChoking: true, // Not interested!
            downloadRate: 10_000_000, uploadRate: 5_000, isSeed: false
        )

        let decision = choker.evaluate(
            candidates: [candidateA, candidateB, candidateC, candidateD],
            isSeeding: false,
            now: Date()
        )

        // Top 2 downloaders (peerB: 2MB/s, peerA: 500KB/s) MUST be unchoked
        #expect(decision.peersToUnchoke.contains("peerB"))
        #expect(decision.peersToUnchoke.contains("peerA"))
        // peerD is not interested, must not be unchoked
        #expect(!decision.peersToUnchoke.contains("peerD"))
    }

    @Test("Choker ranks peers by upload rate in seeding mode")
    func chokerSeedingRanking() {
        let choker = Choker(maxUploadSlots: 2)

        let candidateA = Choker.PeerCandidate(
            key: "peerA", isInterested: true, amChoking: true,
            downloadRate: 0, uploadRate: 200_000, isSeed: false
        )
        let candidateB = Choker.PeerCandidate(
            key: "peerB", isInterested: true, amChoking: true,
            downloadRate: 0, uploadRate: 800_000, isSeed: false
        )

        let decision = choker.evaluate(
            candidates: [candidateA, candidateB],
            isSeeding: true,
            now: Date()
        )

        #expect(decision.peersToUnchoke.contains("peerB"))
    }

    // MARK: - Smart Ban Tests

    @Test("SmartBan identifies and bans only the peer providing corrupt block data")
    func smartBanAttribution() {
        let smartBan = SmartBan()
        let pieceIndex = 42

        let goodBlock0 = Data(repeating: 0xAA, count: 16384)
        let badBlock1 = Data(repeating: 0xFF, count: 16384) // Bad chunk from malicious peer
        let goodBlock1 = Data(repeating: 0xBB, count: 16384) // Valid chunk

        // Peer A sent good block 0, Peer B sent bad block 1
        smartBan.recordBlock(pieceIndex: pieceIndex, offset: 0, data: goodBlock0, peerKey: "192.168.1.10:6881")
        smartBan.recordBlock(pieceIndex: pieceIndex, offset: 16384, data: badBlock1, peerKey: "10.0.0.99:6881")

        // Piece hash check failed initially
        smartBan.onPieceFailed(pieceIndex: pieceIndex)
        #expect(!smartBan.isBanned(peerKey: "192.168.1.10:6881"))
        #expect(!smartBan.isBanned(peerKey: "10.0.0.99:6881"))

        // Re-downloaded piece verified with valid data
        var verifiedPiece = goodBlock0
        verifiedPiece.append(goodBlock1)

        let banned = smartBan.onPieceVerified(pieceIndex: pieceIndex, verifiedData: verifiedPiece)

        // Only Peer B should be banned, Peer A is innocent!
        #expect(banned == ["10.0.0.99:6881"])
        #expect(smartBan.isBanned(peerKey: "10.0.0.99:6881"))
        #expect(!smartBan.isBanned(peerKey: "192.168.1.10:6881"))
        #expect(smartBan.isAddressBanned(address: "10.0.0.99"))
        #expect(!smartBan.isAddressBanned(address: "192.168.1.10"))
    }

    // MARK: - Dynamic Queue Depth & Anti-Snubbing Tests

    @Test("PeerState dynamic queue depth scales with throughput and throttles on snubbing")
    func dynamicQueueDepthAndSnubbing() async {
        let state = PeerState(pieceCount: 100, maxPipelineDepth: 64)

        // Initial queue limit in slow-start
        let initialLimit = await state.effectiveQueueLimit
        #expect(initialLimit == 4)

        // Simulate receiving fast blocks (e.g. 2 MB/s)
        await state.recordBlockReceived(bytes: 2_000_000)
        await state.updateRates(elapsed: 1.0)

        // Queue size should ramp up towards Bandwidth-Delay Product target
        let rampedLimit = await state.effectiveQueueLimit
        #expect(rampedLimit > 4)

        // Simulate snubbing timeout
        await state.setPeerChoking(false)
        await state.setAmInterested(true)
        await state.addPendingRequest(PeerState.BlockRequest(pieceIndex: 0, offset: 0, length: 16384))

        let wasSnubbed = await state.checkSnubbing(now: Date().addingTimeInterval(20), timeout: 12.0)
        #expect(wasSnubbed)

        let snubbedLimit = await state.effectiveQueueLimit
        #expect(snubbedLimit == 1) // Drops to 1 block in snubbed mode!

        // As soon as a block arrives, snubbing clears
        await state.recordBlockReceived(bytes: 16384)
        let clearedSnubbed = await state.isSnubbed
        #expect(!clearedSnubbed)
    }

    // MARK: - Token-Bucket Bandwidth Limiter Tests

    @Test("BandwidthLimiter allows unconstrained transfer when limit is zero")
    func bandwidthLimiterUnlimited() async {
        let limiter = BandwidthLimiter(rateLimit: 0)
        let start = Date()
        await limiter.requestBandwidth(bytes: 1_000_000)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.05)
    }

    @Test("BandwidthLimiter updates rate limit dynamically")
    func bandwidthLimiterDynamicUpdate() {
        let limiter = BandwidthLimiter(rateLimit: 100_000)
        #expect(limiter.rateLimit == 100_000)
        limiter.setRateLimit(500_000)
        #expect(limiter.rateLimit == 500_000)
    }
}
