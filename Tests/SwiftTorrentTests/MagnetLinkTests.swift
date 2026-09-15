import Testing
import Foundation
@testable import SwiftTorrent

@Suite("MagnetLink Parsing & Serialization")
struct MagnetLinkTests {
    @Test("Parse basic magnet URI")
    func parseBasicMagnet() throws {
        let uri = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=TestFile"
        let magnet = try #require(MagnetLink(uri: uri))
        #expect(magnet.displayName == "TestFile")
        #expect(magnet.infoHash.description == "0123456789abcdef0123456789abcdef01234567")
    }

    @Test("Parse magnet URI with multiple trackers")
    func parseWithTrackers() throws {
        let uri = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=http://tracker1.example.com/announce&tr=http://tracker2.example.com/announce"
        let magnet = try #require(MagnetLink(uri: uri))
        #expect(magnet.trackers.count == 2)
    }

    @Test("Invalid magnet returns nil")
    func invalidMagnet() {
        #expect(MagnetLink(uri: "not a magnet") == nil)
        #expect(MagnetLink(uri: "magnet:?foo=bar") == nil)
    }

    @Test("Generate URI with prefix and parameters")
    func generateURI() throws {
        let hash = try #require(InfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        let magnet = MagnetLink(infoHash: hash, displayName: "Test")
        let uri = magnet.uri
        #expect(uri.hasPrefix("magnet:?"))
        #expect(uri.contains("xt=urn:btih:"))
        #expect(uri.contains("dn=Test"))
    }

    @Test("Base32 decoding")
    func base32Decode() throws {
        // "ORSXG5A=" is base32 for "test"
        let decoded = try #require(MagnetLink.base32Decode("ORSXG5A"))
        #expect(String(data: decoded, encoding: .utf8) == "test")
    }

    @Test("Round-trip magnet link serialization and parse")
    func roundTrip() throws {
        let hash = try #require(InfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        let original = MagnetLink(infoHash: hash, displayName: "MyTorrent", trackers: ["http://tracker.example.com/announce"])
        let uri = original.uri
        let parsed = try #require(MagnetLink(uri: uri))
        #expect(parsed.infoHash == original.infoHash)
        #expect(parsed.displayName == "MyTorrent")
    }
}
