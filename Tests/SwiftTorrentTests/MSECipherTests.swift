import Testing
import Foundation
@testable import TorrentKit

@Suite("MSECipher Tests")
struct MSECipherTests {
    @Test("ARC4 standard vector validation")
    func arc4StandardVector() {
        // Key: "Key" (4B 65 79)
        // Plaintext: "Plaintext" (50 6C 61 69 6E 74 65 78 74)
        // Standard ARC4 (without drop1024): BB F3 16 E8 D9 40 AF 0A D3
        let key = Data([0x4B, 0x65, 0x79])
        let plaintext = Data([0x50, 0x6C, 0x61, 0x69, 0x6E, 0x74, 0x65, 0x78, 0x74])
        let expected = Data([0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3])

        let cipher = MSECipher(key: key, discardBytes: 0)
        let ciphertext = cipher.process(plaintext)
        #expect(ciphertext == expected)
    }

    @Test("ARC4 round-trip without drop")
    func arc4RoundTripWithoutDrop() {
        let key = Data((0..<16).map { UInt8($0) })
        let message = Data("The quick brown fox jumps over the lazy dog".utf8)

        let enc = MSECipher(key: key, discardBytes: 0)
        let dec = MSECipher(key: key, discardBytes: 0)

        let ciphertext = enc.process(message)
        let decrypted = dec.process(ciphertext)

        #expect(decrypted == message)
    }

    @Test("ARC4 round-trip with drop1024")
    func arc4RoundTripWithDrop1024() {
        let key = Data((0..<20).map { UInt8($0 * 7) })
        let message = Data("BitTorrent MSE/PE encrypted payload verification data".utf8)

        let enc = MSECipher(key: key, discardBytes: 1024)
        let dec = MSECipher(key: key, discardBytes: 1024)

        let ciphertext = enc.process(message)
        #expect(ciphertext != message)

        let decrypted = dec.process(ciphertext)
        #expect(decrypted == message)
    }

    @Test("Drop1024 differs from standard")
    func drop1024DiffersFromStandard() {
        let key = Data((0..<16).map { UInt8($0 + 1) })
        let message = Data("Test data to show drop1024 produces distinct keystream".utf8)

        let cipherNoDrop = MSECipher(key: key, discardBytes: 0)
        let cipherDrop = MSECipher(key: key, discardBytes: 1024)

        let ct1 = cipherNoDrop.process(message)
        let ct2 = cipherDrop.process(message)

        #expect(ct1 != ct2)
    }

    @Test("In-place mutation matches out-of-place")
    func inPlaceProcess() {
        let key = Data((0..<16).map { UInt8($0 ^ 0x55) })
        let original = Data("In-place mutation must match out-of-place".utf8)

        let c1 = MSECipher(key: key)
        let c2 = MSECipher(key: key)

        let outOfPlace = c1.process(original)

        var inPlace = [UInt8](original)
        c2.process(&inPlace)

        #expect(Data(inPlace) == outOfPlace)
    }
}
