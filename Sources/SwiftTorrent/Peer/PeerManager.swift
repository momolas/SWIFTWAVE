import Foundation

/// Manages the pool of peer connections for a torrent.
public actor PeerManager {
    private let infoHash: Data
    private let peerID: Data
    private var connections: [String: PeerConnection] = [:]
    private var connectedPeers: Set<String> = []
    private var peerInfos: [String: PeerInfo] = [:]
    private var peerStates: [String: PeerState] = [:]
    private var candidatePeers: [(address: String, port: UInt16)] = []
    private var connectingKeys: Set<String> = []
    private let maxConnections: Int

    public var pieceManager: PieceManager?
    public var piecePicker: PiecePicker?
    public var diskIO: DiskIO?
    public var metadataExchange: MetadataExchange?
    public var onPieceCompleted: ((Int) -> Void)?
    public var onBlockReceived: ((Int) -> Void)?
    public var onBlockSent: ((Int) -> Void)?
    public var onMetadataReceived: ((TorrentInfo) -> Void)?
    public var onDHTPortReceived: ((String, UInt16) -> Void)?
    private var globalPendingRequests: [PeerState.BlockRequest: Set<String>] = [:]
    private var peerMessageContinuations: [String: AsyncStream<PeerMessage>.Continuation] = [:]
    private var peerMessageTasks: [String: Task<Void, Never>] = [:]

    public let isPrivate: Bool
    public var dhtPort: UInt16?
    private var remotePexIDs: [String: UInt8] = [:]
    private var pexAddedSinceLast: Set<PeerExchange.PeerEntry> = []
    private var pexDroppedSinceLast: Set<PeerExchange.PeerEntry> = []
    private var pexBroadcastTask: Task<Void, Never>?
    private let localPexID: UInt8 = PeerExchange.defaultLocalExtensionID

    private var pieceCount: Int = 0

    public init(
        infoHash: Data,
        peerID: Data,
        maxConnections: Int = 50,
        isPrivate: Bool = false,
        dhtPort: UInt16? = nil
    ) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.maxConnections = maxConnections
        self.isPrivate = isPrivate
        self.dhtPort = dhtPort
    }

    public func configure(pieceManager: PieceManager, piecePicker: PiecePicker, diskIO: DiskIO, pieceCount: Int) {
        self.pieceManager = pieceManager
        self.piecePicker = piecePicker
        self.diskIO = diskIO
        self.pieceCount = pieceCount
    }

    public func configureMagnet(metadataExchange: MetadataExchange) {
        self.metadataExchange = metadataExchange
    }

    public func setOnMetadataReceived(_ handler: @escaping (TorrentInfo) -> Void) {
        self.onMetadataReceived = handler
    }

    public func setOnPieceCompleted(_ handler: @escaping (Int) -> Void) {
        self.onPieceCompleted = handler
    }

    public func setOnBlockReceived(_ handler: @escaping (Int) -> Void) {
        self.onBlockReceived = handler
    }

    public func setOnBlockSent(_ handler: @escaping (Int) -> Void) {
        self.onBlockSent = handler
    }

    public func setOnDHTPortReceived(_ handler: @escaping (String, UInt16) -> Void) {
        self.onDHTPortReceived = handler
    }

    /// Enqueue multiple peer candidates and start connecting up to maxConnections.
    public func addPeers(_ newPeers: [(String, UInt16)]) async {
        for (addr, port) in newPeers {
            let key = "\(addr):\(port)"
            if connections[key] == nil && !candidatePeers.contains(where: { $0.address == addr && $0.port == port }) {
                candidatePeers.append((address: addr, port: port))
            }
        }
        await replenishConnections()
    }

    /// Replenish connection pool up to maxConnections from queued candidates.
    public func replenishConnections() async {
        while connections.count < maxConnections && !candidatePeers.isEmpty {
            let candidate = candidatePeers.removeFirst()
            await addPeer(address: candidate.address, port: candidate.port)
        }
    }

    /// Add a peer and attempt connection.
    public func addPeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        guard connections[key] == nil else { return }
        guard connections.count < maxConnections else {
            if !candidatePeers.contains(where: { $0.address == address && $0.port == port }) {
                candidatePeers.append((address: address, port: port))
            }
            return
        }

        let pc = pieceCount > 0 ? pieceCount : 1
        let state = PeerState(pieceCount: pc)
        peerStates[key] = state

        let conn = PeerConnection(
            address: address,
            port: port,
            infoHash: infoHash,
            peerID: peerID,
            isPrivate: isPrivate,
            enableFastExtension: true,
            enableDHT: !isPrivate
        )
        connections[key] = conn
        peerInfos[key] = PeerInfo(id: Data(), address: address, port: port)
        connectingKeys.insert(key)

        // Set up sequential message pipeline per peer
        let (stream, continuation) = AsyncStream<PeerMessage>.makeStream(bufferingPolicy: .unbounded)
        peerMessageContinuations[key] = continuation

        conn.onMessage = { message in
            continuation.yield(message)
        }
        conn.onDisconnect = {
            continuation.finish()
        }

        let messageTask = Task { [weak self] in
            for await message in stream {
                guard let self, !Task.isCancelled else { break }
                await self.handleMessage(message, from: key)
            }
            guard let self, !Task.isCancelled else { return }
            await self.handleDisconnect(key: key)
        }
        peerMessageTasks[key] = messageTask

        Task {
            do {
                try await conn.connect()
                await self.onPeerConnected(key: key, conn: conn)
            } catch {
                print("[PeerManager] Connection to \(key) failed: \(error)")
                self.removePeerByKey(key)
                await self.replenishConnections()
            }
        }
    }

    private func onPeerConnected(key: String, conn: PeerConnection) async {
        connectingKeys.remove(key)
        connectedPeers.insert(key)

        guard let state = peerStates[key] else { return }
        await state.setCapabilities(
            extensions: conn.supportsExtensions,
            fastExtension: conn.supportsFastExtension,
            dht: conn.supportsDHT
        )
        await state.setAmInterested(true)

        // 1. BEP-6 Fast Extension or BEP-3 Bitfield
        if conn.supportsFastExtension {
            if let pm = pieceManager {
                let isComplete = await pm.isComplete()
                let completedBf = await pm.getCompleted()
                if isComplete {
                    try? await conn.send(.haveAll)
                } else if completedBf.isEmpty {
                    try? await conn.send(.haveNone)
                } else {
                    try? await conn.send(.bitfield(completedBf.toData()))
                }
            }
            if pieceCount > 0 {
                let fastSet = FastExtension.generateFastSet(
                    k: min(10, pieceCount),
                    pieceCount: pieceCount,
                    infoHash: infoHash,
                    ip: conn.address
                )
                for pieceIdx in fastSet {
                    try? await conn.send(.allowedFast(pieceIndex: UInt32(pieceIdx)))
                    await state.addMyAllowedFastPieceSent(pieceIdx)
                }
            }
        } else {
            if let pm = pieceManager {
                let completedBf = await pm.getCompleted()
                if !completedBf.isEmpty {
                    try? await conn.send(.bitfield(completedBf.toData()))
                }
            }
        }

        // 2. BEP-5 DHT Port message
        if conn.supportsDHT && !isPrivate, let port = dhtPort {
            try? await conn.send(.port(port))
        }

        // 3. Send interested and unchoke proactively
        try? await conn.send(.interested)
        await state.setAmChoking(false)
        try? await conn.send(.unchoke)

        // 4. BEP-10 Extended Handshake (ut_metadata and ut_pex)
        if conn.supportsExtensions {
            var mDict: [(key: Data, value: BencodeValue)] = []
            if metadataExchange != nil {
                mDict.append((key: Data("ut_metadata".utf8), value: .integer(1)))
            }
            if !isPrivate {
                mDict.append((key: Data(PeerExchange.extensionName.utf8), value: .integer(Int64(localPexID))))
            }
            if !mDict.isEmpty {
                let msg = BencodeValue.dictionary([
                    (key: Data("m".utf8), value: .dictionary(mDict))
                ])
                let payload = BencodeEncoder().encode(msg)
                try? await conn.send(.extended(id: 0, payload: payload))
            }
        }

        // 5. BEP-11 PEX tracking
        if !isPrivate {
            let isSeed = await pieceManager?.isComplete() ?? false
            pexAddedSinceLast.insert(PeerExchange.PeerEntry(address: conn.address, port: conn.port, isSeed: isSeed))
            startPEXLoop()
        }

        // 6. Fill piece requests immediately
        await fillRequests(for: key)
    }

    private func handleDisconnect(key: String) async {
        remotePexIDs.removeValue(forKey: key)
        if !isPrivate, let info = peerInfos[key] {
            pexDroppedSinceLast.insert(PeerExchange.PeerEntry(address: info.address, port: info.port))
        }
        if let state = peerStates[key] {
            let bf = await state.getPeerBitfield()
            if var picker = self.piecePicker {
                picker.removePeerBitfield(bf)
                self.piecePicker = picker
            }
        }
        removePeerByKey(key)
        await replenishConnections()
        await fillAllAvailablePeers()
    }

    private func handleMessage(_ message: PeerMessage, from key: String) async {
        guard let state = peerStates[key] else { return }

        switch message {
        case .bitfield(let data):
            let bf = Bitfield(data: data, count: pieceCount > 0 ? pieceCount : data.count * 8)
            await state.setPeerBitfield(bf)
            if var picker = piecePicker {
                picker.addPeerBitfield(bf)
                piecePicker = picker
            }
            peerInfos[key]?.peerBitfield = bf
            await fillRequests(for: key)

        case .have(let pieceIndex):
            let idx = Int(pieceIndex)
            await state.setHave(idx)
            if var picker = piecePicker {
                picker.addHave(idx)
                piecePicker = picker
            }
            await fillRequests(for: key)

        case .port(let dhtPort):
            if !isPrivate, let info = peerInfos[key] {
                onDHTPortReceived?(info.address, dhtPort)
            }

        case .choke:
            await state.setPeerChoking(true)
            let dropped: [PeerState.BlockRequest]
            if connections[key]?.supportsFastExtension == true {
                dropped = await state.clearPendingRequestsExceptAllowedFast()
            } else {
                dropped = await state.clearPendingRequests()
            }
            for req in dropped {
                if var peers = globalPendingRequests[req] {
                    peers.remove(key)
                    if peers.isEmpty {
                        globalPendingRequests.removeValue(forKey: req)
                    } else {
                        globalPendingRequests[req] = peers
                    }
                }
            }
            if !dropped.isEmpty {
                await fillAllAvailablePeers()
            }

        case .unchoke:
            await state.setPeerChoking(false)
            await fillRequests(for: key)

        case .interested:
            await state.setPeerInterested(true)
            await state.setAmChoking(false)
            try? await connections[key]?.send(.unchoke)

        case .notInterested:
            await state.setPeerInterested(false)

        case .haveAll:
            let count = pieceCount > 0 ? pieceCount : 1
            let bf = Bitfield(count: count, allSet: true)
            await state.setPeerBitfield(bf)
            if var picker = piecePicker {
                picker.addPeerBitfield(bf)
                piecePicker = picker
            }
            peerInfos[key]?.peerBitfield = bf
            await fillRequests(for: key)

        case .haveNone:
            let count = pieceCount > 0 ? pieceCount : 1
            let bf = Bitfield(count: count, allSet: false)
            await state.setPeerBitfield(bf)
            peerInfos[key]?.peerBitfield = bf

        case .suggestPiece(let pieceIndex):
            await state.addSuggestedPiece(Int(pieceIndex))

        case .allowedFast(let pieceIndex):
            await state.addAllowedFastPiece(Int(pieceIndex))
            await fillRequests(for: key)

        case .rejectRequest(let index, let begin, let length):
            let req = PeerState.BlockRequest(pieceIndex: Int(index), offset: Int(begin), length: Int(length))
            await state.removePendingRequest(req)
            if var peers = globalPendingRequests[req] {
                peers.remove(key)
                if peers.isEmpty {
                    globalPendingRequests.removeValue(forKey: req)
                } else {
                    globalPendingRequests[req] = peers
                }
            }
            await fillRequests(for: key)

        case .piece(let index, let begin, let block):
            let pieceIndex = Int(index)
            let offset = Int(begin)
            let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: block.count)
            await state.removePendingRequest(request)
            let otherKeys = globalPendingRequests.removeValue(forKey: request)
            onBlockReceived?(block.count)

            // Endgame mode: cancel request on any other peers that had this duplicate block pending
            if let otherKeys, otherKeys.count > 1 {
                for otherKey in otherKeys where otherKey != key {
                    if let otherState = peerStates[otherKey], let otherConn = connections[otherKey] {
                        await otherState.removePendingRequest(request)
                        try? await otherConn.send(.cancel(index: index, begin: begin, length: UInt32(block.count)))
                    }
                }
            }

            guard let pm = pieceManager else { break }
            await pm.addBlock(pieceIndex: pieceIndex, offset: offset, data: block)

            // Only complete piece when ALL blocks for this piece are received
            if await pm.areAllBlocksReceived(pieceIndex) {
                if let buf = await pm.getPieceBuffer(pieceIndex) {
                    await onPieceComplete(index: pieceIndex, data: buf)
                }
            }

            await fillRequests(for: key)

        case .extended(let extID, let payload):
            if extID == 0 {
                // Extended handshake (BEP-10)
                let decoder = BencodeDecoder()
                if let value = try? decoder.decode(payload), let m = value["m"] {
                    if let utPex = m[PeerExchange.extensionName]?.integerValue {
                        remotePexIDs[key] = UInt8(utPex)
                    }
                }
                if let metaEx = metadataExchange {
                    let result = await metaEx.handleExtendedMessage(id: extID, payload: payload)
                    await processMetadataResult(result, key: key)
                }
            } else if extID == localPexID {
                // Inbound PEX message (BEP-11)
                if !isPrivate {
                    let decoded = PeerExchange.decode(payload: payload)
                    await addPeers(decoded.added.map { ($0.address, $0.port) })
                }
            } else if let metaEx = metadataExchange {
                let result = await metaEx.handleExtendedMessage(id: extID, payload: payload)
                await processMetadataResult(result, key: key)
            }

        case .request(let index, let begin, let length):
            let pIndex = Int(index)
            let isAmChoking = await state.amChoking
            let isFast = connections[key]?.supportsFastExtension == true
            let isAllowedFastByUs = await state.isMyAllowedFastPieceSent(pIndex)
            let canServe = !isAmChoking || (isFast && isAllowedFastByUs)

            if canServe, let dio = diskIO, let pm = pieceManager, await pm.hasPiece(pIndex) {
                if let block = try? await dio.readBlock(pieceIndex: pIndex, offset: Int(begin), length: Int(length)), !block.isEmpty {
                    try? await connections[key]?.send(.piece(index: index, begin: begin, block: block))
                    onBlockSent?(block.count)
                }
            } else if isFast {
                try? await connections[key]?.send(.rejectRequest(index: index, begin: begin, length: length))
            }

        default:
            break
        }
    }

    private func processMetadataResult(_ result: MetadataExchange.Result, key: String) async {
        switch result {
        case .sendMessage(let msg):
            try? await connections[key]?.send(msg)
        case .requestMore(let messages):
            for msg in messages {
                try? await connections[key]?.send(msg)
            }
        case .metadataComplete(let info):
            onMetadataReceived?(info)
        case .none:
            break
        }
    }

    /// Periodic loop broadcasting BEP-11 Peer Exchange updates.
    public func startPEXLoop() {
        guard !isPrivate, pexBroadcastTask == nil else { return }
        pexBroadcastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { break }
                await self.broadcastPEX()
            }
        }
    }

    private func broadcastPEX() async {
        guard !isPrivate else { return }
        let addedList = Array(pexAddedSinceLast)
        let droppedList = Array(pexDroppedSinceLast)
        pexAddedSinceLast.removeAll()
        pexDroppedSinceLast.removeAll()

        guard !addedList.isEmpty || !droppedList.isEmpty else { return }
        let payload = PeerExchange.encode(added: addedList, dropped: droppedList)

        for (key, remoteID) in remotePexIDs {
            guard let conn = connections[key] else { continue }
            try? await conn.send(.extended(id: remoteID, payload: payload))
        }
    }

    private func fillRequests(for key: String) async {
        guard let state = peerStates[key],
              let pm = pieceManager,
              let conn = connections[key] else { return }

        let peerChoking = await state.getPeerChoking()
        let allowedFast = await state.allowedFastPieces
        let isFast = conn.supportsFastExtension

        // If choked and not fast extension, or choked and no allowed fast pieces, cannot request
        if peerChoking && (!isFast || allowedFast.isEmpty) { return }

        let completed = await pm.getCompleted()
        let inProgress = await pm.getInProgress()
        let peerBF = await state.getPeerBitfield()
        let isEndgame = (completed.popcount + inProgress.count >= (pieceCount > 0 ? pieceCount : 1)) || (completed.popcount >= Int(Double(pieceCount) * 0.95))

        var triedPieces: Set<Int> = []

        while await state.canRequest {
            var requestedAny = false

            // 1. Fill missing blocks from existing in-progress pieces that this peer has
            let candidatePieces: [Int]
            if peerChoking {
                candidatePieces = Array(allowedFast.filter { !completed.get($0) && peerBF.get($0) && !triedPieces.contains($0) })
            } else {
                candidatePieces = Array(inProgress.filter { !completed.get($0) && peerBF.get($0) && !triedPieces.contains($0) })
            }

            for inProgIdx in candidatePieces {
                guard await state.canRequest else { break }
                let missing = await pm.missingBlockOffsets(for: inProgIdx)
                if missing.isEmpty {
                    triedPieces.insert(inProgIdx)
                    continue
                }

                let pieceSize = await pm.expectedPieceSize(inProgIdx)
                var requestedInPiece = false

                for offset in missing {
                    guard await state.canRequest else { break }
                    let length = min(16384, pieceSize - offset)
                    let request = PeerState.BlockRequest(pieceIndex: inProgIdx, offset: offset, length: length)
                    let peersWithBlock = globalPendingRequests[request] ?? []

                    let shouldRequest: Bool
                    if peersWithBlock.contains(key) {
                        shouldRequest = false
                    } else if peersWithBlock.isEmpty {
                        shouldRequest = true
                    } else if (missing.count <= 3 || isEndgame) && peersWithBlock.count < 2 {
                        // Tail-end stealing: if <= 3 blocks remain missing in this piece, allow duplicate request
                        shouldRequest = true
                    } else {
                        shouldRequest = false
                    }

                    if shouldRequest {
                        var currentSet = peersWithBlock
                        currentSet.insert(key)
                        globalPendingRequests[request] = currentSet

                        await state.addPendingRequest(request)
                        try? await conn.send(.request(
                            index: UInt32(inProgIdx),
                            begin: UInt32(offset),
                            length: UInt32(length)
                        ))
                        requestedInPiece = true
                        requestedAny = true
                    }
                }

                if !requestedInPiece {
                    triedPieces.insert(inProgIdx)
                }
            }

            // 2. Pick a new rarest-first piece if unchoked and we still have pipeline capacity
            let canRequestMore = await state.canRequest
            if !peerChoking && canRequestMore, let picker = piecePicker {
                let maxConcurrentPieces = max(128, min(max(1, connections.count) * 8, 512))
                let allExistingRequested = candidatePieces.allSatisfy { triedPieces.contains($0) }
                // Only allow starting a new piece if under limit OR if all open pieces are already requested
                if inProgress.count < maxConcurrentPieces || allExistingRequested {
                    var tempHave = completed
                    for tried in triedPieces { tempHave.set(tried) }
                    for inProg in inProgress { tempHave.set(inProg) }

                    if let picked = picker.pick(have: tempHave, peerHas: peerBF) {
                        triedPieces.insert(picked)
                        await pm.startPiece(picked)
                        let pieceSize = await pm.expectedPieceSize(picked)
                        var offset = 0
                        while offset < pieceSize {
                            guard await state.canRequest else { break }
                            let length = min(16384, pieceSize - offset)
                            let request = PeerState.BlockRequest(pieceIndex: picked, offset: offset, length: length)
                            var currentSet = globalPendingRequests[request] ?? []
                            currentSet.insert(key)
                            globalPendingRequests[request] = currentSet

                            await state.addPendingRequest(request)
                            try? await conn.send(.request(
                                index: UInt32(picked),
                                begin: UInt32(offset),
                                length: UInt32(length)
                            ))
                            offset += length
                            requestedAny = true
                        }
                    }
                }
            }

            // Break if no request was issued in this pass to prevent infinite loop
            if !requestedAny {
                break
            }
        }
    }

    private func onPieceComplete(index pieceIndex: Int, data: Data) async {
        guard let pm = pieceManager else { return }
        let verified = await pm.completePiece(pieceIndex)
        guard verified else { return }

        // Await disk persistence before broadcasting piece availability (BEP-3 / AGENTS.md)
        if let dio = diskIO {
            try? await dio.writePiece(index: pieceIndex, data: data)
        }

        await broadcastHave(pieceIndex: UInt32(pieceIndex))
        onPieceCompleted?(pieceIndex)
        await fillAllAvailablePeers()
    }

    /// Prompt all connected unchoked peers with spare pipeline capacity to request blocks.
    public func fillAllAvailablePeers() async {
        for key in connectedPeers {
            guard let state = peerStates[key] else { continue }
            let choking = await state.getPeerChoking()
            let allowedFast = await state.allowedFastPieces
            let isFast = connections[key]?.supportsFastExtension == true
            let canReq = await state.canRequest
            if (!choking || (isFast && !allowedFast.isEmpty)) && canReq {
                await fillRequests(for: key)
            }
        }
    }

    private func removePeerByKey(_ key: String) {
        peerMessageContinuations[key]?.finish()
        peerMessageContinuations.removeValue(forKey: key)
        peerMessageTasks[key]?.cancel()
        peerMessageTasks.removeValue(forKey: key)
        connections.removeValue(forKey: key)
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
        connectingKeys.remove(key)
        for (req, var peers) in globalPendingRequests {
            if peers.remove(key) != nil {
                if peers.isEmpty {
                    globalPendingRequests.removeValue(forKey: req)
                } else {
                    globalPendingRequests[req] = peers
                }
            }
        }
    }

    /// Remove a peer.
    public func removePeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        if let conn = connections.removeValue(forKey: key) {
            try? await conn.close()
        }
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
    }

    /// Get all connected peer infos.
    public func peers() -> [PeerInfo] {
        Array(peerInfos.values)
    }

    /// Snapshot of all currently known peers.
    @inlinable
    public func getPeers() -> [PeerInfo] {
        peers()
    }

    public var connectionCount: Int {
        connectedPeers.count > 0 ? connectedPeers.count : connections.count
    }

    /// Number of peers that completed the TCP handshake.
    public var connectedCount: Int {
        connectedPeers.count
    }

    /// Snapshot of connection and choking health.
    public func peerStats() async -> (connected: Int, unchoked: Int, pendingBlocks: Int) {
        var unchoked = 0
        for key in connectedPeers {
            if let state = peerStates[key] {
                if !(await state.getPeerChoking()) {
                    unchoked += 1
                }
            }
        }
        return (connectedPeers.count, unchoked, globalPendingRequests.count)
    }

    /// Send interested message to all peers concurrently.
    public func sendInterestedToAll() async {
        let msg = PeerMessage.interested
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            Task { [conn] in
                try? await conn.send(msg)
            }
        }
    }

    /// Broadcast a have message to all peers concurrently without blocking the actor loop.
    public func broadcastHave(pieceIndex: UInt32) async {
        let msg = PeerMessage.have(pieceIndex: pieceIndex)
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            Task { [conn] in
                try? await conn.send(msg)
            }
        }
    }

    /// Broadcast our complete bitfield to all peers concurrently.
    public func broadcastBitfield(_ bitfield: Bitfield) async {
        guard !bitfield.isEmpty else { return }
        let msg = PeerMessage.bitfield(bitfield.toData())
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            Task { [conn] in
                try? await conn.send(msg)
            }
        }
    }

    /// Check for timed-out requests and cancel them.
    public func checkTimeouts() async {
        for (key, state) in peerStates {
            let timedOut = await state.timedOutRequests(timeout: 4.0)
            for request in timedOut {
                await state.removePendingRequest(request)
                if var peers = globalPendingRequests[request] {
                    peers.remove(key)
                    if peers.isEmpty {
                        globalPendingRequests.removeValue(forKey: request)
                    } else {
                        globalPendingRequests[request] = peers
                    }
                }
            }
            if !timedOut.isEmpty {
                await fillRequests(for: key)
            }
        }

        // Self-healing: purge any global requests for inactive or desynced peers
        // Batch query active pending requests once per peer instead of N*M actor hops
        var validRequestsPerPeer: [String: Set<PeerState.BlockRequest>] = [:]
        for (key, state) in peerStates {
            let pending = await state.getPendingRequests()
            validRequestsPerPeer[key] = Set(pending.keys)
        }

        var emptyKeys: [PeerState.BlockRequest] = []
        for (req, peers) in globalPendingRequests {
            var updatedPeers = peers
            for peerKey in peers {
                if let peerValid = validRequestsPerPeer[peerKey], peerValid.contains(req) {
                    // valid pending request
                } else {
                    updatedPeers.remove(peerKey)
                }
            }
            if updatedPeers.isEmpty {
                emptyKeys.append(req)
            } else if updatedPeers.count != peers.count {
                globalPendingRequests[req] = updatedPeers
            }
        }
        for req in emptyKeys {
            globalPendingRequests.removeValue(forKey: req)
        }

        // Awaken any unchoked peers that have idle pipeline capacity
        await fillAllAvailablePeers()
    }

    /// Disconnect all active peers and release resources.
    public func disconnectAll() async {
        pexBroadcastTask?.cancel()
        pexBroadcastTask = nil
        for continuation in peerMessageContinuations.values {
            continuation.finish()
        }
        peerMessageContinuations.removeAll()
        for task in peerMessageTasks.values {
            task.cancel()
        }
        peerMessageTasks.removeAll()
        for conn in connections.values {
            try? await conn.close()
        }
        connections.removeAll()
        peerInfos.removeAll()
        peerStates.removeAll()
        connectedPeers.removeAll()
        globalPendingRequests.removeAll()
        remotePexIDs.removeAll()
    }

    /// Update playback piece for sequential streaming prioritization.
    public func setPlaybackPiece(_ pieceIndex: Int) {
        piecePicker?.setCurrentPlaybackPiece(pieceIndex)
    }

    /// Dynamically enable or disable sequential streaming piece prioritization.
    public func setSequentialStreaming(enabled: Bool, currentPlaybackPiece: Int = 0) {
        piecePicker?.setSequentialStreaming(enabled: enabled, currentPlaybackPiece: currentPlaybackPiece)
    }
}
