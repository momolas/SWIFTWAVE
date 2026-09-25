import Foundation

public enum DiskIOError: Error, Sendable, Equatable, LocalizedError {
    case pathTraversalDetected(String)
    case corruptedPieceData(expectedLength: Int, actualLength: Int)

    public var errorDescription: String? {
        switch self {
        case .pathTraversalDetected(let path):
            return "Potential directory traversal attack detected for path: \(path)"
        case .corruptedPieceData(let expected, let actual):
            return "Piece data buffer corrupted or truncated (expected \(expected) bytes, got \(actual))"
        }
    }
}

/// Async disk I/O using a dedicated background dispatch queue to avoid blocking Swift cooperative threads.
public actor DiskIO {
    private let basePath: String
    private let fileStorage: FileStorage
    private let ioQueue: DispatchQueue
    public let usePartExtension: Bool

    public init(basePath: String, fileStorage: FileStorage, threadPoolSize: Int = 4, usePartExtension: Bool = true) {
        self.basePath = basePath
        self.fileStorage = fileStorage
        self.ioQueue = DispatchQueue(label: "org.swifttorrent.diskio.serial", qos: .utility)
        self.usePartExtension = usePartExtension
    }

    /// Explicitly shutdown I/O queue (no-op retained for backwards compatibility).
    public func shutdown() async {
        // No explicit shutdown required for GCD DispatchQueue
    }

    private func runIO<T: Sendable>(_ block: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    let result = try block()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolvedPath(for slicePath: String) throws -> String {
        let baseURL = URL(filePath: basePath).resolvingSymlinksInPath().standardizedFileURL
        let combinedURL = baseURL.appending(path: slicePath).standardizedFileURL
        let basePathString = baseURL.path
        let resolvedPathString = combinedURL.path

        let prefixWithSlash = basePathString.hasSuffix("/") ? basePathString : basePathString + "/"
        guard resolvedPathString == basePathString || resolvedPathString.hasPrefix(prefixWithSlash) else {
            throw DiskIOError.pathTraversalDetected(slicePath)
        }
        return resolvedPathString
    }

    /// Target path on disk for writing: uses .part if enabled and final file is not complete.
    private nonisolated static func effectiveWritePath(for resolvedPath: String, usePartExtension: Bool) -> String {
        guard usePartExtension else { return resolvedPath }
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return resolvedPath
        }
        return resolvedPath + ".part"
    }

    /// Source path on disk for reading: prefers final file, then .part file.
    private nonisolated static func effectiveReadPath(for resolvedPath: String, usePartExtension: Bool) -> String {
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return resolvedPath
        }
        if usePartExtension {
            let partPath = resolvedPath + ".part"
            if FileManager.default.fileExists(atPath: partPath) {
                return partPath
            }
        }
        return resolvedPath
    }

    /// Write a piece to disk.
    public func writePiece(index: Int, data: Data) async throws {
        let slices = fileStorage.fileSlices(forPiece: index)
        var resolvedSlicesList: [(path: String, offset: Int64, length: Int)] = []
        for slice in slices {
            let path = try resolvedPath(for: slice.path)
            resolvedSlicesList.append((path: path, offset: slice.offset, length: slice.length))
        }
        let resolvedSlices = resolvedSlicesList

        let usePart = self.usePartExtension
        try await runIO {
            var dataOffset = 0
            for slice in resolvedSlices {
                let endOffset = dataOffset + slice.length
                guard data.count >= endOffset else {
                    throw DiskIOError.corruptedPieceData(expectedLength: endOffset, actualLength: data.count)
                }
                let finalPath = slice.path
                let filePath = Self.effectiveWritePath(for: finalPath, usePartExtension: usePart)
                let dir = (filePath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: filePath) {
                    FileManager.default.createFile(atPath: filePath, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(slice.offset))
                let chunk = data.subdata(in: dataOffset..<endOffset)
                try handle.write(contentsOf: chunk)
                dataOffset = endOffset
            }
        }
    }

    /// Read a piece from disk.
    public func readPiece(index: Int) async throws -> Data {
        let slices = fileStorage.fileSlices(forPiece: index)
        var resolvedSlicesList: [(path: String, offset: Int64, length: Int)] = []
        for slice in slices {
            let path = try resolvedPath(for: slice.path)
            resolvedSlicesList.append((path: path, offset: slice.offset, length: slice.length))
        }
        let resolvedSlices = resolvedSlicesList

        let usePart = self.usePartExtension
        return try await runIO {
            var result = Data()
            for slice in resolvedSlices {
                let filePath = Self.effectiveReadPath(for: slice.path, usePartExtension: usePart)
                guard FileManager.default.fileExists(atPath: filePath) else {
                    return Data()
                }
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(slice.offset))
                guard let chunk = try handle.read(upToCount: slice.length), chunk.count == slice.length else {
                    return Data()
                }
                result.append(chunk)
            }
            return result
        }
    }

    /// Read a specific block (slice) of a piece from disk.
    public func readBlock(pieceIndex: Int, offset: Int, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let pieceData = try await readPiece(index: pieceIndex)
        guard offset < pieceData.count else { return Data() }
        let end = min(offset + length, pieceData.count)
        return pieceData.subdata(in: offset..<end)
    }

    /// Ensure all files exist with correct sizes (creates .part file if enabled).
    public func allocateFiles() async throws {
        var resolvedFilesList: [(path: String, length: Int64)] = []
        for file in fileStorage.files {
            let path = try resolvedPath(for: file.path)
            resolvedFilesList.append((path: path, length: file.length))
        }
        let resolvedFiles = resolvedFilesList

        let usePart = self.usePartExtension
        try await runIO {
            for file in resolvedFiles {
                let finalPath = file.path
                let dir = (finalPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                // If finished file already exists, don't allocate .part
                if FileManager.default.fileExists(atPath: finalPath) {
                    continue
                }

                let targetPath = usePart ? (finalPath + ".part") : finalPath
                if !FileManager.default.fileExists(atPath: targetPath) {
                    FileManager.default.createFile(atPath: targetPath, contents: nil)
                    if file.length > 0 {
                        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: targetPath))
                        defer { try? handle.close() }
                        try handle.truncate(atOffset: UInt64(file.length))
                    }
                }
            }
        }
    }

    /// Finalize all completed files by renaming any .part files to their final names.
    public func finalizeFiles() async throws {
        guard usePartExtension else { return }
        var resolvedFilesList: [String] = []
        for file in fileStorage.files {
            let path = try resolvedPath(for: file.path)
            resolvedFilesList.append(path)
        }
        let resolvedFiles = resolvedFilesList

        try await runIO {
            for finalPath in resolvedFiles {
                let partPath = finalPath + ".part"
                if FileManager.default.fileExists(atPath: partPath) {
                    let partURL = URL(fileURLWithPath: partPath)
                    let finalURL = URL(fileURLWithPath: finalPath)
                    if FileManager.default.fileExists(atPath: finalPath) {
                        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partURL, backupItemName: nil, options: .usingNewMetadataOnly)
                    } else {
                        try FileManager.default.moveItem(at: partURL, to: finalURL)
                    }
                }
            }
        }
    }

    /// Check whether any of the torrent's files (or their .part counterparts) already exist on disk with non-zero size.
    public func hasExistingFiles() async -> Bool {
        var paths: [String] = []
        for file in fileStorage.files {
            if let path = try? resolvedPath(for: file.path) {
                paths.append(path)
            }
        }
        let resolvedPaths = paths
        let usePart = self.usePartExtension
        return (try? await runIO {
            for path in resolvedPaths {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int64, size > 0 {
                    return true
                }
                if usePart,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path + ".part"),
                   let size = attrs[.size] as? Int64, size > 0 {
                    return true
                }
            }
            return false
        }) ?? false
    }

    /// Calculate total existing bytes for all files on disk.
    public func totalDiskBytes() async -> Int64 {
        var paths: [String] = []
        for file in fileStorage.files {
            if let path = try? resolvedPath(for: file.path) {
                paths.append(path)
            }
        }
        let resolvedPaths = paths
        let usePart = self.usePartExtension
        return (try? await runIO {
            var total: Int64 = 0
            for path in resolvedPaths {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int64 {
                    total += size
                } else if usePart,
                          let attrs = try? FileManager.default.attributesOfItem(atPath: path + ".part"),
                          let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
            return total
        }) ?? 0
    }
}
