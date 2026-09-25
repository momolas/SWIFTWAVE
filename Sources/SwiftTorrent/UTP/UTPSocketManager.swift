import Foundation
import Network
import Synchronization

/// Manages uTP connections multiplexed over a single UDP socket (BEP 29).
public actor UTPSocketManager {
    /// Active uTP connections keyed by (remoteAddress, connectionID).
    private var connections: [String: UTPConnection] = [:]
    private var listener: NWListener?
    private let port: UInt16

    public init(port: UInt16) {
        self.port = port
    }

    /// Start listening for incoming uTP packets on the UDP port.
    public func start() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let l = try NWListener(using: .udp, on: nwPort)
        l.start(queue: .global())
        self.listener = l
    }

    /// Initiate an outgoing uTP connection to a remote peer.
    public func connect(to address: String, port: UInt16) -> UTPConnection {
        let connID = UInt16.random(in: 1...UInt16.max)
        let key = "\(address):\(port):\(connID)"
        let conn = UTPConnection(
            remoteAddress: address,
            remotePort: port,
            connectionID: connID,
            isInitiator: true
        )
        connections[key] = conn
        return conn
    }

    /// Handle an incoming uTP packet.
    public func handlePacket(_ packet: UTPPacket, from address: String, port: UInt16) {
        let key = "\(address):\(port):\(packet.connectionID)"
        if let conn = connections[key] {
            conn.handlePacket(packet)
        } else if packet.type == .syn {
            // Accept incoming connection
            let conn = UTPConnection(
                remoteAddress: address,
                remotePort: port,
                connectionID: packet.connectionID,
                isInitiator: false
            )
            connections[key] = conn
            conn.handlePacket(packet)
        }
    }

    /// Remove a closed connection.
    public func removeConnection(key: String) {
        connections.removeValue(forKey: key)
    }
}

/// Represents a single uTP connection (state machine).
public final class UTPConnection: Sendable {
    public enum State: Sendable {
        case idle
        case synSent
        case connected
        case finSent
        case closed
    }

    public let remoteAddress: String
    public let remotePort: UInt16
    public let connectionID: UInt16
    public let isInitiator: Bool

    private struct StateData: Sendable {
        var state: State = .idle
        var congestion = LEDBATCongestionControl()
        var sendSeqNr: UInt16 = 1
        var ackNr: UInt16 = 0
        var sendBuffer: [UTPPacket] = []
        var receiveBuffer: [UInt16: Data] = [:]
    }

    private let innerState: Mutex<StateData>

    public var state: State {
        innerState.withLock { $0.state }
    }

    public init(
        remoteAddress: String,
        remotePort: UInt16,
        connectionID: UInt16,
        isInitiator: Bool
    ) {
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.connectionID = connectionID
        self.isInitiator = isInitiator
        self.innerState = Mutex(StateData())
    }

    /// Build a SYN packet to initiate a connection.
    public func buildSynPacket() -> UTPPacket {
        innerState.withLock { state in
            state.state = .synSent
            let ts = currentTimestampMicroseconds()
            let pkt = UTPPacket(
                type: .syn,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(state.congestion.cwnd),
                sequenceNumber: state.sendSeqNr
            )
            state.sendSeqNr &+= 1
            return pkt
        }
    }

    /// Build a DATA packet with the given payload.
    public func buildDataPacket(payload: Data) -> UTPPacket {
        innerState.withLock { state in
            let ts = currentTimestampMicroseconds()
            let pkt = UTPPacket(
                type: .data,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(state.congestion.cwnd),
                sequenceNumber: state.sendSeqNr,
                ackNumber: state.ackNr,
                payload: payload
            )
            state.sendSeqNr &+= 1
            state.congestion.onSend(bytes: payload.count)
            return pkt
        }
    }

    /// Build a STATE (ACK) packet.
    public func buildStatePacket() -> UTPPacket {
        innerState.withLock { state in
            let ts = currentTimestampMicroseconds()
            return UTPPacket(
                type: .state,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(state.congestion.cwnd),
                sequenceNumber: state.sendSeqNr,
                ackNumber: state.ackNr
            )
        }
    }

    /// Build a FIN packet.
    public func buildFinPacket() -> UTPPacket {
        innerState.withLock { state in
            state.state = .finSent
            let ts = currentTimestampMicroseconds()
            let pkt = UTPPacket(
                type: .fin,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(state.congestion.cwnd),
                sequenceNumber: state.sendSeqNr,
                ackNumber: state.ackNr
            )
            state.sendSeqNr &+= 1
            return pkt
        }
    }

    /// Handle an incoming packet from the remote peer.
    public func handlePacket(_ packet: UTPPacket) {
        innerState.withLock { state in
            switch packet.type {
            case .syn:
                if !isInitiator {
                    state.ackNr = packet.sequenceNumber
                    state.state = .connected
                }
            case .state:
                if state.state == .synSent {
                    state.state = .connected
                    state.ackNr = packet.sequenceNumber &- 1
                }
                // Process ACK for congestion control
                let delay = Int64(packet.timestampDifference)
                let acked = Int(state.congestion.mss) // simplified: 1 segment per ACK
                state.congestion.onAck(sampleDelay: delay, bytesAcked: acked)

            case .data:
                state.ackNr = packet.sequenceNumber
                state.receiveBuffer[packet.sequenceNumber] = packet.payload

            case .fin:
                state.ackNr = packet.sequenceNumber
                state.state = .closed

            case .reset:
                state.state = .closed
            }
        }
    }

    /// Check if the congestion window allows sending.
    public var canSend: Bool {
        innerState.withLock { $0.congestion.canSend }
    }

    private func currentTimestampMicroseconds() -> UInt32 {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return UInt32((now / 1000) & 0xFFFFFFFF)
    }
}
