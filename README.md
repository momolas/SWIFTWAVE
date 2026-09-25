# TorrentKit (SWIFTWAVE)

![screenshot](https://raw.githubusercontent.com/warppipe/SwiftTorrent/refs/heads/main/img/SwiftTorrent.png)

[![CI](https://github.com/warppipe/SwiftTorrent/actions/workflows/ci.yml/badge.svg)](https://github.com/warppipe/SwiftTorrent/actions/workflows/ci.yml)

A pure Swift BitTorrent library targeting macOS 15+, iOS 18+, and tvOS 18+. Implements BEP-3 (peer wire protocol), BEP-5 (DHT), BEP-6 (Fast Extension), BEP-7 (IPv6), BEP-9 (metadata exchange), BEP-10 (extension protocol), BEP-11 (PEX), BEP-15 (UDP trackers), BEP-27 (Private torrents), BEP-29 (uTP / LEDBAT), BEP-52 (BitTorrent v2), and MSE/PE stream encryption with zero external C/C++ or third-party dependencies.

## Features

- Full download pipeline: magnet link → metadata exchange → piece download → multi-file disk write
- BEP-9 metadata exchange (download torrent info from peers via magnet links)
- BEP-10 extension protocol for extended handshake and message negotiation
- BEP-11 peer exchange (ut_pex) with seed flag tracking
- BEP-6 Fast Extension (haveAll, haveNone, allowedFast, suggestPiece, rejectRequest)
- BEP-27 private torrents compliance (strict DHT/PEX isolation)
- BEP-29 Micro Transport Protocol (uTP) with LEDBAT congestion control
- BEP-52 BitTorrent v2 support with SHA-256 and per-file Merkle trees
- Message Stream Encryption (MSE / PE) with Diffie-Hellman 768-bit and ARC4 (drop1024)
- Multi-file torrent support with cross-file piece spanning and `.part` file protection
- Bencode encoding/decoding
- .torrent file parsing and creation
- Magnet link support
- Peer wire protocol (choke, unchoke, interested, have, bitfield, request, piece, cancel)
- HTTP and UDP tracker clients
- Kademlia DHT with k-bucket routing table
- Rarest-first piece selection with pseudo-random tie-breaking and End-Game mode
- Sequential streaming engine prioritizing container headers, seek tables, and playback buffer
- Async disk I/O with piece caching
- Resume data for saving/restoring state
- Event notifications via `AsyncStream<Alert>` and `statusStream()`

## Requirements

- Swift 6.0+
- macOS 15+ / iOS 18+ / tvOS 18+

## Dependencies

- **Zero third-party dependencies**: Built purely on Apple native frameworks (`Network.framework`, `CryptoKit`, `Synchronization`, and Darwin POSIX sockets).

## Build

```bash
swift build
swift test
```

## Usage

### Add a torrent from a .torrent file

```swift
import TorrentKit

let session = Session(settings: SessionSettings(
    listenPort: 6881,
    savePath: "/Users/me/Downloads"
))

let params = try AddTorrentParams.fromFile("/path/to/file.torrent",
                                           savePath: "/Users/me/Downloads")
let handle = try await session.addTorrent(params)
try await handle.start()

// Monitor progress
let status = await handle.status()
print("Progress: \(Int(status.progress * 100))%")
print("Peers: \(status.numPeers)")
```

### Add a torrent from a magnet link

```swift
let params = try AddTorrentParams.fromMagnet(
    "magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12&dn=Example",
    savePath: "/Users/me/Downloads"
)
let handle = try await session.addTorrent(params)
```

### Listen for alerts

```swift
Task {
    for await alert in session.alerts {
        switch alert {
        case let a as TorrentFinishedAlert:
            print("Finished: \(a.infoHash)")
        case let a as PieceFinishedAlert:
            print("Piece \(a.pieceIndex) complete")
        case let a as TrackerResponseAlert:
            print("Tracker \(a.url): \(a.numPeers) peers")
        default:
            break
        }
    }
}
```

### Parse a .torrent file

```swift
let data = try Data(contentsOf: URL(fileURLWithPath: "example.torrent"))
let info = try TorrentInfo.parse(from: data)

print("Name: \(info.name)")
print("Size: \(info.totalSize) bytes")
print("Pieces: \(info.pieceCount)")
print("Info hash: \(info.infoHash)")

for file in info.files {
    print("  \(file.path) (\(file.length) bytes)")
}
```

### Parse a magnet link

```swift
if let magnet = MagnetLink(uri: "magnet:?xt=urn:btih:...&dn=MyFile&tr=http://tracker.example.com/announce") {
    print("Hash: \(magnet.infoHash)")
    print("Name: \(magnet.displayName ?? "unknown")")
    print("Trackers: \(magnet.trackers)")
}
```

### Bencode encoding/decoding

```swift
let decoder = BencodeDecoder()
let value = try decoder.decode(rawData)
print(value["info"]?["name"]?.utf8String ?? "")

let encoder = BencodeEncoder()
let encoded = encoder.encode(.dictionary([
    (key: Data("key".utf8), value: .string(Data("value".utf8)))
]))
```

### Download a multi-file torrent from a magnet link

```swift
import TorrentKit

let session = Session(settings: SessionSettings(
    listenPort: 6881,
    dhtEnabled: true,
    savePath: "/Users/me/Downloads"
))

let params = try AddTorrentParams.fromMagnet(
    "magnet:?xt=urn:btih:...",
    savePath: "/Users/me/Downloads"
)
let handle = try await session.addTorrent(params)
try await handle.start()
try await session.startDHT()

// Wait for metadata from peers (throws TorrentError.timeout on failure)
let info = try await handle.waitForMetadata(timeout: 60)
for file in info.files {
    print("\(file.path) — \(file.length) bytes")
}

// Wait for download to complete
try await handle.waitForCompletion(timeout: 300)
print("Download complete!")
```

### Save and restore resume data

```swift
// Save
if let resumeData = await handle.generateResumeData() {
    let encoded = resumeData.encode()
    try encoded.write(to: URL(fileURLWithPath: "resume.dat"))
}

// Restore
let saved = try Data(contentsOf: URL(fileURLWithPath: "resume.dat"))
let resumeData = try ResumeData.decode(from: saved)
let params = AddTorrentParams(resumeData: resumeData)
```

## Architecture

```
Session (actor)
├── TorrentHandle (actor, per-torrent)
│   ├── PeerManager (actor) → PeerConnection (Network.framework)
│   ├── PieceManager (actor) → Bitfield, PiecePicker
│   ├── TrackerManager (actor) → HTTPTracker, UDPTracker
│   └── DiskIO (actor) → FileStorage, PieceCache
├── DHTNode (actor) → DHTRoutingTable, DHTTraversal, DHTStorage
└── Alerts → AsyncStream<Alert>
```

## License

MIT
