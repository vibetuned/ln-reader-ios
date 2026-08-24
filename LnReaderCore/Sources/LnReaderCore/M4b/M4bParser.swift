import Foundation

public struct ParsedChapter: Equatable {
    public let startMs: Int64
    public let title: String

    public init(startMs: Int64, title: String) {
        self.startMs = startMs
        self.title = title
    }
}

public struct ParsedImage: Equatable {
    public let mimeType: String
    public let bytes: Data

    public init(mimeType: String, bytes: Data) {
        self.mimeType = mimeType
        self.bytes = bytes
    }
}

public struct ParsedM4b {
    public let title: String?
    public let author: String?
    public let album: String?
    public let durationMs: Int64
    public let chapters: [ParsedChapter]
    public let images: [ParsedImage]
}

public enum M4bParserError: Error {
    case notMp4
}

public struct M4bParser {

    public init() {}

    public func parse(source: M4bSource) throws -> ParsedM4b {
        let reader = AtomReader(source: source)
        guard let moov = try reader.findChild(of: nil, type: "moov") else {
            throw M4bParserError.notMp4
        }

        let durationMs = try readMovieDurationMs(reader, moov: moov)
        let udta = try reader.findChild(of: moov, type: "udta")
        let meta = try udta.flatMap { try readUdta(reader, udta: $0) }
            ?? (title: nil, author: nil, album: nil, images: [])
        let chapters = try udta.map { try readChapters(reader, udta: $0) } ?? []

        return ParsedM4b(
            title: meta.title,
            author: meta.author,
            album: meta.album,
            durationMs: durationMs,
            chapters: chapters,
            images: meta.images
        )
    }

    private func readMovieDurationMs(_ reader: AtomReader, moov: Atom) throws -> Int64 {
        guard let mvhd = try reader.findChild(of: moov, type: "mvhd") else { return 0 }
        let payload = try reader.readPayload(mvhd)
        guard !payload.isEmpty else { return 0 }
        let version = payload[payload.startIndex]
        if version == 1 {
            guard payload.count >= 4 + 8 + 8 + 4 + 8 else { return 0 }
            let timescale = UInt64(payload.readU32(at: 4 + 8 + 8))
            let duration = payload.readU64(at: 4 + 8 + 8 + 4)
            return timescale == 0 ? 0 : Int64(duration * 1000 / timescale)
        } else {
            guard payload.count >= 4 + 4 + 4 + 4 + 4 else { return 0 }
            let timescale = UInt64(payload.readU32(at: 4 + 4 + 4))
            let duration = UInt64(payload.readU32(at: 4 + 4 + 4 + 4))
            return timescale == 0 ? 0 : Int64(duration * 1000 / timescale)
        }
    }

    private func readUdta(
        _ reader: AtomReader, udta: Atom
    ) throws -> (title: String?, author: String?, album: String?, images: [ParsedImage]) {
        guard let meta = try reader.findChild(of: udta, type: "meta"),
              let ilst = try reader.metaChildren(of: meta).first(where: { $0.type == "ilst" })
        else {
            return (nil, nil, nil, [])
        }

        var title: String?
        var author: String?
        var album: String?
        var images: [ParsedImage] = []

        for item in try reader.children(of: ilst) {
            // Each ilst item contains one or more `data` atoms.
            let dataAtoms = try reader.children(of: item).filter { $0.type == "data" }
            switch item.type {
            case "\u{A9}nam": title = try readFirstStringData(reader, dataAtoms) ?? title
            case "\u{A9}ART": author = try readFirstStringData(reader, dataAtoms) ?? author
            case "\u{A9}alb": album = try readFirstStringData(reader, dataAtoms) ?? album
            case "covr":
                for dataAtom in dataAtoms {
                    if let image = try readImageData(reader, dataAtom) { images.append(image) }
                }
            default: break
            }
        }
        return (title, author, album, images)
    }

    private func readFirstStringData(_ reader: AtomReader, _ dataAtoms: [Atom]) throws -> String? {
        for atom in dataAtoms {
            let payload = try reader.readPayload(atom)
            // data atom payload: 4 bytes type indicator, 4 bytes locale, then value
            guard payload.count > 8 else { continue }
            return String(data: payload.dropFirst(8), encoding: .utf8)
        }
        return nil
    }

    private func readImageData(_ reader: AtomReader, _ dataAtom: Atom) throws -> ParsedImage? {
        let payload = try reader.readPayload(dataAtom)
        guard payload.count > 8 else { return nil }
        let typeIndicator = payload.readU32(at: 0)
        let mime: String?
        switch typeIndicator {
        case 13: mime = "image/jpeg"
        case 14: mime = "image/png"
        default: mime = sniffImageMime(payload, at: 8)
        }
        guard let mime else { return nil }
        return ParsedImage(mimeType: mime, bytes: Data(payload.dropFirst(8)))
    }

    private func sniffImageMime(_ buf: Data, at offset: Int) -> String? {
        guard buf.count - offset >= 4 else { return nil }
        let start = buf.startIndex + offset
        // JPEG: FF D8 FF
        if buf[start] == 0xFF, buf[start + 1] == 0xD8, buf[start + 2] == 0xFF {
            return "image/jpeg"
        }
        // PNG: 89 50 4E 47
        if buf[start] == 0x89, buf[start + 1] == 0x50, buf[start + 2] == 0x4E, buf[start + 3] == 0x47 {
            return "image/png"
        }
        return nil
    }

    private func readChapters(_ reader: AtomReader, udta: Atom) throws -> [ParsedChapter] {
        guard let chpl = try reader.findChild(of: udta, type: "chpl") else { return [] }
        let payload = try reader.readPayload(chpl)
        // Standard Nero chpl layout used by mp4v2 / mp4chaps:
        //   1 byte version, 3 bytes flags, 4 bytes reserved, 1 byte count, then chapters.
        // Per chapter: 8 bytes start time (100-ns units), 1 byte titleLen, titleLen bytes UTF-8.
        guard payload.count >= 9 else { return [] }
        var headerLen = 9
        var count = Int(payload[payload.startIndex + 8])
        // Sanity: if reading chapters at headerLen=9 overflows, fall back to the short header
        // (1 byte version, 3 bytes flags, 1 byte count).
        if !chaptersFit(payload, headerLen: headerLen, count: count) {
            let countAtFour = Int(payload[payload.startIndex + 4])
            if chaptersFit(payload, headerLen: 5, count: countAtFour) {
                headerLen = 5
                count = countAtFour
            } else {
                return []
            }
        }
        var chapters: [ParsedChapter] = []
        chapters.reserveCapacity(count)
        var pos = headerLen
        for _ in 0 ..< count {
            guard pos + 9 <= payload.count else { break }
            let ticks = payload.readU64(at: pos)
            pos += 8
            let titleLen = Int(payload[payload.startIndex + pos])
            pos += 1
            guard pos + titleLen <= payload.count else { break }
            let titleStart = payload.startIndex + pos
            let title = String(data: payload.subdata(in: titleStart ..< titleStart + titleLen), encoding: .utf8) ?? ""
            pos += titleLen
            chapters.append(ParsedChapter(startMs: Int64(ticks / 10_000), title: title))
        }
        return chapters
    }

    private func chaptersFit(_ payload: Data, headerLen: Int, count: Int) -> Bool {
        guard count > 0, count <= 10_000 else { return false }
        var pos = headerLen
        for _ in 0 ..< count {
            guard pos + 9 <= payload.count else { return false }
            let titleLen = Int(payload[payload.startIndex + pos + 8])
            pos += 9 + titleLen
            guard pos <= payload.count else { return false }
        }
        return true
    }
}
