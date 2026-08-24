import Foundation

/// Random-access read over an m4b file. Open once, read many times via `readAt`.
public protocol M4bSource {
    var size: UInt64 { get }
    func readAt(offset: UInt64, length: Int) throws -> Data
}

public enum M4bSourceError: Error, Equatable {
    case readPastEnd(offset: UInt64, length: Int, size: UInt64)
    case shortRead(expected: Int, got: Int)
}

/// File-backed source over a `FileHandle`. Caller owns lifecycle and must `close()`.
/// For security-scoped URLs (picked via the document picker), the caller is responsible
/// for `startAccessingSecurityScopedResource()` around the source's lifetime.
public final class FileM4bSource: M4bSource {
    public let size: UInt64
    private let handle: FileHandle

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    public func readAt(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset + UInt64(length) <= size else {
            throw M4bSourceError.readPastEnd(offset: offset, length: length, size: size)
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else {
            throw M4bSourceError.shortRead(expected: length, got: data.count)
        }
        return data
    }

    public func close() {
        try? handle.close()
    }
}

/// In-memory source, used by tests.
public struct DataM4bSource: M4bSource {
    private let data: Data
    public var size: UInt64 { UInt64(data.count) }

    public init(_ data: Data) {
        self.data = data
    }

    public func readAt(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset + UInt64(length) <= size else {
            throw M4bSourceError.readPastEnd(offset: offset, length: length, size: size)
        }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start ..< start + length)
    }
}
