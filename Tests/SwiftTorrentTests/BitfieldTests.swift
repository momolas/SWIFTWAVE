import Testing
import Foundation
@testable import TorrentKit

@Suite("Bitfield Operations")
struct BitfieldTests {
    @Test("Basic bit operations (set, get, clear, popcount)")
    func basicOperations() {
        var bf = Bitfield(count: 100)
        #expect(bf.count == 100)
        #expect(bf.isEmpty)
        #expect(!bf.get(0))

        bf.set(0)
        #expect(bf.get(0))
        #expect(bf.popcount == 1)

        bf.set(99)
        #expect(bf.get(99))
        #expect(bf.popcount == 2)

        bf.clear(0)
        #expect(!bf.get(0))
        #expect(bf.popcount == 1)
    }

    @Test("All bits set validation")
    func allSet() {
        var bf = Bitfield(count: 8)
        for i in 0..<8 { bf.set(i) }
        #expect(bf.allSet)
    }

    @Test("Out of bounds safety")
    func outOfBounds() {
        var bf = Bitfield(count: 10)
        bf.set(100) // should be no-op
        #expect(!bf.get(100))
        #expect(!bf.get(-1))
    }

    @Test("Data round-trip serialization")
    func dataRoundTrip() {
        var bf = Bitfield(count: 16)
        bf.set(0)
        bf.set(7)
        bf.set(8)
        bf.set(15)

        let data = bf.toData()
        #expect(data.count == 2)

        let bf2 = Bitfield(data: data, count: 16)
        #expect(bf2.get(0))
        #expect(bf2.get(7))
        #expect(bf2.get(8))
        #expect(bf2.get(15))
        #expect(!bf2.get(1))
        #expect(bf2.popcount == 4)
    }

    @Test("Large bit count handling")
    func largeCount() {
        var bf = Bitfield(count: 1000)
        bf.set(999)
        #expect(bf.get(999))
        #expect(bf.popcount == 1)
    }
}
