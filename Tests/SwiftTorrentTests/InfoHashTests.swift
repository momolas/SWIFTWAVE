import Testing
import Foundation
@testable import TorrentKit

@Suite("InfoHash Validation")
struct InfoHashTests {
    @Test("Valid hex initialization")
    func fromHex() throws {
        let hash = try #require(InfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        #expect(hash.bytes.count == 20)
        #expect(hash.version == .v1)
    }

    @Test("Invalid hex returns nil")
    func invalidHex() {
        #expect(InfoHash(hex: "short") == nil)
        #expect(InfoHash(hex: "xyz") == nil)
    }

    @Test("V1 SHA-1 hash computation")
    func v1Hash() {
        let data = Data("test info dictionary".utf8)
        let hash = InfoHash.v1(from: data)
        #expect(hash.bytes.count == 20)
        #expect(hash.version == .v1)
    }

    @Test("V2 SHA-256 hash computation")
    func v2Hash() {
        let data = Data("test info dictionary".utf8)
        let hash = InfoHash.v2(from: data)
        #expect(hash.bytes.count == 32)
        #expect(hash.version == .v2)
    }

    @Test("Description returns lowercase hex")
    func description() throws {
        let hash = try #require(InfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        #expect(hash.description == "0123456789abcdef0123456789abcdef01234567")
    }

    @Test("Equatable equality and inequality")
    func equatable() throws {
        let h1 = try #require(InfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        let h2 = try #require(InfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        let h3 = try #require(InfoHash(hex: "abcdef0123456789abcdef0123456789abcdef01"))
        #expect(h1 == h2)
        #expect(h1 != h3)
    }
}
