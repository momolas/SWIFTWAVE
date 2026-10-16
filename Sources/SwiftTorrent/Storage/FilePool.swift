import Foundation
import Darwin
import Synchronization

/// Thread-safe POSIX file descriptor pool with LRU eviction and atomic positional I/O (pread/pwrite).
/// Eliminates per-slice open/close/seek overhead, matching libtorrent's pread_disk_io architecture.
public final class FilePool: Sendable {

    private struct State {
        var openFiles: [String: Int32] = [:]
        var lruOrder: [String] = []
        let maxOpenFiles: Int
    }

    private let state: Mutex<State>

    public init(maxOpenFiles: Int = 128) {
        self.state = Mutex(State(openFiles: [:], lruOrder: [], maxOpenFiles: max(16, maxOpenFiles)))
    }

    deinit {
        closeAll()
    }

    /// Reads exactly `count` bytes starting at `offset` using POSIX pread(2) without seeking.
    public func read(path: String, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let fd = try acquireFD(path: path, writeAccess: false)
        var buffer = Data(count: count)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> Int in
            guard let baseAddress = rawBuf.baseAddress else { return 0 }
            return pread(fd, baseAddress, count, off_t(offset))
        }

        if bytesRead < 0 {
            let err = errno
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        if bytesRead < count {
            return buffer.prefix(bytesRead)
        }
        return buffer
    }

    /// Writes data starting at `offset` using POSIX pwrite(2) without seeking.
    public func write(path: String, offset: Int64, data: Data) throws {
        guard !data.isEmpty else { return }
        let fd = try acquireFD(path: path, writeAccess: true)
        let bytesWritten = data.withUnsafeBytes { rawBuf -> Int in
            guard let baseAddress = rawBuf.baseAddress else { return 0 }
            return pwrite(fd, baseAddress, data.count, off_t(offset))
        }

        if bytesWritten != data.count {
            let err = errno
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    /// Closes and evicts a specific path from the cache (e.g. when moving or removing files).
    public func close(path: String) {
        state.withLock { s in
            if let fd = s.openFiles.removeValue(forKey: path) {
                Darwin.close(fd)
            }
            s.lruOrder.removeAll(where: { $0 == path })
        }
    }

    /// Closes all active file descriptors in the pool.
    public func closeAll() {
        state.withLock { s in
            for (_, fd) in s.openFiles {
                Darwin.close(fd)
            }
            s.openFiles.removeAll()
            s.lruOrder.removeAll()
        }
    }

    private func acquireFD(path: String, writeAccess: Bool) throws -> Int32 {
        // Fast path: Check if already open
        var existingFD: Int32?
        state.withLock { s in
            if let fd = s.openFiles[path] {
                // Touch LRU
                if let idx = s.lruOrder.firstIndex(of: path) {
                    s.lruOrder.remove(at: idx)
                }
                s.lruOrder.append(path)
                existingFD = fd
            }
        }
        if let existingFD {
            return existingFD
        }

        // Slow path: Ensure parent directory exists if writing
        if writeAccess {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let flags = writeAccess ? (O_RDWR | O_CREAT) : O_RDONLY
        let mode: mode_t = 0o644
        let fd = open(path, flags, mode)
        guard fd >= 0 else {
            let err = errno
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EACCES)
        }

        // Insert into cache and evict oldest if needed
        var fdToClose: Int32?
        state.withLock { s in
            if s.openFiles.count >= s.maxOpenFiles && !s.lruOrder.isEmpty {
                let oldest = s.lruOrder.removeFirst()
                fdToClose = s.openFiles.removeValue(forKey: oldest)
            }
            s.openFiles[path] = fd
            s.lruOrder.append(path)
        }

        if let fdToClose {
            Darwin.close(fdToClose)
        }

        return fd
    }
}
