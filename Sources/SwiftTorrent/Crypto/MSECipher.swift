import Foundation
import Synchronization

/// ARC4 / RC4 stream cipher conforming to BitTorrent MSE specification (drop1024).
public final class MSECipher: Sendable {
    private struct State: ~Copyable {
        var s: [UInt8]
        var i: Int = 0
        var j: Int = 0
    }

    private let state: Mutex<State>

    /// Initialize with key and discard the specified number of initial keystream bytes.
    /// BitTorrent MSE specifies discarding the first 1024 bytes to prevent FMS key recovery.
    public init(key: Data, discardBytes: Int = 1024) {
        // Key-scheduling algorithm (KSA)
        var s = [UInt8](repeating: 0, count: 256)
        for idx in 0..<256 {
            s[idx] = UInt8(idx)
        }

        var jIndex = 0
        let keyCount = key.count
        for idx in 0..<256 {
            let keyByte = key[key.startIndex + (idx % keyCount)]
            jIndex = (jIndex + Int(s[idx]) + Int(keyByte)) & 0xFF
            s.swapAt(idx, jIndex)
        }

        self.state = Mutex(State(s: s, i: 0, j: 0))

        // Discard initial keystream bytes
        if discardBytes > 0 {
            var discard = [UInt8](repeating: 0, count: discardBytes)
            process(&discard)
        }
    }

    /// Process (encrypt or decrypt) a byte array in place (XOR with keystream).
    public func process(_ buffer: inout [UInt8]) {
        state.withLock { st in
            for idx in 0..<buffer.count {
                st.i = (st.i + 1) & 0xFF
                st.j = (st.j + Int(st.s[st.i])) & 0xFF
                st.s.swapAt(st.i, st.j)
                let k = st.s[(Int(st.s[st.i]) + Int(st.s[st.j])) & 0xFF]
                buffer[idx] ^= k
            }
        }
    }

    /// Process a Data object and return the result.
    public func process(_ data: Data) -> Data {
        var copy = [UInt8](data)
        process(&copy)
        return Data(copy)
    }
}
