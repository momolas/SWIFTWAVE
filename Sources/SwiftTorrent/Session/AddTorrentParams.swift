import Foundation

/// Parameters for adding a torrent to a session.
public struct AddTorrentParams: Sendable {
    public var torrentInfo: TorrentInfo?
    public var magnetLink: MagnetLink?
    public var savePath: String?
    public var resumeData: ResumeData?
    public var paused: Bool
    public var isStreaming: Bool

    public init(torrentInfo: TorrentInfo? = nil, magnetLink: MagnetLink? = nil,
                savePath: String? = nil, resumeData: ResumeData? = nil, paused: Bool = false, isStreaming: Bool = false) {
        self.torrentInfo = torrentInfo
        self.magnetLink = magnetLink
        self.savePath = savePath
        self.resumeData = resumeData
        self.paused = paused
        self.isStreaming = isStreaming
    }

    /// Create from raw .torrent file data in memory.
    public static func fromData(_ data: Data, savePath: String? = nil, paused: Bool = false, isStreaming: Bool = false) throws -> AddTorrentParams {
        let info = try TorrentInfo.parse(from: data)
        return AddTorrentParams(torrentInfo: info, savePath: savePath, paused: paused, isStreaming: isStreaming)
    }

    /// Create from a .torrent file path.
    public static func fromFile(_ path: String, savePath: String? = nil, paused: Bool = false, isStreaming: Bool = false) throws -> AddTorrentParams {
        let data = try Data(contentsOf: URL(filePath: path))
        return try fromData(data, savePath: savePath, paused: paused, isStreaming: isStreaming)
    }

    /// Create from a magnet URI.
    public static func fromMagnet(_ uri: String, savePath: String? = nil, isStreaming: Bool = false) throws -> AddTorrentParams {
        guard let magnet = MagnetLink(uri: uri) else {
            throw AddTorrentError.invalidMagnetLink
        }
        return AddTorrentParams(magnetLink: magnet, savePath: savePath, isStreaming: isStreaming)
    }

    /// The info hash (from either torrent info or magnet link).
    public var infoHash: InfoHash? {
        torrentInfo?.infoHash ?? magnetLink?.infoHash
    }
}

public enum AddTorrentError: Error, Sendable, Equatable, LocalizedError {
    case invalidMagnetLink
    case noInfoHash

    public var errorDescription: String? {
        switch self {
        case .invalidMagnetLink:
            return "Invalid magnet link URI."
        case .noInfoHash:
            return "No info hash could be determined from the provided parameters."
        }
    }
}
