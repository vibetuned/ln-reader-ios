import XCTest
@testable import LnReaderCore

/// Builds synthetic MP4 atom trees so the parser is tested against the exact
/// byte layouts documented in AtomReader / M4bParser (mirrors the real files
/// produced by mp4v2 / mp4chaps that ln-vox emits).
enum AtomBuilder {
    static func u32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func u64(_ value: UInt64) -> Data {
        u32(UInt32(value >> 32)) + u32(UInt32(value & 0xFFFF_FFFF))
    }

    static func fourCC(_ type: String) -> Data {
        type.data(using: .isoLatin1)!
    }

    static func atom(_ type: String, _ payload: Data) -> Data {
        u32(UInt32(8 + payload.count)) + fourCC(type) + payload
    }

    /// Atom using the 64-bit extended size encoding (size32 == 1).
    static func extendedAtom(_ type: String, _ payload: Data) -> Data {
        u32(1) + fourCC(type) + u64(UInt64(16 + payload.count)) + payload
    }

    /// `data` atom: 4 bytes type indicator, 4 bytes locale, then the value.
    static func dataAtom(typeIndicator: UInt32, value: Data) -> Data {
        atom("data", u32(typeIndicator) + u32(0) + value)
    }

    static func stringItem(_ type: String, _ value: String) -> Data {
        atom(type, dataAtom(typeIndicator: 1, value: value.data(using: .utf8)!))
    }

    /// mvhd version 0: ver/flags, creation, modification, timescale, duration.
    static func mvhdV0(timescale: UInt32, duration: UInt32) -> Data {
        atom("mvhd", u32(0) + u32(0) + u32(0) + u32(timescale) + u32(duration))
    }

    /// mvhd version 1: ver/flags, creation(8), modification(8), timescale(4), duration(8).
    static func mvhdV1(timescale: UInt32, duration: UInt64) -> Data {
        atom("mvhd", Data([1, 0, 0, 0]) + u64(0) + u64(0) + u32(timescale) + u64(duration))
    }

    /// Nero chpl with the common 9-byte header (1 version + 3 flags + 4 reserved + 1 count).
    static func chpl(chapters: [(ticks: UInt64, title: String)]) -> Data {
        var payload = Data([0, 0, 0, 0]) + u32(0) + Data([UInt8(chapters.count)])
        for chapter in chapters {
            let title = chapter.title.data(using: .utf8)!
            payload += u64(chapter.ticks) + Data([UInt8(title.count)]) + title
        }
        return atom("chpl", payload)
    }

    /// Nero chpl with the short 5-byte header (1 version + 3 flags + 1 count).
    static func chplShortHeader(chapters: [(ticks: UInt64, title: String)]) -> Data {
        var payload = Data([0, 0, 0, 0, UInt8(chapters.count)])
        for chapter in chapters {
            let title = chapter.title.data(using: .utf8)!
            payload += u64(chapter.ticks) + Data([UInt8(title.count)]) + title
        }
        return atom("chpl", payload)
    }

    /// `meta` is a full box: 4-byte version/flags prefix before its children.
    static func meta(_ children: Data) -> Data {
        atom("meta", u32(0) + children)
    }

    static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9])
}

final class M4bParserTests: XCTestCase {
    private func parse(_ bytes: Data) throws -> ParsedM4b {
        try M4bParser().parse(source: DataM4bSource(bytes))
    }

    func testParsesFullSyntheticBook() throws {
        let ilst = AtomBuilder.atom(
            "ilst",
            AtomBuilder.stringItem("\u{A9}nam", "The Long Night")
                + AtomBuilder.stringItem("\u{A9}ART", "A. Author")
                + AtomBuilder.stringItem("\u{A9}alb", "LN Series")
                + AtomBuilder.atom(
                    "covr",
                    AtomBuilder.dataAtom(typeIndicator: 13, value: AtomBuilder.jpegBytes)
                        + AtomBuilder.dataAtom(typeIndicator: 14, value: AtomBuilder.pngBytes)
                )
        )
        let udta = AtomBuilder.atom(
            "udta",
            AtomBuilder.meta(ilst)
                + AtomBuilder.chpl(chapters: [
                    (ticks: 0, title: "Chapter 1"),
                    (ticks: 95 * 10_000_000, title: "Chapter 2"),
                ])
        )
        // 90_000 units at timescale 600 = 150 s
        let moov = AtomBuilder.atom("moov", AtomBuilder.mvhdV0(timescale: 600, duration: 90_000) + udta)
        let file = AtomBuilder.atom("ftyp", AtomBuilder.fourCC("M4B ")) + moov

        let parsed = try parse(file)

        XCTAssertEqual(parsed.title, "The Long Night")
        XCTAssertEqual(parsed.author, "A. Author")
        XCTAssertEqual(parsed.album, "LN Series")
        XCTAssertEqual(parsed.durationMs, 150_000)
        XCTAssertEqual(parsed.chapters, [
            ParsedChapter(startMs: 0, title: "Chapter 1"),
            ParsedChapter(startMs: 95_000, title: "Chapter 2"),
        ])
        XCTAssertEqual(parsed.images, [
            ParsedImage(mimeType: "image/jpeg", bytes: AtomBuilder.jpegBytes),
            ParsedImage(mimeType: "image/png", bytes: AtomBuilder.pngBytes),
        ])
    }

    func testMvhdVersion1Duration() throws {
        // 44_100 * 3600 units at timescale 44_100 = 1 h
        let moov = AtomBuilder.atom("moov", AtomBuilder.mvhdV1(timescale: 44_100, duration: 44_100 * 3_600))
        let parsed = try parse(moov)
        XCTAssertEqual(parsed.durationMs, 3_600_000)
    }

    func testShortChplHeaderFallback() throws {
        let udta = AtomBuilder.atom(
            "udta",
            AtomBuilder.chplShortHeader(chapters: [
                (ticks: 0, title: "One"),
                (ticks: 30 * 10_000_000, title: "Two"),
                (ticks: 60 * 10_000_000, title: "Three"),
            ])
        )
        let moov = AtomBuilder.atom("moov", AtomBuilder.mvhdV0(timescale: 1000, duration: 90_000) + udta)
        let parsed = try parse(moov)
        XCTAssertEqual(parsed.chapters.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(parsed.chapters.map(\.startMs), [0, 30_000, 60_000])
    }

    func testImageMimeSniffedWhenTypeIndicatorUnknown() throws {
        let ilst = AtomBuilder.atom(
            "ilst",
            AtomBuilder.atom("covr", AtomBuilder.dataAtom(typeIndicator: 0, value: AtomBuilder.jpegBytes))
        )
        let udta = AtomBuilder.atom("udta", AtomBuilder.meta(ilst))
        let moov = AtomBuilder.atom("moov", udta)
        let parsed = try parse(moov)
        XCTAssertEqual(parsed.images.map(\.mimeType), ["image/jpeg"])
    }

    func testExtendedAtomSize() throws {
        let udta = AtomBuilder.extendedAtom(
            "udta",
            AtomBuilder.chpl(chapters: [(ticks: 0, title: "Only")])
        )
        let moov = AtomBuilder.extendedAtom("moov", AtomBuilder.mvhdV0(timescale: 600, duration: 600) + udta)
        let parsed = try parse(moov)
        XCTAssertEqual(parsed.durationMs, 1000)
        XCTAssertEqual(parsed.chapters.map(\.title), ["Only"])
    }

    func testSizeZeroMeansToEndOfParent() throws {
        // moov as the last top-level atom with size 0 (extends to end of file)
        var moovBytes = AtomBuilder.u32(0) + AtomBuilder.fourCC("moov")
        moovBytes += AtomBuilder.mvhdV0(timescale: 600, duration: 1200)
        let file = AtomBuilder.atom("ftyp", AtomBuilder.fourCC("M4B ")) + moovBytes
        let parsed = try parse(file)
        XCTAssertEqual(parsed.durationMs, 2000)
    }

    func testMissingMoovThrows() {
        let file = AtomBuilder.atom("ftyp", AtomBuilder.fourCC("M4B "))
        XCTAssertThrowsError(try parse(file)) { error in
            guard case M4bParserError.notMp4 = error else {
                return XCTFail("expected notMp4, got \(error)")
            }
        }
    }

    func testNoUdtaYieldsBareBook() throws {
        let moov = AtomBuilder.atom("moov", AtomBuilder.mvhdV0(timescale: 600, duration: 600))
        let parsed = try parse(moov)
        XCTAssertNil(parsed.title)
        XCTAssertTrue(parsed.chapters.isEmpty)
        XCTAssertTrue(parsed.images.isEmpty)
    }

    func testGarbageChplIsIgnored() throws {
        // A chpl whose counts fit neither header layout should yield no chapters.
        let udta = AtomBuilder.atom("udta", AtomBuilder.atom("chpl", Data([0, 0, 0, 0, 200, 1, 2, 3, 250])))
        let moov = AtomBuilder.atom("moov", udta)
        let parsed = try parse(moov)
        XCTAssertTrue(parsed.chapters.isEmpty)
    }
}
