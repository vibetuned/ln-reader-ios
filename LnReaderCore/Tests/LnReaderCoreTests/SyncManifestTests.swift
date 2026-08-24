import XCTest
@testable import LnReaderCore

final class SyncManifestTests: XCTestCase {
    private let sampleJson = """
    {
      "span_class": "lnvox-beat",
      "data_attr": "data-beat-id",
      "beats": [
        { "data_beat_id": "b2", "chapter_id": "ch1", "xhtml": "OEBPS/Text/ch1.xhtml", "start_seconds": 10.5, "end_seconds": 14.0 },
        { "data_beat_id": "b1", "xhtml": "OEBPS/Text/ch1.xhtml", "start_seconds": 0.0, "end_seconds": 10.5 },
        { "beat_id": "b3", "xhtml": "OEBPS/Text/ch2.xhtml", "start_seconds": 14.0, "end_seconds": 20.0 },
        { "xhtml": "no-id-skipped.xhtml", "start_seconds": 99.0 }
      ],
      "images": [
        { "src": "../Images/cover.jpg", "trigger_seconds": 0.0 },
        { "src": "../Images/scene.png", "xhtml": "OEBPS/Text/ch2.xhtml", "trigger_seconds": 15.0 },
        { "trigger_seconds": 42.0 }
      ]
    }
    """

    func testParseSortsBeatsAndSkipsInvalid() throws {
        let manifest = try SyncManifestParser.parse(json: sampleJson)
        XCTAssertEqual(manifest.spanClass, "lnvox-beat")
        XCTAssertEqual(manifest.dataAttr, "data-beat-id")
        XCTAssertEqual(manifest.beats.map(\.dataBeatId), ["b1", "b2", "b3"])
        XCTAssertEqual(manifest.beats[1].chapterId, "ch1")
        XCTAssertNil(manifest.beats[0].chapterId)
    }

    func testImagesKeepManifestOrdinalEvenWhenEntriesSkipped() throws {
        let manifest = try SyncManifestParser.parse(json: sampleJson)
        XCTAssertEqual(manifest.images.map(\.src), ["../Images/cover.jpg", "../Images/scene.png"])
        XCTAssertEqual(manifest.images.map(\.ordinal), [0, 1])
        XCTAssertNil(manifest.images[0].xhtml)
        XCTAssertEqual(manifest.images[1].triggerSeconds, 15.0)
    }

    func testBeatAtBinarySearch() throws {
        let manifest = try SyncManifestParser.parse(json: sampleJson)
        XCTAssertNil(manifest.beat(atMs: -1))
        XCTAssertEqual(manifest.beat(atMs: 0)?.dataBeatId, "b1")
        XCTAssertEqual(manifest.beat(atMs: 10_499)?.dataBeatId, "b1")
        XCTAssertEqual(manifest.beat(atMs: 10_500)?.dataBeatId, "b2")
        XCTAssertEqual(manifest.beat(atMs: 999_000)?.dataBeatId, "b3")
    }

    func testDefaultsApplied() throws {
        let manifest = try SyncManifestParser.parse(json: "{}")
        XCTAssertEqual(manifest.spanClass, "lnvox-beat")
        XCTAssertEqual(manifest.dataAttr, "data-beat-id")
        XCTAssertTrue(manifest.beats.isEmpty)
        XCTAssertTrue(manifest.images.isEmpty)
    }
}
