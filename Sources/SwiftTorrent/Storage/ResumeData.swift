import Foundation

/// Save and restore torrent state via bencoding.
public struct ResumeData: Sendable, Equatable, Hashable {
    public let infoHash: InfoHash
    public let completedPieces: Bitfield
    public let uploaded: Int64
    public let downloaded: Int64
    public let savePath: String

    public init(infoHash: InfoHash, completedPieces: Bitfield,
                uploaded: Int64, downloaded: Int64, savePath: String) {
        self.infoHash = infoHash
        self.completedPieces = completedPieces
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.savePath = savePath
    }

    /// Encode to bencoded data.
    public func encode() -> Data {
        let piecesData = completedPieces.toData()
        var pairs: [(key: Data, value: BencodeValue)] = [
            (key: Data("completed_pieces".utf8), value: .string(piecesData)),
            (key: Data("downloaded".utf8), value: .integer(downloaded)),
            (key: Data("info_hash".utf8), value: .string(infoHash.bytes)),
            (key: Data("piece_count".utf8), value: .integer(Int64(completedPieces.count))),
            (key: Data("save_path".utf8), value: .string(Data(savePath.utf8))),
            (key: Data("uploaded".utf8), value: .integer(uploaded)),
        ]
        if let v2Bytes = infoHash.v2Bytes {
            pairs.append((key: Data("info_hash_v2".utf8), value: .string(v2Bytes)))
        }
        return BencodeEncoder().encode(.dictionary(pairs))
    }

    /// Decode from bencoded data.
    public static func decode(from data: Data) throws -> ResumeData {
        let decoder = BencodeDecoder()
        let value = try decoder.decode(data)

        guard let hashData = value["info_hash"]?.stringValue,
              let piecesData = value["completed_pieces"]?.stringValue,
              let uploaded = value["uploaded"]?.integerValue,
              let downloaded = value["downloaded"]?.integerValue,
              let savePath = value["save_path"]?.utf8String else {
            throw ResumeDataError.invalidFormat
        }

        let infoHash: InfoHash
        if let v2Bytes = value["info_hash_v2"]?.stringValue, hashData.count == 20, v2Bytes.count == 32 {
            infoHash = InfoHash(v1Bytes: hashData, v2Bytes: v2Bytes)
        } else {
            infoHash = InfoHash(bytes: hashData)
        }

        let pieceCount = value["piece_count"]?.integerValue.map(Int.init) ?? (piecesData.count * 8)
        let completedPieces = Bitfield(data: piecesData, count: pieceCount)

        return ResumeData(
            infoHash: infoHash, completedPieces: completedPieces,
            uploaded: uploaded, downloaded: downloaded, savePath: savePath
        )
    }
}

public enum ResumeDataError: Error, Sendable, Equatable, LocalizedError {
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Resume data bencode format is invalid or missing required keys."
        }
    }
}
