import Foundation

/// LRU piece cache for reducing disk reads.
public actor PieceCache {
    private var cache: [Int: Data]  // piece index -> data
    private var accessOrder: [Int]  // LRU order (most recent at end)
    private var totalBytes: Int = 0
    private let maxPieces: Int
    private let maxBytes: Int

    public init(maxPieces: Int = 64, maxBytes: Int = 32 * 1024 * 1024) {
        self.cache = [:]
        self.accessOrder = []
        self.totalBytes = 0
        self.maxPieces = maxPieces
        self.maxBytes = maxBytes
    }

    /// Get a piece from cache.
    public func get(_ pieceIndex: Int) -> Data? {
        guard let data = cache[pieceIndex] else { return nil }
        // Move to end (most recently used)
        accessOrder.removeAll { $0 == pieceIndex }
        accessOrder.append(pieceIndex)
        return data
    }

    /// Put a piece into cache.
    public func put(_ pieceIndex: Int, data: Data) {
        if let existing = cache[pieceIndex] {
            totalBytes -= existing.count
        }
        cache[pieceIndex] = data
        totalBytes += data.count
        accessOrder.removeAll { $0 == pieceIndex }
        accessOrder.append(pieceIndex)

        // Evict oldest if over capacity
        while (cache.count > maxPieces || totalBytes > maxBytes), let oldest = accessOrder.first {
            if let evicted = cache.removeValue(forKey: oldest) {
                totalBytes -= evicted.count
            }
            accessOrder.removeFirst()
        }
    }

    /// Clear the cache.
    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        totalBytes = 0
    }

    public func count() -> Int {
        cache.count
    }
}
