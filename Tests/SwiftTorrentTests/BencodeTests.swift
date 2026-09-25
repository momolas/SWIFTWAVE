import Testing
import Foundation
@testable import TorrentKit

@Suite("Bencode Encoding & Decoding")
struct BencodeTests {
    let encoder = BencodeEncoder()
    let decoder = BencodeDecoder()

    // MARK: - Integer

    @Test("Encode and decode positive integer")
    func encodeDecodeInteger() throws {
        let value = BencodeValue.integer(42)
        let data = encoder.encode(value)
        #expect(String(data: data, encoding: .ascii) == "i42e")
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    @Test("Encode and decode negative integer")
    func negativeInteger() throws {
        let value = BencodeValue.integer(-1)
        let data = encoder.encode(value)
        #expect(String(data: data, encoding: .ascii) == "i-1e")
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    @Test("Encode and decode zero integer")
    func zeroInteger() throws {
        let value = BencodeValue.integer(0)
        let data = encoder.encode(value)
        #expect(String(data: data, encoding: .ascii) == "i0e")
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    // MARK: - String

    @Test("Encode and decode standard string")
    func encodeDecodeString() throws {
        let value = BencodeValue.string(Data("hello".utf8))
        let data = encoder.encode(value)
        #expect(String(data: data, encoding: .ascii) == "5:hello")
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    @Test("Encode and decode empty string")
    func emptyString() throws {
        let value = BencodeValue.string(Data())
        let data = encoder.encode(value)
        #expect(String(data: data, encoding: .ascii) == "0:")
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    // MARK: - List

    @Test("Encode and decode list")
    func encodeDecodeList() throws {
        let value = BencodeValue.list([.integer(1), .string(Data("two".utf8)), .integer(3)])
        let data = encoder.encode(value)
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    @Test("Encode and decode empty list")
    func emptyList() throws {
        let value = BencodeValue.list([])
        let data = encoder.encode(value)
        #expect(String(data: data, encoding: .ascii) == "le")
        let decoded = try decoder.decode(data)
        #expect(decoded == value)
    }

    // MARK: - Dictionary

    @Test("Encode and decode dictionary")
    func encodeDecodeDictionary() throws {
        let value = BencodeValue.dictionary([
            (key: Data("cow".utf8), value: .string(Data("moo".utf8))),
            (key: Data("spam".utf8), value: .string(Data("eggs".utf8))),
        ])
        let data = encoder.encode(value)
        let decoded = try decoder.decode(data)
        // Keys should be sorted in output
        #expect(decoded == value)
    }

    @Test("Dictionary subscript lookup")
    func dictionarySubscript() throws {
        let data = Data("d3:fooi42ee".utf8)
        let decoded = try decoder.decode(data)
        #expect(decoded["foo"]?.integerValue == 42)
        #expect(decoded["bar"] == nil)
    }

    // MARK: - Round-trip

    @Test("Nested structure round-trip")
    func nestedRoundTrip() throws {
        let value = BencodeValue.dictionary([
            (key: Data("info".utf8), value: .dictionary([
                (key: Data("name".utf8), value: .string(Data("test.txt".utf8))),
                (key: Data("piece length".utf8), value: .integer(262144)),
            ])),
            (key: Data("announce".utf8), value: .string(Data("http://tracker.example.com/announce".utf8))),
        ])
        let data = encoder.encode(value)
        let decoded = try decoder.decode(data)
        #expect(decoded["info"]?["name"]?.utf8String == "test.txt")
        #expect(decoded["info"]?["piece length"]?.integerValue == 262144)
    }

    // MARK: - Error cases

    @Test("Invalid bencode inputs throw decoding error")
    func invalidInput() {
        #expect(throws: (any Error).self) {
            try decoder.decode(Data())
        }
        #expect(throws: (any Error).self) {
            try decoder.decode(Data("x".utf8))
        }
    }
}
