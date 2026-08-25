import Compression
import Foundation

/// Minimal read-only zip archive, enough for EPUBs: central-directory driven,
/// stored (0) and deflate (8) methods, no zip64, no encryption. Foundation
/// ships no unzip API on iOS, and this stays dependency-free like the m4b
/// parser. Sizes/offsets come from the central directory (authoritative), so
/// data-descriptor entries work without parsing descriptors.
public struct ZipArchive {
    public struct Entry {
        public let name: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int

        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public enum ZipError: Error, Equatable {
        case notAZip
        case unsupported(String)
        case corrupt(String)
    }

    public let entries: [Entry]
    private let data: Data

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        // End-of-central-directory: scan backward for its signature within the
        // last 64 KB + 22 (max comment length + fixed EOCD size).
        let eocdSignature: UInt32 = 0x0605_4B50
        let scanStart = max(0, data.count - 65_557)
        var eocdOffset = -1
        var cursor = data.count - 22
        while cursor >= scanStart {
            if data.readLEU32(at: cursor) == eocdSignature {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZip }

        let entryCount = Int(data.readLEU16(at: eocdOffset + 10))
        let centralDirOffset = Int(data.readLEU32(at: eocdOffset + 16))
        guard entryCount != 0xFFFF, centralDirOffset != 0xFFFF_FFFF else {
            throw ZipError.unsupported("zip64")
        }

        var parsed: [Entry] = []
        parsed.reserveCapacity(entryCount)
        var pos = centralDirOffset
        for _ in 0 ..< entryCount {
            guard pos + 46 <= data.count, data.readLEU32(at: pos) == 0x0201_4B50 else {
                throw ZipError.corrupt("central directory header")
            }
            let method = data.readLEU16(at: pos + 10)
            let compressedSize = Int(data.readLEU32(at: pos + 20))
            let uncompressedSize = Int(data.readLEU32(at: pos + 24))
            let nameLength = Int(data.readLEU16(at: pos + 28))
            let extraLength = Int(data.readLEU16(at: pos + 30))
            let commentLength = Int(data.readLEU16(at: pos + 32))
            let localHeaderOffset = Int(data.readLEU32(at: pos + 42))
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF else {
                throw ZipError.unsupported("zip64 entry")
            }
            let nameStart = data.startIndex + pos + 46
            let name = String(data: data.subdata(in: nameStart ..< nameStart + nameLength), encoding: .utf8)
                ?? String(data: data.subdata(in: nameStart ..< nameStart + nameLength), encoding: .isoLatin1)
                ?? ""
            parsed.append(Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            pos += 46 + nameLength + extraLength + commentLength
        }
        entries = parsed
    }

    public func extract(_ entry: Entry) throws -> Data {
        let pos = entry.localHeaderOffset
        guard pos + 30 <= data.count, data.readLEU32(at: pos) == 0x0403_4B50 else {
            throw ZipError.corrupt("local header for \(entry.name)")
        }
        // Local name/extra lengths can differ from the central directory's.
        let nameLength = Int(data.readLEU16(at: pos + 26))
        let extraLength = Int(data.readLEU16(at: pos + 28))
        let dataStart = data.startIndex + pos + 30 + nameLength + extraLength
        guard dataStart + entry.compressedSize <= data.endIndex else {
            throw ZipError.corrupt("data range for \(entry.name)")
        }
        let compressed = data.subdata(in: dataStart ..< dataStart + entry.compressedSize)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try Self.inflateRaw(compressed, uncompressedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    /// Extracts every entry under `directory`, guarding against path traversal.
    public func extractAll(to directory: URL) throws {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        for entry in entries {
            guard !entry.name.isEmpty else { continue }
            let target = root.appendingPathComponent(entry.name).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") || target.path == root.path else {
                throw ZipError.corrupt("path traversal: \(entry.name)")
            }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try extract(entry).write(to: target)
            }
        }
    }

    /// Raw DEFLATE (RFC 1951) — what zip stores; Apple's COMPRESSION_ZLIB is raw deflate.
    private static func inflateRaw(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), uncompressedSize,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else {
            throw ZipError.corrupt("inflate produced \(written) of \(uncompressedSize) bytes")
        }
        return output
    }
}

extension Data {
    func readLEU16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func readLEU32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0 ..< 4).reversed() {
            value = value << 8 | UInt32(self[startIndex + offset + i])
        }
        return value
    }
}
