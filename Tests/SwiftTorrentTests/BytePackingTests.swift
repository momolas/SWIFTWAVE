import Testing
import Foundation
@testable import TorrentKit

@Suite("BytePacking & Serialization Tests")
struct BytePackingTests {

    @Test("Big-endian integer append and read round-trip")
    func testBigEndianAppendAndRead() {
        var data = Data()
        data.append(bigEndian: UInt16(0x1234))
        data.append(bigEndian: UInt32(0x56789ABC))
        data.append(bigEndian: UInt64(0xDEF0123456789ABC))

        #expect(data.count == 2 + 4 + 8)
        #expect(data.readUInt16BE(at: 0) == 0x1234)
        #expect(data.readUInt32BE(at: 2) == 0x56789ABC)
        #expect(data.readUInt64BE(at: 6) == 0xDEF0123456789ABC)
    }

    @Test("Hex string encoding and decoding round-trip")
    func testHexEncodingAndDecoding() {
        let originalBytes: [UInt8] = [0x00, 0x0f, 0x10, 0xab, 0xcd, 0xef, 0xff]
        let originalData = Data(originalBytes)
        let hex = originalData.hexEncodedString

        #expect(hex == "000f10abcdef" + "ff")

        let decodedData = Data(hexString: hex)
        #expect(decodedData == originalData)

        // Invalid hex
        #expect(Data(hexString: "abc") == nil) // Odd length
        #expect(Data(hexString: "zz") == nil)  // Non-hex characters
    }

    @Test("RFC 3986 percent-encoding for tracker announces")
    func testRFC3986PercentEncoding() {
        // Unreserved ASCII characters: a-z, A-Z, 0-9, -, ., _, ~
        let unreserved = Data("abcABC012-._~".utf8)
        #expect(unreserved.rfc3986PercentEncoded == "abcABC012-._~")

        // Reserved / arbitrary binary bytes: 0x00, 0x20, 0xFF
        let binary = Data([0x00, 0x20, 0xFF])
        #expect(binary.rfc3986PercentEncoded == "%00%20%FF")
    }

    @Test("AtomicFlag concurrency and testAndSet semantics")
    func testAtomicFlag() async {
        let flag = AtomicFlag(false)
        #expect(!flag.isSet)

        // First transition should succeed
        #expect(flag.testAndSet() == true)
        #expect(flag.isSet)

        // Subsequent transitions should return false
        #expect(flag.testAndSet() == false)
        #expect(flag.isSet)

        // Concurrent race test
        let concurrentFlag = AtomicFlag(false)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    concurrentFlag.testAndSet()
                }
            }
            var successCount = 0
            for await wonRace in group {
                if wonRace {
                    successCount += 1
                }
            }
            #expect(successCount == 1)
            #expect(concurrentFlag.isSet)
        }
    }
}
