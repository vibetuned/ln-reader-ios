import Compression
import XCTest
@testable import LnReaderCore

/// Builds real zip bytes (stored + deflate entries) so ZipArchive is tested
/// against the actual wire format.
enum ZipBuilder {
    static func leU16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func leU32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    static func deflate(_ raw: Data) -> Data {
        var dst = Data(count: raw.count + 256)
        let n = dst.withUnsafeMutableBytes { d in
            raw.withUnsafeBytes { s in
                compression_encode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count + 256,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return dst.prefix(n)
    }

    struct Entry {
        let name: String
        let content: Data
        let deflated: Bool
    }

    static func build(_ entries: [Entry]) -> Data {
        var out = Data()
        var centrals = Data()
        for entry in entries {
            let nameData = entry.name.data(using: .utf8)!
            let payload = entry.deflated ? deflate(entry.content) : entry.content
            let method: UInt16 = entry.deflated ? 8 : 0
            let offset = UInt32(out.count)

            var local = leU32(0x0403_4B50)
            local.append(leU16(20)) // version needed
            local.append(leU16(0)) // flags
            local.append(leU16(method))
            local.append(leU16(0)) // time
            local.append(leU16(0)) // date
            local.append(leU32(0)) // crc (unchecked by the reader)
            local.append(leU32(UInt32(payload.count)))
            local.append(leU32(UInt32(entry.content.count)))
            local.append(leU16(UInt16(nameData.count)))
            local.append(leU16(0)) // extra len
            local.append(nameData)
            local.append(payload)
            out.append(local)

            var central = leU32(0x0201_4B50)
            central.append(leU16(20)) // version made by
            central.append(leU16(20)) // version needed
            central.append(leU16(0)) // flags
            central.append(leU16(method))
            central.append(leU16(0)) // time
            central.append(leU16(0)) // date
            central.append(leU32(0)) // crc
            central.append(leU32(UInt32(payload.count)))
            central.append(leU32(UInt32(entry.content.count)))
            central.append(leU16(UInt16(nameData.count)))
            central.append(leU16(0)) // extra len
            central.append(leU16(0)) // comment len
            central.append(leU16(0)) // disk number
            central.append(leU16(0)) // internal attrs
            central.append(leU32(0)) // external attrs
            central.append(leU32(offset))
            central.append(nameData)
            centrals.append(central)
        }
        let centralOffset = UInt32(out.count)
        out.append(centrals)
        var eocd = leU32(0x0605_4B50)
        eocd.append(leU16(0)) // disk number
        eocd.append(leU16(0)) // central dir disk
        eocd.append(leU16(UInt16(entries.count)))
        eocd.append(leU16(UInt16(entries.count)))
        eocd.append(leU32(UInt32(centrals.count)))
        eocd.append(leU32(centralOffset))
        eocd.append(leU16(0)) // comment len
        out.append(eocd)
        return out
    }
}

final class ZipArchiveTests: XCTestCase {
    func testStoredAndDeflatedEntries() throws {
        let body = Data(String(repeating: "The quick brown fox. ", count: 100).utf8)
        let zip = ZipBuilder.build([
            .init(name: "mimetype", content: Data("application/epub+zip".utf8), deflated: false),
            .init(name: "OEBPS/ch1.xhtml", content: body, deflated: true),
        ])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(archive.entries.map(\.name), ["mimetype", "OEBPS/ch1.xhtml"])
        XCTAssertEqual(try archive.extract(archive.entries[0]), Data("application/epub+zip".utf8))
        XCTAssertEqual(try archive.extract(archive.entries[1]), body)
    }

    func testExtractAllGuardsPathTraversal() throws {
        let zip = ZipBuilder.build([
            .init(name: "../evil.txt", content: Data("boom".utf8), deflated: false),
        ])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.extractAll(to: dir))
    }

    func testNotAZipThrows() {
        XCTAssertThrowsError(try ZipArchive(data: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? ZipArchive.ZipError, .notAZip)
        }
    }
}

final class EpubBookTests: XCTestCase {
    private func sampleEpubZip() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="Styles/style.css" media-type="text/css"/>
          </manifest>
          <spine>
            <itemref idref="cover"/>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
        return ZipBuilder.build([
            .init(name: "mimetype", content: Data("application/epub+zip".utf8), deflated: false),
            .init(name: "META-INF/container.xml", content: Data(container.utf8), deflated: true),
            .init(name: "OEBPS/content.opf", content: Data(opf.utf8), deflated: true),
            .init(name: "OEBPS/Text/cover.xhtml", content: Data("<html/>".utf8), deflated: true),
            .init(name: "OEBPS/Text/chapter 1.xhtml", content: Data("<html/>".utf8), deflated: true),
            .init(name: "OEBPS/Styles/style.css", content: Data("body{}".utf8), deflated: false),
        ])
    }

    func testExtractAndParseSpine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epubURL = dir.appendingPathComponent("book.epub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sampleEpubZip().write(to: epubURL)

        let extractionDir = dir.appendingPathComponent("extracted")
        try EpubReader.ensureExtracted(epubURL: epubURL, to: extractionDir)
        // Idempotent: a second call is a no-op, not a re-extract failure.
        try EpubReader.ensureExtracted(epubURL: epubURL, to: extractionDir)

        let book = try EpubReader.parse(extractedDir: extractionDir)
        // Spine follows itemref order, resolves relative to the OPF dir, and
        // percent-decodes hrefs ("chapter%201" → "chapter 1"); css not in spine.
        XCTAssertEqual(book.spine, ["OEBPS/Text/cover.xhtml", "OEBPS/Text/chapter 1.xhtml"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extractionDir.appendingPathComponent("OEBPS/Text/chapter 1.xhtml").path))
    }

    func testMissingContainerThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try EpubReader.parse(extractedDir: dir))
    }
}
