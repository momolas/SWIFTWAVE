import XCTest
@testable import SwiftTorrent

final class SessionIntegrationTests: XCTestCase {
    func testCreateSession() async throws {
        let settings = SessionSettings(listenPort: 0, dhtEnabled: false)
        let session = Session(settings: settings)

        let torrents = await session.allTorrents()
        XCTAssertTrue(torrents.isEmpty)
    }

    func testHandshakeRoundTrip() throws {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let peerID = Data(repeating: 0xCD, count: 20)

        let handshake = Handshake(infoHash: infoHash, peerID: peerID)
        let encoded = handshake.encode()
        XCTAssertEqual(encoded.count, Handshake.length)

        let decoded = try Handshake.decode(from: encoded)
        XCTAssertEqual(decoded.infoHash, infoHash)
        XCTAssertEqual(decoded.peerID, peerID)
        XCTAssertEqual(decoded, handshake)
    }

    func testGeneratePeerID() {
        let id = generatePeerID()
        XCTAssertEqual(id.count, 20)
        XCTAssertTrue(id.starts(with: Data("-ST0001-".utf8)))
    }

    func testResumeDataRoundTrip() throws {
        let hash = InfoHash(hex: "0123456789abcdef0123456789abcdef01234567")!
        var pieces = Bitfield(count: 16)
        pieces.set(0)
        pieces.set(5)
        pieces.set(15)

        let original = ResumeData(
            infoHash: hash, completedPieces: pieces,
            uploaded: 1000, downloaded: 5000, savePath: "/tmp/test"
        )

        let encoded = original.encode()
        let decoded = try ResumeData.decode(from: encoded)

        XCTAssertEqual(decoded.infoHash, hash)
        XCTAssertEqual(decoded.uploaded, 1000)
        XCTAssertEqual(decoded.downloaded, 5000)
        XCTAssertEqual(decoded.savePath, "/tmp/test")
    }

    func testFileStorageSlices() {
        let files = [
            TorrentInfo.FileEntry(path: "file1.txt", length: 100, offset: 0),
            TorrentInfo.FileEntry(path: "file2.txt", length: 200, offset: 100),
        ]
        let storage = FileStorage(files: files, pieceLength: 150, totalSize: 300)

        XCTAssertEqual(storage.pieceCount, 2)
        XCTAssertEqual(storage.pieceSize(0), 150)
        XCTAssertEqual(storage.pieceSize(1), 150)

        // First piece spans file1 (100 bytes) and file2 (50 bytes)
        let slices0 = storage.fileSlices(forPiece: 0)
        XCTAssertEqual(slices0.count, 2)
        XCTAssertEqual(slices0[0].path, "file1.txt")
        XCTAssertEqual(slices0[0].length, 100)
        XCTAssertEqual(slices0[1].path, "file2.txt")
        XCTAssertEqual(slices0[1].length, 50)
    }

    func testDHTMessageRoundTrip() throws {
        let txID = Data([0x01, 0x02])
        let msg = DHTMessage.query(
            transactionID: txID,
            queryType: .ping,
            arguments: [(key: Data("id".utf8), value: .string(Data(repeating: 0xAA, count: 20)))]
        )
        let encoded = msg.encode()
        let decoded = try DHTMessage.decode(from: encoded)

        if case .query(let decodedTxID, let queryType, _) = decoded {
            XCTAssertEqual(decodedTxID, txID)
            XCTAssertEqual(queryType, .ping)
        } else {
            XCTFail("Expected query message")
        }
    }

    func testAddTorrentParamsFromData() throws {
        // Construct minimal valid .torrent bencode
        let infoDict: [(key: Data, value: BencodeValue)] = [
            (key: Data("name".utf8), value: .string(Data("sample.txt".utf8))),
            (key: Data("piece length".utf8), value: .integer(16384)),
            (key: Data("pieces".utf8), value: .string(Data(repeating: 0x55, count: 20))),
            (key: Data("length".utf8), value: .integer(100))
        ]
        let rootDict: [(key: Data, value: BencodeValue)] = [
            (key: Data("announce".utf8), value: .string(Data("http://tracker.example.com/announce".utf8))),
            (key: Data("info".utf8), value: .dictionary(infoDict))
        ]
        let encoded = BencodeEncoder().encode(.dictionary(rootDict))
        let params = try AddTorrentParams.fromData(encoded, savePath: "/tmp/downloads")
        XCTAssertEqual(params.torrentInfo?.name, "sample.txt")
        XCTAssertEqual(params.savePath, "/tmp/downloads")
        XCTAssertEqual(params.torrentInfo?.totalSize, 100)
    }

    func testAddTrackerToActiveTorrent() async throws {
        let settings = SessionSettings(listenPort: 0, dhtEnabled: false)
        let session = Session(settings: settings)
        let infoDict: [(key: Data, value: BencodeValue)] = [
            (key: Data("name".utf8), value: .string(Data("active_sample.txt".utf8))),
            (key: Data("piece length".utf8), value: .integer(16384)),
            (key: Data("pieces".utf8), value: .string(Data(repeating: 0x55, count: 20))),
            (key: Data("length".utf8), value: .integer(100))
        ]
        let rootDict: [(key: Data, value: BencodeValue)] = [
            (key: Data("info".utf8), value: .dictionary(infoDict))
        ]
        let encoded = BencodeEncoder().encode(.dictionary(rootDict))
        let params = try AddTorrentParams.fromData(encoded, savePath: NSTemporaryDirectory(), paused: false)
        let handle = try await session.addTorrent(params)

        let status = await handle.status()
        XCTAssertEqual(status.state, TorrentState.downloading)

        // Inject new tracker
        await handle.addTracker(urlString: "udp://tracker.opentrackr.org:1337/announce")
        let trackers = await handle.getTrackers()
        XCTAssertTrue(trackers.contains(where: { $0.urlString == "udp://tracker.opentrackr.org:1337/announce" }))
    }

    func testRealUserTorrentAddAndStart() async throws {
        let path = "/Users/mo/Library/Application Support/ROUGHCOMPUTER/Torrents/892694aa2a81794ab994cf2055470d1af58fc160.torrent"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = SessionSettings(listenPort: 6881, dhtEnabled: true, savePath: tempDir.path)
        let session = Session(settings: settings)

        let params = try AddTorrentParams.fromData(data, savePath: tempDir.path, paused: false)
        let handle = try await session.addTorrent(params)

        for tr in [
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce",
            "udp://tracker.torrent.eu.org:451/announce"
        ] {
            await handle.addTracker(urlString: tr)
        }

        let st = await handle.status()
        print("Status name:", st.name, "state:", st.state, "pieces:", st.piecesCompleted, "/", st.piecesTotal)
        XCTAssertEqual(st.state, TorrentState.downloading)

        // Wait a few seconds to check if peers connect
        for i in 1...10 {
            try await Task.sleep(for: .seconds(1))
            let peers = await handle.getPeers()
            let currentSt = await handle.status()
            print("[\(i)s] peers=\(peers.count), rate=\(currentSt.downloadRate), downloaded=\(currentSt.totalDownloaded)")
            if peers.count > 0 || currentSt.totalDownloaded > 0 {
                break
            }
        }
    }
}
