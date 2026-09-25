import Foundation
import Network
import Synchronization

/// Manages a single peer TCP connection using native Network.framework.
public final class PeerConnection: Sendable {
    public let address: String
    public let port: UInt16

    private struct ProtectedState {
        var connection: NWConnection?
        var receiveTask: Task<Void, Never>?
        var onMessage: (@Sendable (PeerMessage) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?
        var remotePeerID: Data?
        var supportsExtensions: Bool = false
        var supportsFastExtension: Bool = false
        var supportsDHT: Bool = false
    }

    private let state = Mutex(ProtectedState())
    private let queue = DispatchQueue(label: "org.swifttorrent.peerconnection", qos: .userInitiated)

    private let infoHash: Data
    private let peerID: Data

    public var onMessage: (@Sendable (PeerMessage) -> Void)? {
        get { state.withLock { $0.onMessage } }
        set { state.withLock { $0.onMessage = newValue } }
    }
    public var onDisconnect: (@Sendable () -> Void)? {
        get { state.withLock { $0.onDisconnect } }
        set { state.withLock { $0.onDisconnect = newValue } }
    }
    public var remotePeerID: Data? {
        state.withLock { $0.remotePeerID }
    }
    public var supportsExtensions: Bool {
        state.withLock { $0.supportsExtensions }
    }
    public var supportsFastExtension: Bool {
        state.withLock { $0.supportsFastExtension }
    }
    public var supportsDHT: Bool {
        state.withLock { $0.supportsDHT }
    }

    public let isPrivate: Bool
    public let enableFastExtension: Bool
    public let enableDHT: Bool

    public init(
        address: String,
        port: UInt16,
        infoHash: Data,
        peerID: Data,
        isPrivate: Bool = false,
        enableFastExtension: Bool = true,
        enableDHT: Bool = true
    ) {
        self.address = address
        self.port = port
        self.infoHash = infoHash
        self.peerID = peerID
        self.isPrivate = isPrivate
        self.enableFastExtension = enableFastExtension
        self.enableDHT = enableDHT
    }

    public func connect() async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: port) ?? 6881
        )
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        let tcpParams = NWParameters(tls: nil, tcp: tcpOptions)
        tcpParams.serviceClass = .responsiveData
        let conn = NWConnection(to: endpoint, using: tcpParams)

        state.withLock {
            $0.connection = conn
        }

        // Wait for connection to be ready with 4-second timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                throw PeerConnectionError.connectionTimeout
            }

            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        let resumed = AtomicFlag(false)
                        conn.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if resumed.testAndSet() {
                                    cont.resume()
                                }
                            case .failed(let err):
                                if resumed.testAndSet() {
                                    cont.resume(throwing: err)
                                }
                            case .cancelled:
                                if resumed.testAndSet() {
                                    cont.resume(throwing: PeerConnectionError.notConnected)
                                }
                            default:
                                break
                            }
                        }
                        conn.start(queue: self.queue)
                    }
                } onCancel: {
                    conn.cancel()
                }
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                conn.cancel()
                group.cancelAll()
                throw error
            }
        }

        // Perform handshake with 4-second timeout
        let (handshakeResp, initialBuffer): (Handshake, Data) = try await withThrowingTaskGroup(of: (Handshake, Data).self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                throw PeerConnectionError.handshakeTimeout
            }

            group.addTask {
                try await withTaskCancellationHandler {
                    var receiveBuffer = Data()
                    let reserved = Handshake.defaultReserved(
                        enableFastExtension: self.enableFastExtension,
                        enableDHT: self.enableDHT,
                        isPrivate: self.isPrivate
                    )
                    let handshake = Handshake(infoHash: self.infoHash, peerID: self.peerID, reserved: reserved)
                    let handshakeData = handshake.encode()
                    try await self.sendRaw(connection: conn, data: handshakeData)

                    let rawData = try await self.receiveExact(connection: conn, count: Handshake.length, buffer: &receiveBuffer)
                    guard let decoded = try? Handshake.decode(from: rawData) else {
                        throw PeerConnectionError.handshakeFailed
                    }
                    if decoded.infoHash != self.infoHash {
                        throw PeerConnectionError.handshakeFailed
                    }
                    return (decoded, receiveBuffer)
                } onCancel: {
                    conn.cancel()
                }
            }

            do {
                guard let result = try await group.next() else {
                    throw PeerConnectionError.handshakeFailed
                }
                group.cancelAll()
                return result
            } catch {
                conn.cancel()
                group.cancelAll()
                throw error
            }
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.messageReceiveLoop(connection: conn, initialBuffer: initialBuffer)
        }

        state.withLock { st in
            st.remotePeerID = handshakeResp.peerID
            st.supportsExtensions = handshakeResp.supportsExtensions
            st.supportsFastExtension = self.enableFastExtension && handshakeResp.supportsFastExtension
            st.supportsDHT = self.enableDHT && !self.isPrivate && handshakeResp.supportsDHT
            st.receiveTask = task
        }
    }

    public func send(_ message: PeerMessage) async throws {
        guard let conn = state.withLock({ $0.connection }) else {
            throw PeerConnectionError.notConnected
        }
        let data = message.encode()
        try await sendRaw(connection: conn, data: data)
    }

    public func close() async throws {
        let (conn, task) = state.withLock { st -> (NWConnection?, Task<Void, Never>?) in
            let c = st.connection
            let t = st.receiveTask
            st.connection = nil
            st.receiveTask = nil
            return (c, t)
        }
        task?.cancel()
        conn?.cancel()
    }

    // MARK: - Private Helpers

    private func sendRaw(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveExact(connection: NWConnection, count: Int, buffer: inout Data) async throws -> Data {
        while buffer.count < count {
            let needed = count - buffer.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(needed, 131072)) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: PeerConnectionError.notConnected)
                    } else {
                        continuation.resume(throwing: PeerConnectionError.notConnected)
                    }
                }
            }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    private func messageReceiveLoop(connection: NWConnection, initialBuffer: Data) async {
        var buffer = initialBuffer
        while !Task.isCancelled {
            do {
                let lengthData = try await receiveExact(connection: connection, count: 4, buffer: &buffer)
                let length = lengthData.readUInt32BE(at: 0)

                if length == 0 {
                    let callback = state.withLock { $0.onMessage }
                    callback?(.keepAlive)
                    continue
                }

                // Safety limit: max message length 16MB
                guard length <= 16 * 1024 * 1024 else {
                    break
                }

                let payload = try await receiveExact(connection: connection, count: Int(length), buffer: &buffer)
                let message = try PeerMessage.decode(from: payload)
                let callback = state.withLock { $0.onMessage }
                callback?(message)
            } catch {
                break
            }
        }

        connection.cancel()
        let disconnectCallback = state.withLock { $0.onDisconnect }
        disconnectCallback?()
    }
}

public enum PeerConnectionError: Error, Sendable, Equatable, LocalizedError {
    case notConnected
    case connectionTimeout
    case handshakeFailed
    case handshakeTimeout

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Peer connection is not connected."
        case .connectionTimeout:
            return "Connection to peer timed out."
        case .handshakeFailed:
            return "BitTorrent handshake with peer failed."
        case .handshakeTimeout:
            return "Handshake exchange with peer timed out."
        }
    }
}

