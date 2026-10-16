import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local Service Discovery (BEP-14) implementation.
/// Discovers BitTorrent peers on the local area network using multicast UDP (239.192.152.143:6771).
public actor LocalServiceDiscovery {
    public static let multicastIPv4 = "239.192.152.143"
    public static let multicastPort: UInt16 = 6771

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let cookie: String
    private var isRunning: Bool = false
    private let listenPort: UInt16
    private var onPeerDiscovered: (@Sendable (Data, String, UInt16) -> Void)?

    public init(listenPort: UInt16) {
        self.listenPort = listenPort
        // Random 8-character hex cookie to ignore our own broadcasts
        self.cookie = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    deinit {
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    public func setOnPeerDiscovered(_ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
        self.onPeerDiscovered = handler
    }

    public func start() throws {
        guard !isRunning else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.multicastPort.bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindRes == 0 {
            // Join multicast group
            var mreq = ip_mreq()
            inet_pton(AF_INET, Self.multicastIPv4, &mreq.imr_multiaddr)
            mreq.imr_interface.s_addr = INADDR_ANY
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        }

        // Make non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        self.socketFD = fd
        self.isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "org.swifttorrent.lsd", qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.readPackets()
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.readSource = source
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    /// Broadcast announce for an info-hash to the LAN multicast group (BEP-14).
    public func announce(infoHash: Data) {
        let hexHash = infoHash.map { String(format: "%02x", $0) }.joined()
        let message = "BT-SEARCH * HTTP/1.1\r\n" +
            "Host: \(Self.multicastIPv4):\(Self.multicastPort)\r\n" +
            "Port: \(listenPort)\r\n" +
            "Infohash: \(hexHash)\r\n" +
            "cookie: \(cookie)\r\n\r\n\r\n"

        guard let data = message.data(using: .utf8) else { return }

        let fd = socketFD >= 0 ? socketFD : socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(Self.multicastPort.bigEndian)
        inet_pton(AF_INET, Self.multicastIPv4, &dest.sin_addr)

        _ = data.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return 0 }
            return withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if socketFD < 0 {
            Darwin.close(fd)
        }
    }

    private func readPackets() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var srcAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while true {
            let bytesRead = withUnsafeMutablePointer(to: &srcAddr) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(socketFD, &buffer, buffer.count, 0, sa, &addrLen)
                }
            }
            guard bytesRead > 0 else { break }

            let data = Data(buffer.prefix(bytesRead))
            guard let text = String(data: data, encoding: .utf8) else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &srcAddr.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = ipBuf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? ""
            }

            parseAnnouncement(text, fromAddress: ip)
        }
    }

    private func parseAnnouncement(_ text: String, fromAddress: String) {
        guard text.contains("BT-SEARCH") else { return }

        var port: UInt16?
        var infoHashData: Data?
        var remoteCookie: String?

        let lines = text.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("port:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let p = UInt16(parts[1].trimmingCharacters(in: .whitespaces)) {
                    port = p
                }
            } else if lower.hasPrefix("infohash:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let hex = parts[1].trimmingCharacters(in: .whitespaces)
                    infoHashData = Data(hexString: String(hex))
                }
            } else if lower.hasPrefix("cookie:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    remoteCookie = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Ignore our own broadcasts
        if let remoteCookie, remoteCookie == cookie {
            return
        }

        if let port, let infoHashData {
            onPeerDiscovered?(infoHashData, fromAddress, port)
        }
    }
}
