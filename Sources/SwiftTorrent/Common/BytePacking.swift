import Foundation
import Synchronization

// MARK: - FixedWidthInteger Big-Endian Extensions

extension FixedWidthInteger {
    /// Returns the big-endian byte representation of this integer.
    @inlinable
    public var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}

// MARK: - Data Big-Endian & Binary Serialization

extension Data {
    /// Appends the big-endian bytes of a fixed-width integer directly into Data without intermediate array allocations.
    @inlinable
    public mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { buf in
            self.append(contentsOf: buf)
        }
    }

    /// Reads a big-endian fixed-width integer from the given offset.
    @inlinable
    public func readIntegerBE<T: FixedWidthInteger>(at offset: Int) -> T {
        let start = self.startIndex + offset
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { buf in
            self.copyBytes(to: buf, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(bigEndian: value)
    }

    /// Reads a 16-bit unsigned integer in big-endian byte order.
    @inlinable
    public func readUInt16BE(at offset: Int) -> UInt16 {
        readIntegerBE(at: offset)
    }

    /// Reads a 32-bit unsigned integer in big-endian byte order.
    @inlinable
    public func readUInt32BE(at offset: Int) -> UInt32 {
        readIntegerBE(at: offset)
    }

    /// Reads a 64-bit unsigned integer in big-endian byte order.
    @inlinable
    public func readUInt64BE(at offset: Int) -> UInt64 {
        readIntegerBE(at: offset)
    }

    // MARK: - Hexadecimal Encoding & Decoding

    /// Fast hexadecimal string representation (lowercase).
    public var hexEncodedString: String {
        let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
        var utf8Bytes = [UInt8](repeating: 0, count: self.count * 2)
        var idx = 0
        for byte in self {
            utf8Bytes[idx] = hexDigits[Int(byte >> 4)]
            utf8Bytes[idx + 1] = hexDigits[Int(byte & 0x0F)]
            idx += 2
        }
        return String(decoding: utf8Bytes, as: UTF8.self)
    }

    /// Initializes Data by parsing a hexadecimal string.
    public init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var chars = hexString.makeIterator()
        while let c1 = chars.next(), let c2 = chars.next() {
            guard let byte = UInt8(String([c1, c2]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }

    // MARK: - RFC 3986 Binary Percent-Encoding

    /// URL-encoded form for tracker announces (strictly RFC 3986 unreserved ASCII characters).
    public var rfc3986PercentEncoded: String {
        self.map { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            default:
                let hi = byte >> 4
                let lo = byte & 0x0F
                return "%" + String(hi, radix: 16).uppercased() + String(lo, radix: 16).uppercased()
            }
        }.joined()
    }
}

// MARK: - Thread-Safe Concurrency Primitives

/// Thread-safe atomic boolean flag using Swift 6 Synchronization.Mutex.
public final class AtomicFlag: Sendable {
    private let state: Mutex<Bool>

    public init(_ value: Bool = false) {
        self.state = Mutex(value)
    }

    /// Atomically sets the flag to true if it was false.
    /// - Returns: `true` if this call transitioned the flag from `false` to `true`; `false` if it was already `true`.
    public func testAndSet() -> Bool {
        state.withLock { value in
            if value { return false }
            value = true
            return true
        }
    }

    /// Returns current state of the flag.
    public var isSet: Bool {
        state.withLock { $0 }
    }
}
