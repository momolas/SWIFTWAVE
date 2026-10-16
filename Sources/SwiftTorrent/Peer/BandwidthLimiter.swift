import Foundation
import Synchronization

/// Thread-safe Token-Bucket rate limiter matching libtorrent's bandwidth_limit.cpp.
/// Throttles download and upload throughput accurately without CPU spinning.
public final class BandwidthLimiter: Sendable {
    private struct Bucket {
        var rateLimit: Int // bytes per second (0 = unlimited)
        var tokens: Double
        var lastReplenish: Date
        var maxCapacity: Double
    }

    private let bucket: Mutex<Bucket>

    public init(rateLimit: Int = 0) {
        let initialTokens = rateLimit > 0 ? Double(rateLimit) : 0
        let capacity = rateLimit > 0 ? max(65536.0, Double(rateLimit) * 0.25) : 0
        self.bucket = Mutex(Bucket(
            rateLimit: rateLimit,
            tokens: initialTokens,
            lastReplenish: Date(),
            maxCapacity: capacity
        ))
    }

    /// Update rate limit dynamically. 0 means unlimited.
    public func setRateLimit(_ limit: Int) {
        bucket.withLock { b in
            b.rateLimit = max(0, limit)
            b.maxCapacity = limit > 0 ? max(65536.0, Double(limit) * 0.25) : 0
            b.tokens = min(b.tokens, b.maxCapacity)
            b.lastReplenish = Date()
        }
    }

    public var rateLimit: Int {
        bucket.withLock { $0.rateLimit }
    }

    /// Wait for quota to consume `bytes` according to the token bucket.
    public func requestBandwidth(bytes: Int) async {
        guard bytes > 0 else { return }

        while true {
            var waitDuration: TimeInterval?

            bucket.withLock { b in
                guard b.rateLimit > 0 else { return }

                let now = Date()
                let elapsed = now.timeIntervalSince(b.lastReplenish)
                if elapsed > 0 {
                    let newTokens = elapsed * Double(b.rateLimit)
                    b.tokens = min(b.maxCapacity, b.tokens + newTokens)
                    b.lastReplenish = now
                }

                let needed = Double(bytes)
                if b.tokens >= needed {
                    b.tokens -= needed
                    waitDuration = nil
                } else {
                    let deficit = needed - b.tokens
                    waitDuration = deficit / Double(b.rateLimit)
                }
            }

            guard let duration = waitDuration, duration > 0.001 else {
                break
            }

            // Sleep cooperatively until enough tokens accumulate
            try? await Task.sleep(for: .seconds(min(duration, 0.5)))
        }
    }
}
