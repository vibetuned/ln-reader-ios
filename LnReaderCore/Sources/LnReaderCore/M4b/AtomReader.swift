import Foundation

/// Walks an MP4 atom tree over an `M4bSource`. Atom layout:
///   4 bytes big-endian size, 4 bytes type, [8 bytes extended size if size == 1], payload.
/// Size == 0 means "to end of parent".
///
/// The `meta` atom is a full box: 4 byte version+flags prefix before its children.
/// Children of `ilst` are keyed metadata items whose payload contains one or more
/// `data` atoms (8-byte type+locale prefix, then raw value bytes).
public struct Atom {
    public let type: String
    public let offset: UInt64
    public let headerSize: Int
    public let totalSize: UInt64

    public var payloadOffset: UInt64 { offset + UInt64(headerSize) }
    public var payloadSize: UInt64 { totalSize - UInt64(headerSize) }
    public var payloadEnd: UInt64 { offset + totalSize }
}

public final class AtomReader {
    public let source: M4bSource

    public init(source: M4bSource) {
        self.source = source
    }

    public func topLevelAtoms() throws -> [Atom] {
        try atoms(from: 0, to: source.size)
    }

    public func children(of parent: Atom, skippingPayloadBytes skip: Int = 0) throws -> [Atom] {
        try atoms(from: parent.payloadOffset + UInt64(skip), to: parent.payloadEnd)
    }

    /// Children of `meta`, accounting for its 4-byte version/flags prefix.
    public func metaChildren(of meta: Atom) throws -> [Atom] {
        try children(of: meta, skippingPayloadBytes: 4)
    }

    public func findChild(of parent: Atom?, type: String) throws -> Atom? {
        let atoms = try parent.map { try children(of: $0) } ?? topLevelAtoms()
        return atoms.first { $0.type == type }
    }

    public func findChildren(of parent: Atom?, type: String) throws -> [Atom] {
        let atoms = try parent.map { try children(of: $0) } ?? topLevelAtoms()
        return atoms.filter { $0.type == type }
    }

    public func readPayload(_ atom: Atom) throws -> Data {
        try source.readAt(offset: atom.payloadOffset, length: Int(atom.payloadSize))
    }

    private func atoms(from start: UInt64, to end: UInt64) throws -> [Atom] {
        var out: [Atom] = []
        var pos = start
        while pos + 8 <= end {
            let header = try source.readAt(offset: pos, length: 8)
            let size32 = header.readU32(at: 0)
            let type = header.readFourCC(at: 4)
            let total: UInt64
            let headerSize: Int
            switch size32 {
            case 1:
                let ext = try source.readAt(offset: pos + 8, length: 8)
                total = ext.readU64(at: 0)
                headerSize = 16
            case 0:
                total = end - pos
                headerSize = 8
            default:
                total = UInt64(size32)
                headerSize = 8
            }
            if total < UInt64(headerSize) || pos + total > end { break }
            out.append(Atom(type: type, offset: pos, headerSize: headerSize, totalSize: total))
            pos += total
        }
        return out
    }
}

extension Data {
    /// Big-endian unsigned 32-bit read at a zero-based offset (slice-safe).
    func readU32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value = value << 8 | UInt32(self[startIndex + offset + i])
        }
        return value
    }

    /// Big-endian unsigned 64-bit read at a zero-based offset (slice-safe).
    func readU64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value = value << 8 | UInt64(self[startIndex + offset + i])
        }
        return value
    }

    /// 4-byte atom type as a Latin-1 string (handles © in ©nam / ©ART / ©alb).
    func readFourCC(at offset: Int) -> String {
        let start = startIndex + offset
        return String(data: subdata(in: start ..< start + 4), encoding: .isoLatin1) ?? ""
    }
}
