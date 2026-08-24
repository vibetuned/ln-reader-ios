// Temporary CLI check of the M4bParser port — runs without XCTest (Command Line
// Tools only). Mirrors the main assertions in M4bParserTests. Deleted once Xcode
// is installed and `swift test` works.
import Foundation
import LnReaderCore

func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
func u64(_ v: UInt64) -> Data { u32(UInt32(v >> 32)) + u32(UInt32(v & 0xFFFF_FFFF)) }
func fourCC(_ t: String) -> Data { t.data(using: .isoLatin1)! }
func atom(_ t: String, _ p: Data) -> Data { u32(UInt32(8 + p.count)) + fourCC(t) + p }
func extendedAtom(_ t: String, _ p: Data) -> Data { u32(1) + fourCC(t) + u64(UInt64(16 + p.count)) + p }
func dataAtom(type: UInt32, value: Data) -> Data { atom("data", u32(type) + u32(0) + value) }
func stringItem(_ t: String, _ v: String) -> Data { atom(t, dataAtom(type: 1, value: v.data(using: .utf8)!)) }
func mvhdV0(timescale: UInt32, duration: UInt32) -> Data { atom("mvhd", u32(0) + u32(0) + u32(0) + u32(timescale) + u32(duration)) }
func mvhdV1(timescale: UInt32, duration: UInt64) -> Data { atom("mvhd", Data([1, 0, 0, 0]) + u64(0) + u64(0) + u32(timescale) + u64(duration)) }

func chpl(header9: Bool, _ chapters: [(UInt64, String)]) -> Data {
    var p = header9 ? Data([0, 0, 0, 0]) + u32(0) + Data([UInt8(chapters.count)])
                    : Data([0, 0, 0, 0, UInt8(chapters.count)])
    for (ticks, title) in chapters {
        let t = title.data(using: .utf8)!
        p += u64(ticks) + Data([UInt8(t.count)]) + t
    }
    return atom("chpl", p)
}

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print("\(cond ? "PASS" : "FAIL")  \(label)")
    if !cond { failures += 1 }
}

let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9])

// --- full synthetic book ---
let ilst = atom("ilst",
    stringItem("\u{A9}nam", "The Long Night")
    + stringItem("\u{A9}ART", "A. Author")
    + stringItem("\u{A9}alb", "LN Series")
    + atom("covr", dataAtom(type: 13, value: jpeg) + dataAtom(type: 0, value: png)))
let udta = atom("udta", atom("meta", u32(0) + ilst) + chpl(header9: true, [(0, "Chapter 1"), (95 * 10_000_000, "Chapter 2")]))
let moov = atom("moov", mvhdV0(timescale: 600, duration: 90_000) + udta)
let file = atom("ftyp", fourCC("M4B ")) + moov

let parsed = try M4bParser().parse(source: DataM4bSource(file))
check(parsed.title == "The Long Night", "title")
check(parsed.author == "A. Author", "author")
check(parsed.album == "LN Series", "album")
check(parsed.durationMs == 150_000, "duration v0 (got \(parsed.durationMs))")
check(parsed.chapters == [ParsedChapter(startMs: 0, title: "Chapter 1"), ParsedChapter(startMs: 95_000, title: "Chapter 2")], "chapters 9-byte header")
check(parsed.images.map(\.mimeType) == ["image/jpeg", "image/png"], "images: explicit type + magic-byte sniff")
check(parsed.images.map(\.bytes) == [jpeg, png], "image bytes")

// --- mvhd v1 ---
let v1 = try M4bParser().parse(source: DataM4bSource(atom("moov", mvhdV1(timescale: 44_100, duration: 44_100 * 3_600))))
check(v1.durationMs == 3_600_000, "duration v1 (got \(v1.durationMs))")

// --- 5-byte chpl header fallback ---
let shortHdr = try M4bParser().parse(source: DataM4bSource(
    atom("moov", mvhdV0(timescale: 1000, duration: 90_000) + atom("udta", chpl(header9: false, [(0, "One"), (30 * 10_000_000, "Two"), (60 * 10_000_000, "Three")])))))
check(shortHdr.chapters.map(\.title) == ["One", "Two", "Three"], "chapters 5-byte header fallback")
check(shortHdr.chapters.map(\.startMs) == [0, 30_000, 60_000], "chapter times")

// --- 64-bit extended atom size ---
let ext = try M4bParser().parse(source: DataM4bSource(
    extendedAtom("moov", mvhdV0(timescale: 600, duration: 600) + extendedAtom("udta", chpl(header9: true, [(0, "Only")])))))
check(ext.durationMs == 1000 && ext.chapters.map(\.title) == ["Only"], "extended (64-bit) atom sizes")

// --- size 0 = to end of parent ---
let sizeZero = try M4bParser().parse(source: DataM4bSource(
    atom("ftyp", fourCC("M4B ")) + u32(0) + fourCC("moov") + mvhdV0(timescale: 600, duration: 1200)))
check(sizeZero.durationMs == 2000, "size-0 atom extends to end")

// --- garbage chpl ignored ---
let garbage = try M4bParser().parse(source: DataM4bSource(
    atom("moov", atom("udta", atom("chpl", Data([0, 0, 0, 0, 200, 1, 2, 3, 250]))))))
check(garbage.chapters.isEmpty, "garbage chpl ignored")

// --- missing moov throws ---
do {
    _ = try M4bParser().parse(source: DataM4bSource(atom("ftyp", fourCC("M4B "))))
    check(false, "missing moov throws")
} catch M4bParserError.notMp4 {
    check(true, "missing moov throws")
}

// --- sync manifest ---
let manifest = try SyncManifestParser.parse(json: """
{"beats":[{"data_beat_id":"b2","start_seconds":10.5,"end_seconds":14,"xhtml":"c1.xhtml"},
          {"data_beat_id":"b1","start_seconds":0,"end_seconds":10.5,"xhtml":"c1.xhtml"},
          {"beat_id":"b3","start_seconds":14,"end_seconds":20,"xhtml":"c2.xhtml"}],
 "images":[{"src":"a.jpg","trigger_seconds":0},{"trigger_seconds":9},{"src":"b.png","trigger_seconds":15}]}
""")
check(manifest.spanClass == "lnvox-beat" && manifest.dataAttr == "data-beat-id", "manifest defaults")
check(manifest.beats.map(\.dataBeatId) == ["b1", "b2", "b3"], "beats sorted, beat_id fallback")
check(manifest.images.map(\.ordinal) == [0, 2], "image ordinals preserve manifest positions")
check(manifest.beat(atMs: 10_499)?.dataBeatId == "b1" && manifest.beat(atMs: 10_500)?.dataBeatId == "b2"
      && manifest.beat(atMs: -1) == nil, "beatAt binary search")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
