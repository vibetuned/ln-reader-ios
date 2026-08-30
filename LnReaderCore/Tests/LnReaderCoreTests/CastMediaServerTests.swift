import XCTest
@testable import LnReaderCore

final class CastMediaServerTests: XCTestCase {
    private var tempDir: URL!
    private var server: CastMediaServer!
    private var payload: Data!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cast-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        payload = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        let fileURL = tempDir.appendingPathComponent("book.m4b")
        try payload.write(to: fileURL)
        server = CastMediaServer { kind, id in
            guard kind == "book", id == "abc" else { return nil }
            return CastMediaServer.Resource(fileURL: fileURL, mimeType: "audio/mp4")
        }
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fetch(_ url: URL, range: String? = nil) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse, data)
    }

    func testServesWholeFile() async throws {
        let url = try XCTUnwrap(server.localURL(kind: "book", id: "abc"))
        let (response, data) = try await fetch(url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, payload)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
    }

    func testServesOpenEndedRange() async throws {
        let url = try XCTUnwrap(server.localURL(kind: "book", id: "abc"))
        let (response, data) = try await fetch(url, range: "bytes=99000-")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, payload.suffix(1000))
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Range"), "bytes 99000-99999/100000")
    }

    func testServesBoundedRange() async throws {
        let url = try XCTUnwrap(server.localURL(kind: "book", id: "abc"))
        let (response, data) = try await fetch(url, range: "bytes=10-19")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, payload.subdata(in: 10 ..< 20))
    }

    func testRejectsWrongTokenAndUnknownId() async throws {
        let good = try XCTUnwrap(server.localURL(kind: "book", id: "abc"))
        var badToken = URLComponents(url: good, resolvingAgainstBaseURL: false)!
        badToken.path = "/t/deadbeef/book/abc"
        let (tokenResponse, _) = try await fetch(badToken.url!)
        XCTAssertEqual(tokenResponse.statusCode, 404)

        let unknown = try XCTUnwrap(server.localURL(kind: "book", id: "nope"))
        let (idResponse, _) = try await fetch(unknown)
        XCTAssertEqual(idResponse.statusCode, 404)
    }

    func testRangeParsing() {
        XCTAssertEqual(CastMediaServer.parseRange("bytes=0-", total: 10), 0 ... 9)
        XCTAssertEqual(CastMediaServer.parseRange("bytes=5-7", total: 10), 5 ... 7)
        XCTAssertEqual(CastMediaServer.parseRange("bytes=5-99", total: 10), 5 ... 9)
        XCTAssertNil(CastMediaServer.parseRange("bytes=10-", total: 10))
        XCTAssertNil(CastMediaServer.parseRange(nil, total: 10))
        XCTAssertNil(CastMediaServer.parseRange("bytes=0-", total: 0))
    }
}
